import Foundation
import IOKit
import IOUSBHost

/// The pad over a USB-C cable, using the Android Open Accessory (AOA) protocol.
/// Why AOA: it needs no developer mode on the pad. The Mac asks the pad to switch into "accessory mode";
/// Android then opens PadLink by itself (first time: one "Immer öffnen" tap) and both sides talk over
/// two raw USB bulk pipes — no Wi‑Fi, no network stack, no radio jitter.
enum AOA {
    static let googleVID = 0x18D1
    static let accessoryPIDs = 0x2D00...0x2D05
    // Must match android/app/src/main/res/xml/accessory_filter.xml
    static let strings = ["PadLink", "PadLink Mac", "PadLink – Bildschirm vom Mac", "1", "https://padlink.app", "1"]

    static let getProtocol: UInt8 = 51
    static let sendString: UInt8 = 52
    static let start: UInt8 = 53
}

/// Finds the pad on USB and, if needed, switches it into accessory mode.
enum UsbScanner {
    struct Device {
        let service: io_service_t
        let entryID: UInt64
        let vid: Int, pid: Int
        let name: String
        var isAccessory: Bool { vid == AOA.googleVID && AOA.accessoryPIDs.contains(pid) }
    }
    struct Interface {
        let service: io_service_t
        let number: Int, cls: Int, sub: Int
        let name: String
    }

    /// Blocking (call off the main thread). Returns interface 0 of the pad in accessory mode, or nil if
    /// no pad is on the cable. `kick`: the pad is already in accessory mode but didn't answer — ask it to
    /// switch again, which makes Android drop the old accessory connection and open PadLink afresh.
    static func findPad(wait: TimeInterval = 30, kick: Bool = false, onSwitched: (() -> Void)? = nil) -> io_service_t? {
        resetReport()
        lastSawPad = false
        lastBlocked = false
        for port in usbCPorts() {
            note("Anschluss \(port.name): \(port.connected ? "belegt" : "frei")\(port.connected ? ", Daten: \(port.transports), Freigabe: \(port.auth)" : "")")
            if port.connected && port.blocked { lastBlocked = true }
        }
        if lastBlocked { note("→ macOS hat das Gerät am Kabel noch nicht freigegeben („Zubehör erlauben“)") }
        let ds = devices()
        defer { ds.forEach { IOObjectRelease($0.service) } }
        note(ds.isEmpty ? "Keine USB-Geräte sichtbar (Kabel? Mac fragt evtl. „Zubehör erlauben?“)" : "USB-Geräte am Mac:")
        for d in ds { note("• \(describe(d))") }
        if let acc = ds.first(where: { $0.isAccessory }) {
            note("Pad ist schon im PadLink-Kabelmodus")
            guard kick, switchToAccessory(acc) else { return firstInterface(of: acc.entryID) }
            onSwitched?()
            return waitForAccessory(excluding: acc.entryID, wait: min(wait, 15))
        }
        var switched = false
        for d in ds where looksLikeAndroid(d) {
            lastSawPad = true
            note("Pad-Kandidat: \(d.name.isEmpty ? "?" : d.name)")
            if switchToAccessory(d) { switched = true }
        }
        if !switched { note(ds.contains(where: looksLikeAndroid) ? "Umschalten hat nicht geklappt" : "Kein Pad unter den USB-Geräten erkannt") }
        guard switched else { return nil }
        onSwitched?()
        return waitForAccessory(excluding: nil, wait: wait)
    }

    // MARK: Diagnosis (shown in the app when the cable doesn't work)

    /// Results of the last `findPad`: something pad-like was on USB / macOS is holding a device back.
    private(set) static var lastSawPad = false
    private(set) static var lastBlocked = false

    struct Port { let name: String; let connected: Bool; let transports: String; let auth: String; let blocked: Bool }

