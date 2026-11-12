import AppKit
import Carbon.HIToolbox
import Combine

/// Brings over settings from Glass Lock, the standalone app Icicle's lock screen used to be:
/// lock screen designs, timers, the hot corner and the shortcut. Runs once, before any setting is read.
enum GlassLockMigration {
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedGlassLock") else { return }
        d.set(true, forKey: "migratedGlassLock")

        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        guard let file = files.first(where: { $0.hasPrefix("io.github.") && $0.hasSuffix(".glasslock.plist") }),
              let values = d.persistentDomain(forName: String(file.dropLast(".plist".count))), !values.isEmpty else { return }

        for key in ["faces", "activeFace", "activities", "inbox", "hotCorner", "use24h", "displayName", "weatherCity",
                    "saverOnLock", "dismissedSystemNotifications"] {
            if let value = values[key] { d.set(value, forKey: key) }
        }
        // Glass Lock stored its shortcut with different field names.
        struct OldShortcut: Decodable { var keyCode: UInt32; var modifiers: UInt32; var key: String }
        if let data = values["openShortcut"] as? Data, let old = try? JSONDecoder().decode(OldShortcut.self, from: data),
           let combo = try? JSONEncoder().encode(KeyCombo(keyCode: old.keyCode, carbonModifiers: old.modifiers, keyName: old.key)) {
            d.set(combo, forKey: "lockScreenOpenHotKey")
        } else if values["openShortcutOff"] as? Bool == true {
            d.set(Data(), forKey: "lockScreenOpenHotKey")
        }
        // Someone who used Glass Lock wants the lock screen on.
        d.set(true, forKey: "lockScreenEnabled")
    }

    /// Two copies would fight over the hot corner, the shortcuts and the lock screen's data.
    static func retireStandaloneApp() {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, id.hasPrefix("io.github."), id.hasSuffix(".glasslock") else { continue }
            app.terminate()
        }
    }
}

/// The lock screen (formerly Glass Lock) inside Icicle: starts its services, registers its shortcuts and
/// adds its entries to the ❄ menu. Everything follows the "Lock screen" switch in Settings live.
final class LockScreenFeature {
    static let shared = LockScreenFeature()

    /// Shows a running timer's countdown beside the ❄ icon.
    var setIconTitle: ((String?) -> Void)?
    var openSettings: ((SettingsTab) -> Void)?

    private let settings = AppSettings.shared
    private var servicesStarted = false
    private var cancellables = Set<AnyCancellable>()

    private struct Applied: Equatable {
        var enabled: Bool
        var lockNow: KeyCombo?
        var open: KeyCombo?
        var takesOverSystemLock: Bool
    }
    private var applied: Applied?

