import AppKit
import Combine

/// Owns Icicle's status items and the show/hide logic.
///
/// Menu bar layout, left to right:
///   [always-hidden items] ‹ [hidden items] ‹ [visible items] ❄ [system items]
///
/// Each divider is an NSStatusItem. To hide a section, its divider's length is set to a huge value,
/// which pushes every item to its left off the screen's left edge. The user places the dividers with ⌘-drag.
final class MenuBarManager: NSObject {
    var openSettings: ((SettingsTab) -> Void)?
    var snapFrontWindow: ((CGRect) -> Void)?

    private enum Name {
        static let first = "IcicleIcon"
        static let second = "IcicleHiddenDivider"
        static let alwaysHidden = "IcicleAlwaysHiddenDivider"
    }

    private static let collapsedLength: CGFloat = 10_000
    private static let hoverDwell: TimeInterval = 0.25
    private static let hoverExitGrace: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.1

    private let settings = AppSettings.shared

    // macOS decides where new status items appear and ignores requested positions, so neither item has a
    // fixed role: whichever sits further right is the Icicle icon, the other is the hidden-section divider.
    private let itemA: NSStatusItem
    private let itemB: NSStatusItem
    private var iconIsA = true
    private var iconItem: NSStatusItem { iconIsA ? itemA : itemB }
    private var hiddenDivider: NSStatusItem { iconIsA ? itemB : itemA }
    private var alwaysHiddenDivider: NSStatusItem?

    private(set) var isHiddenShown = true
    private(set) var isAlwaysHiddenShown = false
    private var revealedByHover = false

    private var rehideTimer: Timer?
    private var hoverTimer: Timer?
    private var hoverAccum: TimeInterval = 0
    private var hoverExitAccum: TimeInterval = 0
    private var didWarnAboutOrder = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let bar = NSStatusBar.system
        itemA = bar.statusItem(withLength: NSStatusItem.variableLength)
        itemA.autosaveName = Name.first
        itemB = bar.statusItem(withLength: NSStatusItem.variableLength)
        itemB.autosaveName = Name.second
        super.init()

