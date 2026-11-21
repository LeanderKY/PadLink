import Foundation
import AppKit
import Network
import ApplicationServices
import CoreGraphics

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case choosePad([String])
        case connecting(String)
        case waitingForApproval(String)
        case streaming(String)
        case problem(String)
    }

    @Published var phase: Phase = .idle
    @Published var latencyMs: Double = 0
    @Published var fps: Int = 0
    @Published private(set) var viaCable = false
    /// Opt-in: pause AirDrop's radio (AWDL) while streaming over Wi‑Fi — fewer lag spikes, asks for the password.
    @Published var pauseAirDrop = UserDefaults.standard.bool(forKey: "pauseAirDrop") {
        didSet { UserDefaults.standard.set(pauseAirDrop, forKey: "pauseAirDrop") }
    }
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()
    @Published var hasInputAccess = AXIsProcessTrusted()

    @Published var mode: DisplayMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published private(set) var pairedPad: String? {
        didSet { UserDefaults.standard.set(pairedPad, forKey: "pairedPad") }
    }

    private let browser = PadBrowser()
    private var session: StreamSession?
    private var searchTimeout: Task<Void, Never>?
    private var permissionPoll: Timer?
    private var connectingTo: String?

    private let macId: String = {
        if let id = UserDefaults.standard.string(forKey: "macId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "macId")
        return id
    }()

    init() {
        mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .mirror
        quality = Quality(rawValue: UserDefaults.standard.integer(forKey: "quality").clamped(0, 2)) ?? .balanced
        if UserDefaults.standard.object(forKey: "quality") == nil { quality = .balanced }
        pairedPad = UserDefaults.standard.string(forKey: "pairedPad")
        startPermissionPolling()
        KeyMap.shared.prepare() // keyboard-layout lookup must happen on the main thread
        FrontApp.shared.prepare()
    }

    var permissionsOK: Bool { hasScreenAccess && hasInputAccess }
    var isActive: Bool {
        switch phase { case .idle, .problem: return false; default: return true }
    }
    var isStreaming: Bool { if case .streaming = phase { return true }; return false }

    // MARK: The big button

    func bigButton() {
        if isActive { disconnect() } else { connect() }
    }

    func connect() {
        guard permissionsOK else { return }
        phase = .searching
        // Cable first: if the pad is plugged in, use USB (lowest latency). Otherwise Wi‑Fi.
        Task {
            let usb = await Task.detached(priority: .userInitiated) { UsbScanner.findPad() }.value
            guard phase == .searching else { if let usb { IOObjectRelease(usb) }; return }
            if let usb { openUSB(usb) } else { searchWifi() }
        }
    }

    private func searchWifi() {
        browser.onChange = { [weak self] found in self?.evaluate(found) }
        browser.start()
        searchTimeout?.cancel()
        searchTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .searching else { return }
            self.browser.stop()
            self.phase = .problem("Pad nicht gefunden.\nPadLink auf dem Pad öffnen – und Kabel einstecken oder beide ins gleiche WLAN.")
        }
    }

    func disconnect() {
        searchTimeout?.cancel()
        browser.stop()
        session?.stop()
        session = nil
        AirDropPause.resume()
        phase = .idle
    }

    func choose(_ name: String) { open(name) }

    func forgetPad() {
        if let p = pairedPad { tokens[p] = nil }
        pairedPad = nil
        disconnect()
    }

    private func evaluate(_ found: [String: NWEndpoint]) {
        guard phase == .searching || { if case .choosePad = phase { return true }; return false }() else { return }
        if let p = pairedPad {
            if found[p] != nil { open(p) }
            return
        }
        let names = found.keys.sorted()
        if names.count == 1 { open(names[0]) }
        else if names.count > 1 { phase = .choosePad(names) }
    }

    private func openUSB(_ interfaceService: io_service_t) {
        viaCable = true
        connectingTo = nil
        phase = .connecting("Pad am Kabel")
        startSession(UsbConnection(interfaceService: interfaceService), name: nil)
    }

    private func open(_ name: String) {
        guard let endpoint = browser.found[name] else { return }
        searchTimeout?.cancel()
        browser.stop()
        viaCable = false
        connectingTo = name
        phase = .connecting(name)
        startSession(PadConnection(endpoint: endpoint), name: name)
    }

    private func startSession(_ transport: PadTransport, name: String?) {
        let s = StreamSession(transport: transport, mode: mode, quality: quality, macId: macId,
                              macName: Host.current().localizedName ?? "Mac", token: name.flatMap { tokens[$0] })
        s.onEvent = { [weak self] e in self?.handle(e, from: s) }
        session = s
        s.start()
    }

    private func handle(_ e: StreamSession.Event, from s: StreamSession) {
        guard s === session else { return }
        switch e {
        case .waitingForApproval:
            phase = .waitingForApproval(connectingTo ?? "Pad")
        case .token(let t):
            if let name = connectingTo {
                tokens[name] = t
                pairedPad = name
            }
        case .streaming(let padName):
            phase = .streaming(padName)
            if pauseAirDrop && !viaCable { Task { _ = await AirDropPause.pause() } }
        case .stats(let rtt, let fps):
            latencyMs = rtt
            self.fps = fps
        case .ended(let reason):
            AirDropPause.resume()
            session = nil
            if let reason { phase = .problem(reason) } else if isActive { phase = .idle }
        }
    }

    // MARK: Tokens

    private var tokens: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "tokens") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "tokens") }
    }

    // MARK: Permissions

    func askScreenAccess() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func askInputAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func startPermissionPolling() {
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = CGPreflightScreenCaptureAccess(), a = AXIsProcessTrusted()
                if s != self.hasScreenAccess { self.hasScreenAccess = s }
                if a != self.hasInputAccess { self.hasInputAccess = a }
            }
        }
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
