import Foundation
import AppKit
import Security

/// Updates PadLink from GitHub by itself.
///
/// Why: the app is signed with a (free) development certificate, not notarised. A copy downloaded with a web
/// browser gets the "from the internet" mark, and macOS then refuses to open it ("could be malware"). A copy
/// the app downloads itself carries no such mark — so after the first install, updates never hit that wall.
/// Safety: the new app is only installed if it is signed by exactly the same certificate as this one.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var available: String?      // newer version on GitHub, e.g. "1.6"
    @Published private(set) var working = false
    @Published private(set) var problem: String?

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private static let api = URL(string: "https://api.github.com/repos/LeanderKY/PadLink/releases/latest")!
    private var timer: Timer?
    private var tag: String?

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    func check() async {
        var req = URLRequest(url: Self.api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PadLink-Updater", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["tag_name"] as? String else { return }
        let v = t.hasPrefix("v") ? String(t.dropFirst()) : t
        tag = t
        available = Self.isNewer(v, than: current) ? v : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func install() {
        guard let tag, !working else { return }
        working = true
        problem = nil
        Task {
            do {
                let newApp = try await Self.download(tag: tag)
                try Self.verify(newApp)
                try Self.replaceSelf(with: newApp)
            } catch {
                working = false
                problem = "Update hat nicht geklappt: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Steps

    private static func download(tag: String) async throws -> URL {
        let url = URL(string: "https://github.com/LeanderKY/PadLink/releases/download/\(tag)/PadLink-Mac.zip")!
        let (file, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw fail("Download fehlgeschlagen") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PadLink-Update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("PadLink-Mac.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.appendingPathComponent("x").path])
        let app = dir.appendingPathComponent("x/PadLink.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw fail("Update-Datei ist unvollständig") }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// The new app must be intact and signed by the same certificate as the running one.
    private static func verify(_ app: URL) throws {
        var me: SecCode?, req: SecRequirement?, code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(me as! SecStaticCode, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw fail("Signatur kann nicht geprüft werden")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else {
            throw fail("Das Update ist nicht von PadLink signiert – nicht installiert")
        }
    }

    private static func replaceSelf(with newApp: URL) throws {
        let target = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp, backupItemName: nil, options: [])
        // Start the new version once this one has quit.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", target.path]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw fail("\(URL(fileURLWithPath: tool).lastPathComponent) fehlgeschlagen") }
        return p.terminationStatus
    }

    private static func fail(_ s: String) -> NSError {
        NSError(domain: "PadLink.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
