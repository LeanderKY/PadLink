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
    /// no pad is on the cable.
    static func findPad(wait: TimeInterval = 6) -> io_service_t? {
        if let i = accessoryInterface() { return i }
        let candidates = devices().filter(looksLikeAndroid)
        guard !candidates.isEmpty else { return nil }
        var switched = false
        for d in candidates where switchToAccessory(d) { switched = true }
        defer { candidates.forEach { IOObjectRelease($0.service) } }
        guard switched else { return nil }
        // The pad disconnects and comes back as a Google accessory device.
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if let i = accessoryInterface() { return i }
        }
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
        let ifs = interfaces(of: acc.entryID)
        var result: io_service_t?
        for i in ifs {
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
        let n = d.name.lowercased()
        if ["android", "wacom", "movink", "dtha"].contains(where: n.contains) {
            // Wacom also makes plain pen tablets (HID only) — require a non-HID interface.
            return interfacesSummary(d).contains { $0.cls == 0xFF || $0.cls == 6 }
        }
        return interfacesSummary(d).contains { ($0.cls == 0xFF && ($0.sub == 0x42 || $0.name.uppercased().contains("MTP"))) || $0.cls == 6 }
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
        guard let obj = objects.first else { NSLog("PadLink USB: cannot open \(d.name)"); return false }
        defer { obj.destroy() }

        // 1. Does it speak AOA?
        let ver = NSMutableData(length: 2)!
        var n = 0
        do {
            try obj.__send(request(0xC0, AOA.getProtocol, length: 2), data: ver, bytesTransferred: &n, completionTimeout: 1)
        } catch {
            NSLog("PadLink USB: \(d.name) is not an Android accessory host target (\(error.localizedDescription))")
            return false
        }
        let protocolVersion = Int(ver.bytes.load(as: UInt16.self).littleEndian)
        guard n == 2, protocolVersion >= 1 else { return false }

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
            NSLog("PadLink USB: AOA start failed: \(error.localizedDescription)")
            return false
        }
        NSLog("PadLink USB: switched \(d.name) to accessory mode (AOA v\(protocolVersion))")
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
        guard !closed else { return }
        send(.bye, Data()) { [weak self] in self?.queue.async { self?.finish(nil) } }
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