        configure(itemA.button, action: #selector(primaryItemClicked(_:)))
        configure(itemB.button, action: #selector(primaryItemClicked(_:)))
    }

    func start() {
        syncAlwaysHiddenDivider()
        registerHotKeys()
        updateHoverPolling()
        updateLayout()

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsDidChange() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        if settings.hasCompletedOnboarding {
            // Status item windows aren't positioned until a later runloop pass; role assignment needs them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hideAll() }
        } else {
            settings.hasCompletedOnboarding = true
            openSettings?(.layout)
        }
    }

    // MARK: - Public actions

    func toggleHidden() {
        isHiddenShown ? hideAll() : showHidden()
    }

    func toggleAlwaysHidden() {
        guard let ah = alwaysHiddenDivider else { return }
        if isHiddenShown && isAlwaysHiddenShown {
            hideAll()
        } else {
            showHidden(includingAlwaysHidden: true)
            if !isOrdered(left: ah, right: hiddenDivider) { warnAboutOrder() }
        }
    }

    func showHidden(includingAlwaysHidden: Bool = false, byHover: Bool = false) {
        isHiddenShown = true
        if includingAlwaysHidden { isAlwaysHiddenShown = true }
        revealedByHover = byHover
        updateLayout()
        scheduleRehide()
    }

    func hideAll() {
        rehideTimer?.invalidate()
        isHiddenShown = false
        isAlwaysHiddenShown = false
        revealedByHover = false
        updateLayout()
    }

    // MARK: - Layout

    private func assignRoles() {
        guard let a = itemA.button?.window?.frame, let b = itemB.button?.window?.frame else { return }
        iconIsA = a.minX >= b.minX
    }

    private func updateLayout() {
        assignRoles()

        iconItem.length = NSStatusItem.variableLength
        iconItem.button?.appearsDisabled = false
        let symbol = isHiddenShown ? settings.iconStyle.visibleSymbol : settings.iconStyle.hiddenSymbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Icicle")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        iconItem.button?.image = image
        iconItem.button?.toolTip = "Click to show or hide menu bar items\n⌥-click for always-hidden items\nRight-click for options"

        hiddenDivider.button?.toolTip = "Icicle: items left of this are hidden. ⌘-drag to move."
        if isHiddenShown {
            expand(hiddenDivider, dimmed: false)
        } else {
            collapse(hiddenDivider)
        }

        if let ah = alwaysHiddenDivider {
            // Never collapse a divider sitting right of the hidden divider — it would swallow the hidden section.
            let ahCanCollapse = isOrdered(left: ah, right: hiddenDivider)
            if (isHiddenShown && isAlwaysHiddenShown) || !ahCanCollapse {
                expand(ah, dimmed: true)
            } else {
                collapse(ah)
            }
        }
    }

    private func expand(_ item: NSStatusItem, dimmed: Bool) {
        if settings.showSectionDividers {
            item.length = NSStatusItem.variableLength
            item.button?.image = Self.dividerImage
            item.button?.appearsDisabled = dimmed
        } else {
            item.button?.image = nil
            item.length = 0
        }
    }

    private func collapse(_ item: NSStatusItem) {
        item.button?.image = nil
        item.length = Self.collapsedLength
    }

    private static let dividerImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Section divider")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()

    /// Compares left edges. A collapsed divider's window keeps its on-screen origin and reports its huge
    /// width extending rightward, so right edges can't be trusted; left edges keep the true order either way.
    private func isOrdered(left: NSStatusItem, right: NSStatusItem) -> Bool {
        guard let l = left.button?.window?.frame, let r = right.button?.window?.frame else { return true }
        return l.minX < r.minX
    }

    private func warnAboutOrder() {
        guard !didWarnAboutOrder else { return }
        didWarnAboutOrder = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move the always-hidden divider"
        alert.informativeText = "The dimmed divider (‹) is to the right of the hidden-section divider, so it can't hide anything yet. Hold ⌘ and drag the dimmed divider further left."
        alert.runModal()
    }

    // MARK: - Always-hidden section

    private func syncAlwaysHiddenDivider() {
        if settings.alwaysHiddenEnabled, alwaysHiddenDivider == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Name.alwaysHidden
            configure(item.button, action: #selector(alwaysHiddenDividerClicked(_:)))
            item.button?.toolTip = "Icicle: items left of this are always hidden. ⌘-drag to move."
            alwaysHiddenDivider = item
        } else if !settings.alwaysHiddenEnabled, let item = alwaysHiddenDivider {
            NSStatusBar.system.removeStatusItem(item)
            alwaysHiddenDivider = nil
            isAlwaysHiddenShown = false
        }
    }

    // MARK: - Clicks

    private func configure(_ button: NSStatusBarButton?, action: Selector) {
        button?.target = self
        button?.action = action
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func isMenuClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    }

    @objc private func primaryItemClicked(_ sender: NSStatusBarButton) {
        assignRoles() // the user may have ⌘-dragged since the last layout
        if sender === iconItem.button {
            iconClicked()
        } else {
            hiddenDividerClicked()
        }
    }

    private func iconClicked() {
        guard let event = NSApp.currentEvent else { return }
        if isMenuClick(event) {
            showMenu(below: iconItem)
        } else if event.modifierFlags.contains(.option), alwaysHiddenDivider != nil {
            toggleAlwaysHidden()
        } else {
            toggleHidden()
        }
    }

    /// When collapsed, this divider is the blank stretch of menu bar left of the visible items,
    /// so clicking it is "clicking an empty part of the menu bar".
    private func hiddenDividerClicked() {
        guard let event = NSApp.currentEvent else { return }
        if isMenuClick(event) {
            showMenu(below: hiddenDivider)
        } else if isHiddenShown {
            hideAll()
        } else if settings.showOnClick {
            showHidden(includingAlwaysHidden: event.modifierFlags.contains(.option) && alwaysHiddenDivider != nil)
        }
    }

    @objc private func alwaysHiddenDividerClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, let ah = alwaysHiddenDivider else { return }
        if isMenuClick(event) {
            showMenu(below: ah)
        } else if isAlwaysHiddenShown {
            isAlwaysHiddenShown = false
            updateLayout()
        } else if event.modifierFlags.contains(.option) {
            showHidden(includingAlwaysHidden: true)
        } else if settings.showOnClick {
            hideAll()
        }
    }

