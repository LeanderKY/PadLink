import Foundation

/// Optional: pause AWDL (the radio link behind AirDrop/Handoff/Sidecar) while streaming over Wi‑Fi.
/// macOS hops to another Wi‑Fi channel for AWDL about once a second, which shows up as regular lag
/// spikes in any real-time stream. Switching it off needs an admin password (macOS asks), so this is
/// opt-in. A small root helper brings AWDL back when the session ends — or when PadLink quits/crashes.
enum AirDropPause {
    private static var flagPath: String?

    /// Shows the macOS password dialog. Returns true if AWDL is paused.
    static func pause() async -> Bool {
        if flagPath != nil { return true }
        let flag = "/tmp/padlink-awdl-\(UUID().uuidString)"
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = "/sbin/ifconfig awdl0 down; " +
            "(while /bin/kill -0 \(pid) 2>/dev/null && [ ! -e \(flag) ]; do /bin/sleep 1; done; " +
            "/sbin/ifconfig awdl0 up; /bin/rm -f \(flag)) >/dev/null 2>&1 &"
        let script = "do shell script \"\(shell)\" with administrator privileges " +
            "with prompt \"PadLink möchte AirDrop während des Zeichnens pausieren (weniger Ruckler im WLAN).\""
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
        if ok { flagPath = flag }
        return ok
    }

    /// Brings AWDL back (no password needed — the helper started in `pause()` is waiting for this file).
    static func resume() {
        guard let f = flagPath else { return }
        flagPath = nil
        FileManager.default.createFile(atPath: f, contents: nil)
    }
}
