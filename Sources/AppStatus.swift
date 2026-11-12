import SwiftUI
import Combine
import ServiceManagement

/// One line of the "is everything working?" checklist shown in the ❄ menu and in Settings.
struct StatusItem: Identifiable {
    enum State { case ok, problem, off }
    let id: String
    let name: String
    let state: State
    let detail: String
    var fixTitle: String? = nil
    var fix: (() -> Void)? = nil

    var symbol: String { switch state { case .ok: "checkmark.circle.fill"; case .problem: "exclamationmark.triangle.fill"; case .off: "minus.circle" } }
    var color: Color { switch state { case .ok: .green; case .problem: .orange; case .off: .secondary } }
}

/// Watches everything Icicle depends on (permissions, the login item, the lock screen's pieces) and turns it into a checklist.
final class AppStatus: ObservableObject {
    static let shared = AppStatus()
    @Published private(set) var items: [StatusItem] = []
    private var observers: [Any] = []

    var problems: Int { items.filter { $0.state == .problem }.count }

    func start() {
        refresh()
        // Re-check whenever any of the things it reports on change, and when you come back to the app.
        let objects: [any ObservableObject] = [LockScreenSetup.shared, SystemNotifications.shared, EventsService.shared,
                                               WeatherService.shared, ClaudeUsage.shared, FaceStore.shared]
        for o in objects {
            if let p = (o as? LockScreenSetup)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
            if let p = (o as? SystemNotifications)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
            if let p = (o as? EventsService)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
            if let p = (o as? WeatherService)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
            if let p = (o as? ClaudeUsage)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
            if let p = (o as? FaceStore)?.objectWillChange { observers.append(p.sink { [weak self] _ in self?.refreshSoon() }) }
        }
        observers.append(Inbox.shared.objectWillChange.sink { [weak self] _ in self?.refreshSoon() })
        observers.append(AppSettings.shared.objectWillChange.sink { [weak self] _ in self?.refreshSoon() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            LockScreenSetup.shared.refresh(); SystemNotifications.shared.refresh()
        })
    }

