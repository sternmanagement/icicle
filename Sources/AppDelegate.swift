import AppKit
import Carbon.HIToolbox
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var manager: MenuBarManager!
    private let snapper = WindowSnapper()
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        manager = MenuBarManager()
        manager.openSettings = { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        manager.snapFrontWindow = { [weak self] zone in self?.snapper.snapFocusedWindow(to: zone) }
        settingsWindow.itemsModel.manager = manager
        manager.requestEndArranging = { [weak self] in self?.settingsWindow.itemsModel.stopEditing() }
        settingsWindow.showAllItems = { [weak self] in self?.manager.showHidden(includingAlwaysHidden: true) }
        snapper.start()
        manager.start()
        extras.start()
        appearance.ownIconMinX = { [weak self] in self?.manager.iconFrame?.minX }
        appearance.hiddenItemsBoundary = { [weak self] in self?.manager.hiddenItemsBoundary }
        appearance.start()
        focusBorder.start()
        screenCorners.start()
        dimmer.start()

        // Finished timers notify even while one of Icicle's own windows is in front.
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        let lockScreen = LockScreenFeature.shared
        lockScreen.setIconTitle = { [weak self] in self?.manager.iconTitle = $0 }
        lockScreen.openSettings = { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        manager.extraMenuItems = { lockScreen.menuItems() }
        lockScreen.start()

        let corners = HotCorners.shared
        corners.toggleMenuBarItems = { [weak self] in self?.manager.toggleHidden() }
        corners.toggleClipboard = { [weak self] in self?.extras.toggleClipboard() }
        corners.start()

        // First launch, or the first one after an update that needs something new: walk through setup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            AppLocation.offerMoveIfNeeded()
            if SetupWindow.needsShowing { SetupWindow.show() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private let appearance = MenuBarAppearance()
    private let focusBorder = FocusBorder()
    private let screenCorners = ScreenCorners()
    private let dimmer = BackgroundDimmer()

    private let extras = Extras()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(tab: .general)
        return false
    }

    // Accessory apps show no menu bar, but key equivalents (⌘W, ⌘Q, copy/paste) still route through mainMenu.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Icicle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

/// The optional features beyond the menu bar and snapping. Each follows its setting live.
final class Extras {
    private let settings = AppSettings.shared
    private let clipboardPicker = ClipboardPicker()
    private let windowSwitcher = WindowSwitcher()
    private var cancellables = Set<AnyCancellable>()

    func start() {
        settings.objectWillChange.merge(with: WorkspaceStore.shared.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        apply()
    }

    func toggleClipboard() {
        if settings.clipboardEnabled { clipboardPicker.toggle() }
    }

    private func apply() {
        ClipboardHistory.shared.setEnabled(settings.clipboardEnabled)
        HotKeyCenter.shared.register(id: 20, combo: settings.clipboardEnabled ? settings.clipboardHotKey : nil) { [weak self] in
            self?.clipboardPicker.toggle()
        }

        let switcherCombo = settings.windowSwitcherEnabled ? settings.windowSwitcherHotKey : nil
        HotKeyCenter.shared.register(id: 30, combo: switcherCombo) { [weak self] in
            if let switcherCombo { self?.windowSwitcher.advance(backwards: false, combo: switcherCombo) }
        }
        HotKeyCenter.shared.register(id: 31, combo: switcherCombo?.withShift) { [weak self] in
            if let switcherCombo { self?.windowSwitcher.advance(backwards: true, combo: switcherCombo) }
        }

        let store = WorkspaceStore.shared
        for (index, keyCode) in WorkspaceStore.numberKeyCodes.enumerated() {
            let enabled = settings.workspacesEnabled && settings.workspaceHotKeysEnabled && index < store.workspaces.count
            let combo = KeyCombo(keyCode: UInt32(keyCode), carbonModifiers: UInt32(controlKey | optionKey), keyName: "\(index + 1)")
            HotKeyCenter.shared.register(id: 40 + UInt32(index), combo: enabled ? combo : nil) {
                if store.workspaces.indices.contains(index) { store.restore(store.workspaces[index]) }
            }
        }
    }
}
