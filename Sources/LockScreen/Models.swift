import SwiftUI
import AppKit
import IOKit.ps
import UserNotifications

/// Set by the screen saver build, which shows a snapshot written by the app instead of running live services.
enum GL { static var isSaver = false }

/// Everything in this folder is also compiled into the screen saver, so it can't reach the rest of Icicle
/// directly. The app fills these in at launch.
enum LockHooks {
    /// Whether the lock screen feature is switched on in Icicle's settings.
    static var isEnabled: () -> Bool = { true }
    /// Opens Icicle's settings on the Lock Screen page.
    static var openSettings: () -> Void = {}
}

/// The lock screen only does live work (polling music, writing the lock screen snapshot) while something shows it:
/// the Mac is locked, the overlay is up, or one of its windows is open. Otherwise it sleeps on notifications.
enum Live {
    static let changed = Notification.Name("GlassLock.liveChanged")
    static var locked = false { didSet { if locked != oldValue { post() } } }
    static var overlay = false { didSet { if overlay != oldValue { post() } } }
    static var windows = 0 { didSet { if windows != oldValue { post() } } }
    static var active: Bool { locked || overlay || windows > 0 }
    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }

    /// Releases a window's SwiftUI content when it closes, so nothing keeps redrawing (or holding memory) offscreen.
    static func track(_ window: NSWindow, onClose: @escaping () -> Void) {
        windows += 1
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            windows -= 1
            window.contentView = nil
            ImageCache.purge()
            onClose()
        }
    }
}

// MARK: - Preferences

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) == nil ? def : d.bool(forKey: key) }
    private static func string(_ key: String, _ def: String) -> String { d.string(forKey: key) ?? def }

    // When the lock screen appears
    @Published var saverOnLock = bool("saverOnLock", true) { didSet { Self.d.set(saverOnLock, forKey: "saverOnLock") } }

    // Display
    @Published var use24h = bool("use24h", false) { didSet { Self.d.set(use24h, forKey: "use24h") } }
    @Published var displayName = string("displayName", NSFullUserName()) { didSet { Self.d.set(displayName, forKey: "displayName") } }
    @Published var weatherCity = string("weatherCity", "") { didSet { Self.d.set(weatherCity, forKey: "weatherCity") } }

    // Updates
    @Published var autoCheckUpdates = bool("autoCheckUpdates", true) { didSet { Self.d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var skippedVersion = string("skippedVersion", "") { didSet { Self.d.set(skippedVersion, forKey: "skippedVersion") } }
}

// MARK: - Notification Center (events from this app)

struct InboxItem: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case timer, claude, update, system }
    var id = UUID()
    var source: Source
    var title: String
    var body: String
    var date = Date()
    /// For notifications from other apps (source `.system`): the app that sent it.
    var bundleId: String? = nil
    var app: String? = nil

    var appName: String {
        switch source { case .timer: "Clock"; case .claude: "Claude Code"; case .update: "Icicle"; case .system: app ?? "Notification" }
    }
    /// Notifications stack per app.
    var groupKey: String { bundleId ?? source.rawValue }
    var symbol: String {
        switch source { case .timer: "timer"; case .claude: "terminal.fill"; case .update: "arrow.down.circle.fill"; case .system: "bell.fill" }
    }
    var tint: Color {
        switch source { case .timer: .orange; case .claude: Color(red: 0.85, green: 0.47, blue: 0.34); case .update: .blue; case .system: .gray }
    }
}

final class Inbox: ObservableObject {
    static let shared = Inbox()
    @Published var items: [InboxItem] = [] { didSet { save() } }

    init() {
        if let data = UserDefaults.standard.data(forKey: "inbox"),
           let saved = try? JSONDecoder().decode([InboxItem].self, from: data) {
            // Earlier versions stacked a "went quiet" notice for every pause; keep only the newest.
            var keptClaude = false
            items = saved.filter { item in
                guard item.source == .claude else { return true }
                defer { keptClaude = true }
                return !keptClaude
            }
        }
    }

    /// Notifications from other apps, read from macOS's Notification Center (not stored here).
    @Published var system: [InboxItem] = []
    /// Everything to show, newest first.
    var all: [InboxItem] { (items + system).sorted { $0.date > $1.date } }

    func add(_ source: InboxItem.Source, title: String, body: String) {
        items.insert(InboxItem(source: source, title: title, body: body), at: 0)
        if items.count > 50 { items.removeLast(items.count - 50) }
    }
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if system.contains(where: { $0.id == id }) { SystemNotifications.shared.dismiss([id]); system.removeAll { $0.id == id } }
    }
    func remove(source: InboxItem.Source) { items.removeAll { $0.source == source } }
    func clear() {
        items.removeAll()
        SystemNotifications.shared.dismiss(system.map(\.id)); system.removeAll()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "inbox") }
    }
}

