import AppKit
import SQLite3

/// Notifications from your other apps, read from macOS's Notification Center database.
/// macOS protects that database, so this works only after you give Icicle Full Disk Access.
/// It's read-only and stays on your Mac; dismissing one here only hides it on Icicle's lock screen.
final class SystemNotifications: ObservableObject {
    static let shared = SystemNotifications()

    enum Access { case unknown, granted, needsFullDiskAccess }
    @Published private(set) var access: Access = .unknown

    private var timer: Timer?
    private var dismissed: Set<UUID>
    private let queue = DispatchQueue(label: "glasslock.system-notifications", qos: .utility)

    private static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }
    private static var iconFolder: URL { Snapshot.folder.appendingPathComponent("icons") }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "dismissedSystemNotifications") ?? []
        dismissed = Set(saved.compactMap(UUID.init))
    }

    func start() {
        refresh()
        NotificationCenter.default.addObserver(forName: Live.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(); self?.schedule()
        }
        schedule()
    }

    /// Every 10 seconds while the lock screen is showing (or the Mac is locked); otherwise every few minutes.
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Live.active ? 10 : 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = Live.active ? 2 : 60
    }

    func dismiss(_ ids: [UUID]) {
        dismissed.formUnion(ids)
        UserDefaults.standard.set(dismissed.map(\.uuidString), forKey: "dismissedSystemNotifications")
    }

    func refresh() {
        guard !GL.isSaver else { return }
        queue.async {
            let result = Self.read()
            DispatchQueue.main.async {
                switch result {
                case .none:
                    self.access = .needsFullDiskAccess
                    Inbox.shared.system = []
                case .some(let notes):
                    self.access = .granted
                    // Forget dismissals for notifications macOS no longer has.
                    let live = Set(notes.map(\.id))
                    if !self.dismissed.isSubset(of: live) { self.dismissed.formIntersection(live); self.dismiss([]) }
                    let shown = notes.filter { !self.dismissed.contains($0.id) }
                    if Inbox.shared.system != shown { Inbox.shared.system = shown }
                }
            }
        }
    }

    /// nil when macOS blocks access (no Full Disk Access).
    private static func read() -> [InboxItem]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT r.uuid, a.identifier, r.data, r.delivered_date
            FROM record r JOIN app a ON a.app_id = r.app_id
            ORDER BY r.delivered_date DESC LIMIT 60
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var notes: [InboxItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bundleId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let req = plist["req"] as? [String: Any] else { continue }
            let title = (req["titl"] as? String) ?? ""
            let subtitle = (req["subt"] as? String) ?? ""
            let body = (req["body"] as? String) ?? ""
            guard !(title.isEmpty && body.isEmpty) else { continue }

            var id = UUID()
            if let u = sqlite3_column_blob(stmt, 0), sqlite3_column_bytes(stmt, 0) == 16 {
                let b = [UInt8](UnsafeRawBufferPointer(start: u, count: 16))
                id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            }
            let delivered = sqlite3_column_double(stmt, 3)
            let date = delivered > 0 ? Date(timeIntervalSinceReferenceDate: delivered) : ((plist["date"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date())
            let name = appName(bundleId)
            notes.append(InboxItem(id: id, source: .system,
                                   title: title.isEmpty ? name : title,
                                   body: [subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n"),
                                   date: date, bundleId: bundleId, app: name))
            saveIcon(bundleId)
        }
        return notes
    }

    // MARK: App names and icons

    private static var names: [String: String] = [:]
    private static func appName(_ bundleId: String) -> String {
        if let n = names[bundleId] { return n }
        var name = bundleId.split(separator: ".").last.map(String.init)?.capitalized ?? bundleId
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleId] = name
        return name
    }

    /// Icons are saved as small PNGs so the lock screen (which can't ask macOS for them) can show them too.
    private static func saveIcon(_ bundleId: String) {
        let file = iconFolder.appendingPathComponent("\(bundleId).png")
        guard !FileManager.default.fileExists(atPath: file.path),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 72, height: 72)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: iconFolder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: file, options: .atomic)
    }

    private static var iconCache: [String: NSImage] = [:]
    static func icon(for bundleId: String) -> NSImage? {
        if let i = iconCache[bundleId] { return i }
        guard let img = NSImage(contentsOf: iconFolder.appendingPathComponent("\(bundleId).png")) else { return nil }
        iconCache[bundleId] = img
        return img
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}