    // MARK: - Menu

    private func showMenu(below item: NSStatusItem) {
        let menu = NSMenu()

        menu.addItem(menuItem(isHiddenShown ? "Hide Menu Bar Items" : "Show Hidden Items",
                              symbol: isHiddenShown ? "eye.slash" : "eye",
                              action: #selector(menuToggleHidden)))
        if alwaysHiddenDivider != nil {
            menu.addItem(menuItem(isAlwaysHiddenShown ? "Hide Always-Hidden Items" : "Show Always-Hidden Items",
                                  symbol: "eye.trianglebadge.exclamationmark",
                                  action: #selector(menuToggleAlwaysHidden)))
        }

        menu.addItem(.separator())
        let snapItem = menuItem("Snap Front Window", symbol: "rectangle.split.2x1", action: nil)
        snapItem.submenu = snapMenu()
        menu.addItem(snapItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Arrange Menu Bar…", symbol: "menubar.rectangle", action: #selector(menuOpenLayout)))
        menu.addItem(menuItem("Settings…", symbol: "gearshape", action: #selector(menuOpenSettings), key: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Icicle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbolImage("power")
        menu.addItem(quit)

        // Pop up at the cursor: a collapsed divider's own origin is thousands of points off-screen.
        let barBottom = item.button?.window?.frame.minY ?? NSEvent.mouseLocation.y
        menu.popUp(positioning: nil, at: NSPoint(x: NSEvent.mouseLocation.x, y: barBottom - 4), in: nil)
    }

    private func snapMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, String, CGRect)] = [
            ("Left Half", "rectangle.lefthalf.filled", SnapLayout.Zone.leftHalf),
            ("Right Half", "rectangle.righthalf.filled", SnapLayout.Zone.rightHalf),
            ("Top Left", "rectangle.inset.topleft.filled", SnapLayout.Zone.topLeft),
            ("Top Right", "rectangle.inset.topright.filled", SnapLayout.Zone.topRight),
            ("Bottom Left", "rectangle.inset.bottomleft.filled", SnapLayout.Zone.bottomLeft),
            ("Bottom Right", "rectangle.inset.bottomright.filled", SnapLayout.Zone.bottomRight),
            ("Fill Screen", "rectangle.inset.filled", SnapLayout.Zone.full),
        ]
        for (index, (title, symbol, zone)) in entries.enumerated() {
            if index == entries.count - 1 { menu.addItem(.separator()) }
            let item = menuItem(title, symbol: symbol, action: #selector(menuSnap(_:)))
            item.representedObject = NSValue(rect: zone)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let dragItem = NSMenuItem(title: "Let Icicle Handle Window Dragging",
                                  action: #selector(menuToggleSystemDrag), keyEquivalent: "")
        dragItem.target = self
        dragItem.state = SystemDragSettings.icicleHandlesDrags ? .on : .off
        menu.addItem(dragItem)
        return menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbolImage(symbol)
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func menuToggleHidden() { toggleHidden() }
    @objc private func menuToggleAlwaysHidden() {
        if isAlwaysHiddenShown {
            isAlwaysHiddenShown = false
            updateLayout()
        } else {
            showHidden(includingAlwaysHidden: true)
        }
    }
    @objc private func menuOpenLayout() { openSettings?(.layout) }
    @objc private func menuOpenSettings() { openSettings?(.general) }
    @objc private func menuSnap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else { return }
        snapFrontWindow?(value.rectValue)
    }
    @objc private func menuToggleSystemDrag() {
        SystemDragSettings.setIcicleHandlesDrags(!SystemDragSettings.icicleHandlesDrags)
    }

    // MARK: - Auto-rehide

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        guard settings.autoRehide, settings.rehideStrategy == .timed, !revealedByHover else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: settings.rehideDelay, repeats: false) { [weak self] _ in
            self?.attemptRehide()
        }
    }

    /// Defers while the user is still using the menu bar so items don't vanish out from under them.
    private func attemptRehide() {
        guard isHiddenShown else { return }
        if isMouseInMenuBar() || isMenuOpen() {
            rehideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                self?.attemptRehide()
            }
            return
        }
        hideAll()
    }

    @objc private func frontmostAppChanged(_ note: Notification) {
        guard settings.autoRehide, settings.rehideStrategy == .focusedApp,
              isHiddenShown, !revealedByHover else { return }
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        // Some menu bar items activate their app when clicked; give the menu a moment to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isMenuOpen(), !self.isMouseInMenuBar() else { return }
            self.hideAll()
        }
    }

    // MARK: - Show on hover

    private func updateHoverPolling() {
        if settings.showOnHover, hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.hoverTick()
            }
        } else if !settings.showOnHover {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func hoverTick() {
        let mouse = NSEvent.mouseLocation
        let inBar = isMouseInMenuBar()

        if !isHiddenShown {
            hoverExitAccum = 0
            if inBar, isOverEmptyMenuBarSpace(mouse) {
                hoverAccum += Self.pollInterval
                if hoverAccum >= Self.hoverDwell {
                    hoverAccum = 0
                    showHidden(byHover: true)
                }
            } else {
                hoverAccum = 0
            }
        } else if revealedByHover {
            hoverAccum = 0
            if !inBar, !isMenuOpen() {
                hoverExitAccum += Self.pollInterval
                if hoverExitAccum >= Self.hoverExitGrace {
                    hoverExitAccum = 0
                    hideAll()
                }
            } else {
                hoverExitAccum = 0
            }
        }
    }

    /// Empty space = left of the hidden divider's right edge but past the frontmost app's menus.
    /// Finding the app menus needs Accessibility; without it, hover is disabled rather than firing over File/Edit/View.
    private func isOverEmptyMenuBarSpace(_ point: NSPoint) -> Bool {
        guard let divider = hiddenDivider.button?.window?.frame, point.x <= divider.maxX else { return false }
        guard let menusEnd = AccessibilityAccess.frontmostAppMenusMaxX() else { return false }
        return point.x > menusEnd + 8
    }

    // MARK: - Environment checks

    private func isMouseInMenuBar() -> Bool {
        guard let window = iconItem.button?.window, let screen = window.screen else { return false }
        let mouse = NSEvent.mouseLocation
        return mouse.y >= window.frame.minY && mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
    }

    /// Window layer and bounds are readable without Screen Recording permission.
    private func isMenuOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    // MARK: - Settings

    private func settingsDidChange() {
        let wasEnabled = alwaysHiddenDivider != nil
        syncAlwaysHiddenDivider()
        // A new divider can appear anywhere; reveal everything so it can be placed.
        if !wasEnabled, alwaysHiddenDivider != nil {
            showHidden(includingAlwaysHidden: true)
        }
        registerHotKeys()
        updateHoverPolling()
        updateLayout()
        if isHiddenShown { scheduleRehide() }
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.register(id: 1, combo: settings.toggleHiddenHotKey) { [weak self] in
            self?.toggleHidden()
        }
        HotKeyCenter.shared.register(id: 2, combo: settings.alwaysHiddenEnabled ? settings.toggleAlwaysHiddenHotKey : nil) { [weak self] in
            self?.toggleAlwaysHidden()
        }
    }
}
