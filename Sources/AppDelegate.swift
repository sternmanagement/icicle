import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: MenuBarManager!
    private let snapper = WindowSnapper()
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        manager = MenuBarManager()
        manager.openSettings = { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        manager.snapFrontWindow = { [weak self] zone in self?.snapper.snapFocusedWindow(to: zone) }
        settingsWindow.itemsModel.manager = manager
        settingsWindow.showAllItems = { [weak self] in self?.manager.showHidden(includingAlwaysHidden: true) }
        snapper.start()
        manager.start()
    }

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