    private var pending = false
    private func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { self.pending = false; self.refresh() }
    }

    func checkAgain() {
        LockScreenSetup.shared.refresh()
        SystemNotifications.shared.refresh()
        WeatherService.shared.refresh()
        EventsService.shared.refresh()
        refresh()
    }

    func refresh() {
        let setup = LockScreenSetup.shared, notes = SystemNotifications.shared
        let events = EventsService.shared, weather = WeatherService.shared, claude = ClaudeUsage.shared
        let face = FaceStore.shared.active
        let kinds = Set(face.widgets.map(\.kind))
        let settings = AppSettings.shared
        var list: [StatusItem] = []

        // Accessibility, for everything that looks at or moves other apps' windows and icons
        if AccessibilityAccess.isTrusted {
            list.append(.init(id: "ax", name: "Accessibility", state: .ok, detail: "Window snapping and the menu bar layout can work"))
        } else {
            list.append(.init(id: "ax", name: "Accessibility", state: .problem, detail: "Needed for window snapping and arranging menu bar icons",
                              fixTitle: "Allow…", fix: { AccessibilityAccess.request() }))
        }

        // Opens at login
        if SMAppService.mainApp.status == .enabled {
            list.append(.init(id: "login", name: "Opens at login", state: .ok, detail: "Icicle is there after every restart"))
        } else {
            list.append(.init(id: "login", name: "Opens at login", state: settings.lockScreenEnabled ? .problem : .off,
                              detail: settings.lockScreenEnabled ? "The lock screen won't update after a restart" : "Icicle won't start by itself after a restart",
                              fixTitle: "Turn On", fix: { try? SMAppService.mainApp.register(); AppStatus.shared.refresh() }))
        }

        // Everything below belongs to the lock screen.
        guard settings.lockScreenEnabled else { items = list; return }

        if !setup.isInstalled {
            list.append(.init(id: "lock", name: "Lock screen", state: .problem, detail: "Not set up yet",
                              fixTitle: "Set Up…", fix: { setup.install() }))
        } else if !setup.isSelected {
            list.append(.init(id: "lock", name: "Lock screen", state: .problem, detail: "Not chosen in Screen Saver settings",
                              fixTitle: "Choose…", fix: { setup.openSettings() }))
        } else {
            let shortcut = settings.lockNowHotKey.map { "with \($0.displayString), " } ?? ""
            list.append(.init(id: "lock", name: "Lock screen", state: .ok, detail: "Shows when you lock \(shortcut)from the ❄ menu or when idle"))
        }

        // Notifications from other apps
        switch notes.access {
        case .granted:
            let n = Inbox.shared.system.count
            list.append(.init(id: "notes", name: "Notifications from your apps", state: .ok,
                              detail: n == 0 ? "Connected; nothing new" : "\(n) showing"))
        case .needsFullDiskAccess:
            list.append(.init(id: "notes", name: "Notifications from your apps", state: .problem, detail: "Needs Full Disk Access",
                              fixTitle: "Allow…", fix: { notes.openFullDiskAccessSettings() }))
        case .unknown:
            list.append(.init(id: "notes", name: "Notifications from your apps", state: .off, detail: "Checking…"))
        }

        // Widgets that need permissions, only when they're on the current lock screen
        let usesCalendar = kinds.contains(.calendar) || face.inline == .nextEvent
        if usesCalendar {
            switch events.calendarAccess {
            case true?: list.append(.init(id: "cal", name: "Calendar", state: .ok, detail: "\(events.events.count) upcoming"))
            case false?: list.append(.init(id: "cal", name: "Calendar", state: .problem, detail: "Access was turned off",
                                           fixTitle: "Allow…", fix: { Self.openPrivacy("Privacy_Calendars") }))
            case nil: list.append(.init(id: "cal", name: "Calendar", state: .off, detail: "Checking…"))
            }
        }
        if kinds.contains(.reminders) {
            switch events.reminderAccess {
            case true?: list.append(.init(id: "rem", name: "Reminders", state: .ok, detail: "\(events.reminderCount) open"))
            case false?: list.append(.init(id: "rem", name: "Reminders", state: .problem, detail: "Access was turned off",
                                           fixTitle: "Allow…", fix: { Self.openPrivacy("Privacy_Reminders") }))
            case nil: list.append(.init(id: "rem", name: "Reminders", state: .off, detail: "Checking…"))
            }
        }
        let usesWeather = kinds.contains(.weather) || kinds.contains(.sunrise) || [.dateWeather, .sunrise].contains(face.inline)
        if usesWeather {
            if let t = weather.temperature {
                list.append(.init(id: "weather", name: "Weather", state: .ok, detail: "\(t)°\(weather.place.isEmpty ? "" : " in \(weather.place)")"))
            } else if let problem = weather.problem {
                list.append(.init(id: "weather", name: "Weather", state: .problem, detail: problem,
                                  fixTitle: "Location…", fix: { Self.openPrivacy("Privacy_LocationServices") }))
            } else {
                list.append(.init(id: "weather", name: "Weather", state: .off, detail: "Loading…"))
            }
        }

        // Claude Code
        list.append(claude.available
            ? .init(id: "claude", name: "Claude Code", state: .ok, detail: claude.isWorking ? "Working now" : "\(claude.sessions.count) session\(claude.sessions.count == 1 ? "" : "s") today")
            : .init(id: "claude", name: "Claude Code", state: .off, detail: "No activity found today"))

        items = list
    }

    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

/// The checklist as a Settings section.
struct StatusSection: View {
    @ObservedObject private var status = AppStatus.shared

    var body: some View {
        Section {
            ForEach(status.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let title = item.fixTitle, let fix = item.fix {
                        Button(title, action: fix)
                    }
                }
            }
        } header: {
            HStack {
                Text("Status")
                Spacer()
                Button("Check Again") { status.checkAgain() }.buttonStyle(.link).font(.caption)
            }
        } footer: {
            Text(status.problems == 0 ? "Everything is working." : "\(status.problems) thing\(status.problems == 1 ? " needs" : "s need") attention.")
        }
    }
}