// MARK: - Live Activities: timers and stopwatches

struct Activity: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case timer, stopwatch }
    var id = UUID()
    var kind: Kind
    var label: String
    var total: TimeInterval = 0          // timer length
    var end: Date?                       // timer end while running
    var pausedRemaining: TimeInterval = 0
    var started: Date?                   // stopwatch segment start while running
    var accumulated: TimeInterval = 0    // stopwatch time before current segment
    var paused = false

    var displayLabel: String { label.isEmpty ? (kind == .timer ? "Timer" : "Stopwatch") : label }

    func remaining(at now: Date) -> TimeInterval {
        paused ? pausedRemaining : max(0, (end ?? now).timeIntervalSince(now))
    }
    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (paused ? 0 : now.timeIntervalSince(started ?? now))
    }
    func statusText(at now: Date) -> String {
        let value = kind == .timer ? formatDuration(remaining(at: now)) : formatDuration(elapsed(at: now))
        return paused ? "\(value) (paused)" : value
    }
}

final class Activities: ObservableObject {
    static let shared = Activities()
    @Published var items: [Activity] = [] { didSet { save(); if !GL.isSaver { updateTicker() } } }
    /// Ticks once a second while a timer runs, for the menu bar countdown.
    @Published private(set) var now = Date()
    private var ticker: Timer?

    var nextTimer: Activity? {
        items.filter { $0.kind == .timer && !$0.paused }.min { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "activities"),
           let saved = try? JSONDecoder().decode([Activity].self, from: data) { items = saved }
    }

    func start() { updateTicker() }

    /// Checks for finished timers only while one is counting down.
    private func updateTicker() {
        let running = items.contains { $0.kind == .timer && !$0.paused }
        if running, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.checkFinished()
                let second = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
                if second != self.now { self.now = second }
            }
            ticker?.tolerance = 0.2
        } else if !running {
            ticker?.invalidate(); ticker = nil
        }
    }

    func startTimer(minutes: Int, label: String = "") {
        let total = TimeInterval(minutes * 60)
        items.append(Activity(kind: .timer, label: label, total: total, end: Date().addingTimeInterval(total), pausedRemaining: total))
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func startStopwatch(label: String = "") {
        items.append(Activity(kind: .stopwatch, label: label, started: Date()))
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var a = items[i]
        let now = Date()
        switch (a.kind, a.paused) {
        case (.timer, true): a.end = now.addingTimeInterval(a.pausedRemaining)
        case (.timer, false): a.pausedRemaining = a.remaining(at: now)
        case (.stopwatch, true): a.started = now
        case (.stopwatch, false): a.accumulated = a.elapsed(at: now)
        }
        a.paused.toggle()
        items[i] = a
    }

    func cancel(_ id: UUID) { items.removeAll { $0.id == id } }

    private func checkFinished() {
        let now = Date()
        let done = items.filter { $0.kind == .timer && !$0.paused && ($0.end ?? .distantFuture) <= now }
        guard !done.isEmpty else { return }
        items.removeAll { a in done.contains { $0.id == a.id } }
        for a in done {
            NSSound(named: "Glass")?.play()
            let body = "Your \(formatHoursMinutes(a.total)) timer is done."
            Inbox.shared.add(.timer, title: a.displayLabel, body: body)
            let content = UNMutableNotificationContent()
            content.title = a.displayLabel
            content.body = body
            content.sound = .default
            if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id.uuidString, content: content, trigger: nil)) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "activities") }
    }
}

// MARK: - Battery

final class Battery: ObservableObject {
    static let shared = Battery()
    @Published var percent: Int?
    @Published var charging = false
    private var timer: Timer?

    func start() {
        refresh()
        // macOS calls back when the battery level or charging state changes; no polling needed.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Battery>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refresh() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { percent = nil; return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = cur * 100 / max
            charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            return
        }
        percent = nil
    }

    var symbol: String {
        guard let p = percent else { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch p { case 88...: return "battery.100"; case 63...: return "battery.75"; case 38...: return "battery.50"; case 13...: return "battery.25"; default: return "battery.0" }
    }
}

// MARK: - Shared formatting

func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    let h = s / 3600, m = (s / 60) % 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatHoursMinutes(_ t: TimeInterval) -> String {
    let m = Int((t / 60).rounded())
    return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
}

func compactNumber(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
    return "\(n)"
}