    func start() {
        LockHooks.isEnabled = { AppSettings.shared.lockScreenEnabled }
        LockHooks.openSettings = { [weak self] in self?.openSettings?(.lockScreen) }
        Updater.shared.start()
        AppStatus.shared.start()

        let changes: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(),
            Prefs.shared.objectWillChange.eraseToAnyPublisher(),
            LockScreenSetup.shared.objectWillChange.eraseToAnyPublisher(),
            Activities.shared.objectWillChange.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            if self?.settings.lockScreenEnabled == true { GlassLockMigration.retireStandaloneApp() }
        }
        apply()
    }

    private func apply() {
        let enabled = settings.lockScreenEnabled
        if enabled, !servicesStarted {
            servicesStarted = true
            GlassLockMigration.retireStandaloneApp()
            ClaudeUsage.shared.start()
            NowPlaying.shared.start()
            Battery.shared.start()
            Activities.shared.start()
            SystemNotifications.shared.start()
            SnapshotWriter.shared.start()
            LockScreenSetup.shared.start()
        }

        // macOS's own Lock Screen shortcut, ⌃⌘Q, is only taken over once the lock screen can actually show:
        // a plain macOS lock puts up Apple's lock screen first, and nothing can be drawn over that.
        let state = Applied(enabled: enabled, lockNow: settings.lockNowHotKey, open: settings.lockScreenOpenHotKey,
                            takesOverSystemLock: enabled && Prefs.shared.saverOnLock && LockScreenSetup.shared.isSelected)
        if state != applied {
            applied = state
            HotKeyCenter.shared.register(id: 50, combo: enabled ? state.lockNow : nil) { Self.lockOrDismiss() }
            HotKeyCenter.shared.register(id: 51, combo: enabled ? state.open : nil) { LockController.shared.toggle() }
            let systemLock = KeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(controlKey | cmdKey), keyName: "Q")
            HotKeyCenter.shared.register(id: 52, combo: state.takesOverSystemLock ? systemLock : nil) { Self.lockOrDismiss() }
            if !enabled { LockController.shared.hide() }
        }

        let timer = enabled ? Activities.shared.nextTimer : nil
        setIconTitle?(timer.map { formatDuration($0.remaining(at: Date())) })
    }

    private static func lockOrDismiss() {
        if LockController.shared.isShowing { LockController.shared.hide() } else { LockScreenSetup.shared.lockNow() }
    }

    // MARK: - ❄ menu

    func menuItems() -> (feature: [NSMenuItem], app: [NSMenuItem]) {
        var app: [NSMenuItem] = []
        if case .available(let version) = Updater.shared.status {
            app.append(ActionMenuItem("Update to \(version)…", symbol: "arrow.down.circle") { Updater.shared.promptInstall() })
        } else {
            app.append(ActionMenuItem("Check for Updates…", symbol: "arrow.triangle.2.circlepath") { Updater.shared.check(userInitiated: true) })
        }
        guard settings.lockScreenEnabled else { return ([], app) }

        var feature: [NSMenuItem] = []
        let lock = ActionMenuItem("Lock Now", symbol: "lock.fill") { LockScreenSetup.shared.lockNow() }
        lock.setShortcut(settings.lockNowHotKey)
        feature.append(lock)

        let screen = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        screen.image = NSImage(systemSymbolName: "lock.display", accessibilityDescription: nil)
        screen.submenu = lockScreenMenu()
        feature.append(screen)

        let timers = NSMenuItem(title: "Timers", action: nil, keyEquivalent: "")
        timers.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        timers.submenu = timersMenu()
        feature.append(timers)

        let claude = ClaudeUsage.shared
        if claude.available {
            let project = claude.currentSession?.project ?? ""
            let state = claude.isWorking ? "working" + (project.isEmpty ? "" : " on \(project)") : "idle"
            let today = "\(compactNumber(claude.totalTokens)) tokens · \(claude.sessions.count) session\(claude.sessions.count == 1 ? "" : "s") today"
            let item = NSMenuItem(title: "Claude Code: \(state) · \(today)", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            item.isEnabled = false
            feature.append(item)
        }
        return (feature, app)
    }

    private func lockScreenMenu() -> NSMenu {
        let menu = NSMenu()
        let open = ActionMenuItem("Open on Desktop", symbol: "rectangle.inset.filled") { LockController.shared.show() }
        open.setShortcut(settings.lockScreenOpenHotKey)
        menu.addItem(open)
        menu.addItem(ActionMenuItem("Customize…", symbol: "paintpalette") { CustomizeWindow.show() })
        menu.addItem(.separator())

        let store = FaceStore.shared
        for face in store.faces {
            let item = ActionMenuItem(face.name) { store.activeId = face.id }
            item.state = store.activeId == face.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let status = AppStatus.shared
        let summary = NSMenuItem(title: status.problems == 0 ? "Everything Is Working"
                                 : "\(status.problems) Thing\(status.problems == 1 ? " Needs" : "s Need") Attention",
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        for entry in status.items where entry.state == .problem {
            if let fix = entry.fix, let title = entry.fixTitle {
                menu.addItem(ActionMenuItem("\(entry.name): \(entry.detail) — \(title)", symbol: "exclamationmark.triangle", handler: fix))
            } else {
                let item = NSMenuItem(title: "\(entry.name): \(entry.detail)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Lock Screen Settings…", symbol: "gearshape") { [weak self] in self?.openSettings?(.lockScreen) })
        return menu
    }

    private func timersMenu() -> NSMenu {
        let menu = NSMenu()
        let activities = Activities.shared
        let now = Date()
        for activity in activities.items {
            let item = NSMenuItem(title: "\(activity.displayLabel) · \(activity.statusText(at: now))", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: activity.kind == .timer ? "timer" : "stopwatch", accessibilityDescription: nil)
            let sub = NSMenu()
            sub.addItem(ActionMenuItem(activity.paused ? "Resume" : "Pause", symbol: activity.paused ? "play.fill" : "pause.fill") {
                activities.toggle(activity.id)
            })
            sub.addItem(ActionMenuItem(activity.kind == .timer ? "Cancel" : "Stop", symbol: "xmark") { activities.cancel(activity.id) })
            item.submenu = sub
            menu.addItem(item)
        }
        if !activities.items.isEmpty { menu.addItem(.separator()) }

        let header = NSMenuItem(title: "Start a Timer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for minutes in [1, 3, 5, 10, 15, 25, 45, 60] {
            menu.addItem(ActionMenuItem(minutes == 60 ? "1 hour" : "\(minutes) min") { activities.startTimer(minutes: minutes) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Start Stopwatch", symbol: "stopwatch") { activities.startStopwatch() })
        return menu
    }
}

/// A menu item that runs a closure, for menus built outside the object that owns them.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }

    /// Shows a global shortcut beside the item when it's a plain letter or digit.
    func setShortcut(_ combo: KeyCombo?) {
        guard let combo, combo.keyName.count == 1, let scalar = combo.keyName.lowercased().unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return }
        keyEquivalent = combo.keyName.lowercased()
        var flags: NSEvent.ModifierFlags = []
        if combo.carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if combo.carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if combo.carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if combo.carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        keyEquivalentModifierMask = flags
    }
}
