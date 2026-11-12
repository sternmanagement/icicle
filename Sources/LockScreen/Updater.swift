import AppKit

/// Checks the GitHub repository's latest release and installs a newer DMG in place.
/// The repository is baked into Info.plist (ICUpdateRepo) at build time.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }
    struct Release { let version: String; let notes: String; let dmg: URL }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    private var latest: Release?
    private var timer: Timer?

    let repo = Bundle.main.object(forInfoDictionaryKey: "ICUpdateRepo") as? String ?? ""
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
    }

    private func autoCheck() {
        if Prefs.shared.autoCheckUpdates { check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        guard !repo.isEmpty, !repo.contains("__"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            fail("This build has no update source.", show: userInitiated); return
        }
        status = .checking
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Icicle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            DispatchQueue.main.async { self.handle(data: data, response: response, userInitiated: userInitiated) }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, userInitiated: Bool) {
        lastChecked = Date()
        guard let data, let http = response as? HTTPURLResponse else {
            fail("Couldn't reach GitHub. Check your internet connection and try again.", show: userInitiated); return
        }
        if http.statusCode == 404 { status = .upToDate; if userInitiated { upToDateAlert() }; return }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            fail("GitHub returned an unexpected answer (HTTP \(http.statusCode)).", show: userInitiated); return
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion) else {
            status = .upToDate; if userInitiated { upToDateAlert() }; return
        }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let link = asset["browser_download_url"] as? String, let dmg = URL(string: link) else {
            fail("Version \(version) is published but its download isn't ready yet. Try again in a few minutes.", show: userInitiated); return
        }
        latest = Release(version: version, notes: obj["body"] as? String ?? "", dmg: dmg)
        status = .available(version)
        if !Inbox.shared.items.contains(where: { $0.source == .update && $0.title.contains(version) }) {
            Inbox.shared.remove(source: .update)
            Inbox.shared.add(.update, title: "Icicle \(version) is available", body: "Right-click ❄ in the menu bar and choose Update to install it.")
        }
        if userInitiated || Prefs.shared.skippedVersion != version { promptInstall() }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func promptInstall() {
        guard let r = latest else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Icicle \(r.version) is available"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have version \(currentVersion)." + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install()
        case .alertThirdButtonReturn: Prefs.shared.skippedVersion = r.version
        default: break
        }
    }

    func install() {
        guard let r = latest else { return }
        let dest = Bundle.main.bundleURL
        if dest.path.contains("/AppTranslocation/") || dest.path.hasPrefix("/Volumes/") {
            fail("Move Icicle to your Applications folder, open it from there, then update again.", show: true); return
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            fail("Icicle can't replace itself in \(dest.deletingLastPathComponent().path). Download the new version from GitHub instead.", show: true); return
        }
        status = .downloading
        URLSession.shared.downloadTask(with: r.dmg) { tmp, response, _ in
            guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.fail("The download didn't finish. Try again.", show: true) }; return
            }
            do {
                let staged = try Self.stage(dmgAt: tmp)
                DispatchQueue.main.async { self.relaunch(staged: staged, dest: dest) }
            } catch {
                DispatchQueue.main.async { self.fail("The update couldn't be prepared: \(error.localizedDescription)", show: true) }
            }
        }.resume()
    }

    /// Mounts the DMG, copies the app out, checks it's the same app with an intact signature.
    private static func stage(dmgAt tmp: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("IcicleUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: tmp, to: dmg)
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The download doesn't contain an app.")
        }
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download contains a different app.")
        }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        // When this copy is signed with a certificate, the update must be signed by the same one,
        // so nothing else can pose as a Icicle update.
        if let requirement = designatedRequirement(of: Bundle.main.bundleURL), !requirement.contains("cdhash") {
            do { try run("/usr/bin/codesign", ["--verify", "-R", requirement, staged.path]) }
            catch { throw UpdateError("The update isn't signed by the Icicle developer.") }
        }
        return staged
    }

    private func relaunch(staged: URL, dest: URL) {
        status = .installing
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/ditto \(q(staged.path)) \(q(dest.path + ".new")) || exit 1
        /bin/mv \(q(dest.path)) \(q(dest.path + ".old")) && /bin/mv \(q(dest.path + ".new")) \(q(dest.path))
        /bin/rm -rf \(q(dest.path + ".old")) \(q(staged.deletingLastPathComponent().path))
        /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path)) 2>/dev/null
        /usr/bin/open \(q(dest.path))
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("icicle-install-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            fail("The update couldn't start: \(error.localizedDescription)", show: true)
        }
    }

    private func fail(_ message: String, show: Bool) {
        status = .failed(message)
        guard show else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Update didn't work"
        a.informativeText = message
        a.runModal()
    }

    private func upToDateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "You're up to date"
        a.informativeText = "Icicle \(currentVersion) is the newest version."
        a.runModal()
    }

    /// The signing rule macOS uses to recognize this app, e.g. `identifier "…" and certificate leaf = H"…"`.
    private static func designatedRequirement(of app: URL) -> String? {
        guard let out = try? run("/usr/bin/codesign", ["-d", "-r-", app.path]),
              let line = out.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") }) else { return nil }
        return "=" + line.dropFirst("designated => ".count)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(out.prefix(200))") }
        return out
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