    /// The Mac's USB-C ports as the system sees them — including macOS's "allow this accessory?" state, which
    /// keeps a newly plugged-in device away from every app until someone clicks "Allow".
    static func usbCPorts() -> [Port] {
        var out: [Port] = []
        let match: NSDictionary = ["IOProviderClass": "IOService", "IOPropertyMatch": ["PortTypeDescription": "USB-C"]]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFDictionary, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            let connected = (prop("ConnectionActive") as? Bool) ?? false
            let transports = (prop("TransportsProvisioned") as? [String])?.joined(separator: "+") ?? "?"
            let required = (prop("AuthorizationRequired") as? Bool) ?? false
            let auth = (prop("UserAuthorizationStatusDescription") as? String) ?? "?"
            let ok = ["not required", "authorized", "allowed", "approved"].contains { auth.lowercased().contains($0) }
            out.append(Port(name: (prop("PortDescription") as? String) ?? "USB-C", connected: connected,
                            transports: transports, auth: auth, blocked: required && !ok))
        }
        return out
    }

    private static let reportLock = NSLock()
    private static var reportLines: [String] = []
    static var report: String { reportLock.lock(); defer { reportLock.unlock() }; return reportLines.joined(separator: "\n") }
    private static func resetReport() { reportLock.lock(); reportLines = []; reportLock.unlock() }
    static func note(_ s: String) {
        NSLog("PadLink USB: \(s)")
        reportLock.lock(); reportLines.append(s); if reportLines.count > 40 { reportLines.removeFirst() }; reportLock.unlock()
    }
    private static func describe(_ d: Device) -> String {
        let ifs = interfaces(of: d.entryID)
        ifs.forEach { IOObjectRelease($0.service) }
        let cls = ifs.map { String(format: "%02X/%02X", $0.cls, $0.sub) }.joined(separator: " ")
        return String(format: "%@ [%04X:%04X] %@", d.name.isEmpty ? "(ohne Namen)" : d.name, d.vid, d.pid, ifs.isEmpty ? "keine Schnittstellen" : cls)
    }

    /// The pad disconnects and comes back as a Google accessory device (a new registry entry).
    private static func waitForAccessory(excluding old: UInt64?, wait: TimeInterval) -> io_service_t? {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let ds = devices()
            defer { ds.forEach { IOObjectRelease($0.service) } }
            if let acc = ds.first(where: { $0.isAccessory && $0.entryID != old }),
               let i = firstInterface(of: acc.entryID) { note("Pad im Kabelmodus wieder da"); return i }
        }
        note("Pad kam nach dem Umschalten nicht zurück (\(Int(wait)) s) – am Mac „Zubehör erlauben“ bestätigt?")
        return nil
    }

    /// True if something that looks like the pad is plugged in (cheap, no USB traffic).
    static func padPluggedIn() -> Bool {
        let ds = devices()
        defer { ds.forEach { IOObjectRelease($0.service) } }
        return ds.contains { $0.isAccessory || looksLikeAndroid($0) }
    }

    static func accessoryInterface() -> io_service_t? {
        let ds = devices()
        defer { ds.forEach { IOObjectRelease($0.service) } }
        guard let acc = ds.first(where: { $0.isAccessory }) else { return nil }
        return firstInterface(of: acc.entryID)
    }

    private static func firstInterface(of entryID: UInt64) -> io_service_t? {
        var result: io_service_t?
        for i in interfaces(of: entryID) {
            if result == nil && i.number == 0 { result = i.service } else { IOObjectRelease(i.service) }
        }
        return result
    }

    // MARK: Registry

    static func devices() -> [Device] {
        var out: [Device] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &id)
            let name = [str(s, "USB Vendor Name") ?? str(s, "kUSBVendorString"),
                        str(s, "USB Product Name") ?? str(s, "kUSBProductString")]
                .compactMap { $0 }.joined(separator: " ")
            out.append(Device(service: s, entryID: id, vid: int(s, "idVendor") ?? 0, pid: int(s, "idProduct") ?? 0, name: name))
        }
        return out
    }

    static func interfaces(of deviceEntryID: UInt64) -> [Interface] {
        var out: [Interface] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            var parent: io_registry_entry_t = 0
            var pid: UInt64 = 0
            if IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS {
                IORegistryEntryGetRegistryEntryID(parent, &pid)
                IOObjectRelease(parent)
            }
            if pid == deviceEntryID {
                out.append(Interface(service: s, number: int(s, "bInterfaceNumber") ?? -1,
                                     cls: int(s, "bInterfaceClass") ?? -1, sub: int(s, "bInterfaceSubClass") ?? -1,
                                     name: str(s, "USB Interface Name") ?? str(s, "kUSBString") ?? ""))
            } else {
                IOObjectRelease(s)
            }
        }
        return out
    }

    /// Android devices expose MTP/PTP or vendor (ADB) interfaces. We never poke Apple devices, hubs,
    /// keyboards, mice or audio gear.
    static func looksLikeAndroid(_ d: Device) -> Bool {
        if d.isAccessory || d.vid == 0x05AC || d.vid == 0 { return false }
        let ifs = interfacesSummary(d)
        let n = d.name.lowercased()
        if d.vid == 0x056A || ["android", "wacom", "movink", "dtha"].contains(where: n.contains) {
            // Wacom also makes plain pen tablets (HID only). The pad in "charging only" mode may show no
            // interfaces at all — still worth asking (an AOA request to a non-Android device just fails).
            return ifs.isEmpty || ifs.contains { $0.cls != 3 }
        }
        return ifs.contains { ($0.cls == 0xFF && ($0.sub == 0x42 || $0.name.uppercased().contains("MTP"))) || $0.cls == 6 }
    }

    private static func interfacesSummary(_ d: Device) -> [Interface] {
        let ifs = interfaces(of: d.entryID)
        ifs.forEach { IOObjectRelease($0.service) }
        return ifs
    }

    // MARK: AOA handshake

    /// Sends the AOA "switch to accessory mode" requests. Uses the device object if macOS lets us open it,
    /// otherwise one of its interfaces (control requests go to the same default pipe either way).
    static func switchToAccessory(_ d: Device) -> Bool {
        let q = DispatchQueue(label: "padlink.usb.ctrl")
        var objects: [IOUSBHostObject] = []
        if let dev = try? IOUSBHostDevice(__ioService: d.service, options: [], queue: q, interestHandler: nil) {
            objects.append(dev)
        } else {
            for i in interfaces(of: d.entryID) {
                if objects.isEmpty, let o = try? IOUSBHostInterface(__ioService: i.service, options: [], queue: q, interestHandler: nil) {
                    objects.append(o)
                }
                IOObjectRelease(i.service)
            }
        }
        guard let obj = objects.first else { note("Kann \(d.name) nicht öffnen (macOS lässt keinen Zugriff zu)"); return false }
        defer { obj.destroy() }

        // 1. Does it speak AOA?
        let ver = NSMutableData(length: 2)!
        var n = 0
        do {
            try obj.__send(request(0xC0, AOA.getProtocol, length: 2), data: ver, bytesTransferred: &n, completionTimeout: 1)
        } catch {
            note("\(d.name) antwortet nicht auf die Kabelmodus-Anfrage (\(error.localizedDescription))")
            return false
        }
        let protocolVersion = Int(ver.bytes.load(as: UInt16.self).littleEndian)
        guard n == 2, protocolVersion >= 1 else { note("\(d.name): kein Android-Kabelmodus (Version \(protocolVersion))"); return false }

        // 2. Identify ourselves, 3. start.
        do {
            for (idx, s) in AOA.strings.enumerated() {
                var bytes = Array(s.utf8); bytes.append(0)
                let data = NSMutableData(bytes: bytes, length: bytes.count)
                try obj.__send(request(0x40, AOA.sendString, index: UInt16(idx), length: UInt16(bytes.count)),
                               data: data, bytesTransferred: nil, completionTimeout: 1)
            }
            try obj.__send(request(0x40, AOA.start, length: 0), data: nil, bytesTransferred: nil, completionTimeout: 1)
        } catch {
            note("Umschalten fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
        note("\(d.name) auf Kabelmodus umgeschaltet (AOA v\(protocolVersion))")
        return true
    }

    private static func request(_ type: UInt8, _ req: UInt8, index: UInt16 = 0, length: UInt16) -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(bmRequestType: type, bRequest: req, wValue: 0, wIndex: index, wLength: length)
    }

    // MARK: Property helpers

    private static func int(_ s: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
    private static func str(_ s: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

/// The framed PadLink protocol over the two accessory bulk pipes.
final class UsbConnection: PadTransport {
    let queue = DispatchQueue(label: "padlink.net", qos: .userInteractive)
    let isUSB = true
    var onReady: (() -> Void)?
    var onMessage: ((Msg, Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    private let service: io_service_t
    private var iface: IOUSBHostInterface?
    private var inPipe: IOUSBHostPipe?
    private var outPipe: IOUSBHostPipe?
    private let writeQueue = DispatchQueue(label: "padlink.usb.write", qos: .userInteractive)
    private var parser = FrameParser()
    private var closed = false
    private var gotData = false

    /// Android's accessory driver reads in 16 KB transfers; never send more per transfer.
    private static let chunk = 16 * 1024

    init(interfaceService: io_service_t) { service = interfaceService }
    deinit { IOObjectRelease(service) }

    func start() {
        queue.async { [self] in
            do {
                let i = try IOUSBHostInterface(__ioService: service, options: [], queue: queue) { [weak self] _, type, _ in
                    if type == 0xE000_0010 /* kIOMessageServiceIsTerminated */ { self?.queue.async { self?.finish("Kabel getrennt") } }
                }
                iface = i
                let (inAddr, outAddr) = try Self.bulkEndpoints(of: i)
                inPipe = try i.copyPipe(withAddress: inAddr)
                outPipe = try i.copyPipe(withAddress: outAddr)
            } catch {
                return finish("Pad am Kabel nicht bereit – ist PadLink auf dem Pad offen? (\(error.localizedDescription))")
            }
            onReady?()
            let t = Thread { [weak self] in self?.readLoop() }
            t.name = "padlink.usb.read"
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    func send(_ type: Msg, _ payload: Data, completion: (() -> Void)?) {
        let bytes = frame(type, payload)
        writeQueue.async { [weak self] in
            guard let self, let pipe = self.outPipe else { completion?(); return }
            var off = 0
            while off < bytes.count {
                var len = min(Self.chunk, bytes.count - off)
                // A transfer that is an exact multiple of the 512-byte packet size (and not a full 16 KB)
                // would leave the pad's read waiting for more. Send it as two short transfers instead.
                if len < Self.chunk && len % 512 == 0 { len -= 1 }
                let part = NSMutableData(data: bytes.subdata(in: (bytes.startIndex + off)..<(bytes.startIndex + off + len)))
                do {
                    try pipe.__sendIORequest(with: part, bytesTransferred: nil, completionTimeout: 8)
                } catch {
                    self.queue.async { self.finish("Kabel-Verbindung unterbrochen") }
                    completion?()
                    return
                }
                off += len
            }
            completion?()
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            // Nobody on the other end yet (PadLink on the pad not open): a write would block — just let go.
            guard gotData else { return finish(nil) }
            send(.bye, Data()) { [weak self] in self?.queue.async { self?.finish(nil) } }
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish(nil) }
        }
    }

    private func readLoop() {
        while let pipe = inPipe {
            let buf = NSMutableData(length: Self.chunk)!
            var n = 0
            do {
                try pipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: 0)
            } catch {
                queue.async { [weak self] in self?.finish(self?.closed == true ? nil : "Kabel-Verbindung unterbrochen") }
                return
            }
            if n > 0 {
                let d = Data(bytes: buf.bytes, count: n)
                queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.gotData = true
                    for (t, p) in self.parser.feed(d) { self.onMessage?(t, p) }
                }
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        try? inPipe?.__abort(with: .synchronous)
        try? outPipe?.__abort(with: .synchronous)
        iface?.destroy()
        inPipe = nil
        outPipe = nil
        iface = nil
        onClosed?(reason)
    }

    private static func bulkEndpoints(of i: IOUSBHostInterface) throws -> (Int, Int) {
        let cfg = i.configurationDescriptor
        let ifd = i.interfaceDescriptor
        var inAddr: Int?, outAddr: Int?
        var cur: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, cur) {
            let type = ep.pointee.bmAttributes & 0x3
            let addr = Int(ep.pointee.bEndpointAddress)
            if type == 2 { // bulk
                if addr & 0x80 != 0 { inAddr = inAddr ?? addr } else { outAddr = outAddr ?? addr }
            }
            cur = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let a = inAddr, let b = outAddr else {
            throw NSError(domain: "PadLink", code: 10, userInfo: [NSLocalizedDescriptionKey: "keine USB-Datenleitung gefunden"])
        }
        return (a, b)
    }
}

/// Tells the app when the pad gets plugged in (or unplugged), without polling.
final class UsbWatcher {
    var onPadPlugged: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iters: [io_iterator_t] = []
    private var plugged = false
    private var pending: DispatchWorkItem?

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        IONotificationPortSetDispatchQueue(p, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            let cb: IOServiceMatchingCallback = { ctx, it in
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
                Unmanaged<UsbWatcher>.fromOpaque(ctx!).takeUnretainedValue().recheck()
            }
            if IOServiceAddMatchingNotification(p, type, IOServiceMatching("IOUSBHostDevice"), cb, me, &it) == KERN_SUCCESS {
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) } // arm
                iters.append(it)
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = UsbScanner.padPluggedIn()
            DispatchQueue.main.async { self?.plugged = now }
        }
    }

    /// Interfaces show up a moment after the device itself — look once things have settled.
    private func recheck() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let now = UsbScanner.padPluggedIn()
                DispatchQueue.main.async {
                    guard let self else { return }
                    let was = self.plugged
                    self.plugged = now
                    if now && !was { self.onPadPlugged?() }
                }
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
}
