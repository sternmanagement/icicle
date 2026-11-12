import AppKit
import ServiceManagement

/// Puts the lock screen on the real macOS lock screen. Apps can't replace the login window, but macOS shows the
/// screen saver on top of it, so Icicle ships a screen saver ("Glass Lock.saver") built from the same views.
/// It keeps the name it had as a separate app, so an existing choice in System Settings carries over.
final class LockScreenSetup: ObservableObject {
    static let shared = LockScreenSetup()

    @Published private(set) var isInstalled = false

    private var bundled: URL? { Bundle.main.url(forResource: "Glass Lock", withExtension: "saver") }
    private var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/Glass Lock.saver")
    }

    func start() {
        refresh()
        updateInstalledCopy()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in Live.locked = false }
        dnc.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { _ in Live.locked = true }
        dnc.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { _ in
            // Stopping the screen saver leads to the password prompt; screenIsUnlocked follows once it's entered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !Self.screenIsLocked() { Live.locked = false } }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Live.locked = true
            SnapshotWriter.shared.write()
            guard LockHooks.isEnabled(), Prefs.shared.saverOnLock, self?.isSelected == true else { return }
            // Locking with ⌃⌘Q or the Apple menu shows the plain login window; start Glass Lock on top of it.
            self?.startScreenSaver()
        }
    }

    /// Whether macOS has Glass Lock chosen as its screen saver (System Settings → Screen Saver). Read only.
    @Published private(set) var isSelected = false

    static func screenIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: installed.path)
        isSelected = isInstalled && Self.chosenScreenSaver()?.contains("Glass%20Lock.saver") == true
    }

    /// Since macOS 14 the screen saver choice is stored with the wallpaper settings.
    private static func chosenScreenSaver() -> String? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = root["AllSpacesAndDisplays"] as? [String: Any],
              let content = (all["Idle"] as? [String: Any])?["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              let config = choice["Configuration"] as? Data, !config.isEmpty,
              let decoded = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any]
        else { return nil }
        return ((decoded["module"] as? [String: Any])?["relative"] as? String) ?? "\(decoded)"
    }

    /// Opens the bundled screen saver, which makes macOS offer to install it and select it in System Settings.
    func install() {
        guard let bundled else { return }
        // The lock screen gets its live data from the app, so keep the app running.
        try? SMAppService.mainApp.register()
        NSWorkspace.shared.open(bundled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.refresh() }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func openLockSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Locks the Mac by starting the screen saver (macOS asks for the password right away when it ends).
    func lockNow() {
        SnapshotWriter.shared.write()
        refresh()
        if isSelected { startWhenHandsOff() } else { LockHooks.openSettings() }   // finish setup first
    }

    /// Any key or mouse event ends a screen saver, including letting go of ⌃⌥⌘L or the click on Lock Now.
    /// Wait until no keys or buttons are held and the pointer has settled, then start it.
    func startWhenHandsOff(deadline: Date = Date().addingTimeInterval(5)) {
        let anyInput = CGEventType(rawValue: ~0)!
        let quietFor = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let held = !NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty || NSEvent.pressedMouseButtons != 0
        if (!held && quietFor > 0.6) || Date() > deadline {
            startScreenSaver()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.startWhenHandsOff(deadline: deadline) }
        }
    }

    func startScreenSaver() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
    }

    /// After the app updates, refresh the copy in ~/Library/Screen Savers so it matches.
    private func updateInstalledCopy() {
        guard isInstalled, let bundled,
              let new = Bundle(url: bundled)?.infoDictionary?["CFBundleVersion"] as? String,
              let old = Bundle(url: installed)?.infoDictionary?["CFBundleVersion"] as? String, new != old else { return }
        let fm = FileManager.default
        let temp = installed.deletingLastPathComponent().appendingPathComponent(".Glass Lock.saver.new")
        try? fm.removeItem(at: temp)
        guard (try? fm.copyItem(at: bundled, to: temp)) != nil else { return }
        removexattr(temp.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        _ = try? fm.replaceItemAt(installed, withItemAt: temp)
    }
}
