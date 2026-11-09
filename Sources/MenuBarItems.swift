import AppKit
import Carbon.HIToolbox

enum MenuBarSection: String, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible: return "Visible"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        }
    }
}

/// Another app's status item, as reported by its Accessibility "extras menu bar".
struct MenuBarItem: Identifiable, Equatable {
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    /// e.g. "com.apple.menuextra.clock"; empty for most third-party items.
    let identifier: String
    /// Position among the app's own items; tells apart apps with several items and no titles.
    let index: Int
    /// AX coordinates (origin top-left of the primary display). x matches Cocoa x.
    let frame: CGRect
    let image: NSImage?

    // Identifiers are stable where titles aren't (the clock's title is the time).
    var id: String { "\(bundleID ?? appName)|\(identifier.isEmpty ? title : identifier)|\(index)" }

    var icon: NSImage? {
        if let image { return image }
        // Apple's items all belong to one background process with a generic icon; use their symbols instead.
        if identifier.hasPrefix("com.apple.menuextra.") {
            let symbols = ["battery": "battery.75percent", "clock": "clock", "controlcenter": "switch.2", "wifi": "wifi",
                           "bluetooth": "dot.radiowaves.left.and.right", "sound": "speaker.wave.2", "focus": "moon",
                           "display": "display", "airdrop": "airplayaudio", "spotlight": "magnifyingglass", "siri": "mic",
                           "timemachine": "clock.arrow.circlepath", "textinput": "keyboard", "nowplaying": "play.circle"]
            let name = identifier.replacingOccurrences(of: "com.apple.menuextra.", with: "")
            if let symbol = symbols[name], let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                return image
            }
        }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// Apple's own items (battery, Wi-Fi, clock…) as opposed to third-party apps'.
    var isApple: Bool { bundleID?.hasPrefix("com.apple.") ?? false }

    /// macOS parks items it has no room for (in its overflow menu) far below the menu bar.
    var isInSystemOverflow: Bool { frame.minY > 100 }

    /// The clock and Control Center are pinned to the right end of the menu bar by macOS, and so is
    /// macOS 27's own "Show Hidden Menu Bar Items" button (a menu bar agent item with no identifier).
    var isMovable: Bool {
        if bundleID == "com.apple.MenuBarAgent", identifier.isEmpty { return false }
        return !["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(identifier)
    }

    static func == (a: MenuBarItem, b: MenuBarItem) -> Bool { a.id == b.id && a.frame == b.frame }
}

enum MenuBarItemScanner {
    static func scan() -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var items: [MenuBarItem] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.15)
            guard let extras = axApp.element("AXExtrasMenuBar") else { continue }
            let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
            for (index, child) in extras.elements(kAXChildrenAttribute).enumerated() {
                // System items come wrapped in a group; the details live on the menu bar item inside.
                let leaf = child.string(kAXRoleAttribute) == kAXMenuBarItemRole ? child
                    : child.elements(kAXChildrenAttribute).first { $0.string(kAXRoleAttribute) == kAXMenuBarItemRole } ?? child
                guard let frame = leaf.axFrame ?? child.axFrame, frame.width > 0 else { continue }
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { leaf.string($0) ?? child.string($0) }
                    .first { !$0.isEmpty } ?? appName
                items.append(MenuBarItem(pid: app.processIdentifier, appName: appName, bundleID: app.bundleIdentifier,
                                         title: label, identifier: leaf.string(kAXIdentifierAttribute) ?? "",
                                         index: index, frame: frame, image: image(of: leaf)))
            }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func image(of element: AXUIElement) -> NSImage? {
        guard let value = element.value("AXImageData") else { return nil }
        if let data = value as? Data, let image = NSImage(data: data) { return image }
        if CFGetTypeID(value) == CGImage.typeID { return NSImage(cgImage: value as! CGImage, size: .zero) }
        return nil
    }
}

/// Where Icicle's dividers sit, used to tell which section another app's item is in.
struct DividerFrames {
    var hidden: CGRect?
    var alwaysHidden: CGRect?

    func section(of item: MenuBarItem) -> MenuBarSection {
        guard let hidden, item.frame.midX < hidden.minX else { return .visible }
        if let alwaysHidden, item.frame.midX < alwaysHidden.minX { return .alwaysHidden }
        return .hidden
    }

    /// Where to drop an item so it lands in `target`: just inside the divider it has to cross.
    /// Divider frames are only meaningful while every section is expanded.
    func dropPoint(from current: MenuBarSection, to target: MenuBarSection, y: CGFloat) -> CGPoint? {
        let order: [MenuBarSection] = [.alwaysHidden, .hidden, .visible]
        let movingRight = order.firstIndex(of: target)! > order.firstIndex(of: current)!
        let boundary: CGRect?
        switch target {
        case .visible: boundary = hidden
        case .hidden: boundary = movingRight ? alwaysHidden : hidden
        case .alwaysHidden: boundary = alwaysHidden
        }
        guard let boundary else { return nil }
        let x = movingRight ? boundary.maxX - boundary.width / 4 : boundary.minX + boundary.width / 4
        return CGPoint(x: x, y: y)
    }
}

/// Backs the item list in Settings: scans other apps' items and moves them between sections.
final class MenuBarItemsModel: ObservableObject {
    struct Entry: Identifiable {
        let item: MenuBarItem
        let section: MenuBarSection
        var id: String { item.id }
    }

    weak var manager: MenuBarManager?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var movingID: String?
    @Published var failure: String?
    /// While the list is on screen every section stays expanded, so positions are real and items can be dragged.
    private var isEditing = false

    func startEditing() {
        guard !isEditing else { return }
        isEditing = true
        manager?.beginArranging()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Apps launched since the switch was turned on may have added visible icons; sweep them up.
            if AppSettings.shared.hideNonAppleIcons { self.moveAllNonApple(to: .hidden) } else { self.refresh() }
        }
    }

    func stopEditing() {
        guard isEditing else { return }
        isEditing = false
        if movingID == nil { manager?.endArranging() }
    }

    func refresh() {
        guard let manager, movingID == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = MenuBarItemScanner.scan()
            DispatchQueue.main.async {
                guard self.movingID == nil else { return }
                let frames = manager.dividerFrames()
                self.entries = items.map { Entry(item: $0, section: frames.section(of: $0)) }
            }
        }
    }

    func move(_ entry: Entry, to target: MenuBarSection) {
        guard entry.section != target else { return }
        runMoves(busyID: entry.id) { manager in
            Self.drag(entry.id, to: target, manager: manager)
                ? [] : ["Couldn't move \(entry.item.title). If it's behind the camera notch, hide a few other icons first, or ⌘-drag it by hand."]
        }
    }

    /// Moves every non-Apple icon into `target`, one at a time. Icons macOS tucked into its overflow for lack
    /// of room are picked up as moving others frees space.
    func moveAllNonApple(to target: MenuBarSection) {
        runMoves(busyID: Self.batchID) { manager in
            var skipped = Set<String>()
            var failed: [String] = []
            for _ in 0..<60 {
                let frames = DispatchQueue.main.sync { manager.dividerFrames() }
                guard let next = MenuBarItemScanner.scan().first(where: {
                    !$0.isApple && $0.isMovable && !$0.isInSystemOverflow && !skipped.contains($0.id)
                        && frames.section(of: $0) != target
                }) else { break }
                if !Self.drag(next.id, to: target, manager: manager) {
                    skipped.insert(next.id)
                    failed.append(next.title)
                }
            }
            return failed.isEmpty ? [] : ["Couldn't move \(failed.joined(separator: ", ")). ⌘-drag them by hand if they're still out of place."]
        }
    }

    static let batchID = "*"
    var isBatchMoving: Bool { movingID == Self.batchID }

    /// Shows every section, runs `work` off the main thread, then restores the menu bar and rescans.
    private func runMoves(busyID: String, _ work: @escaping (MenuBarManager) -> [String]) {
        guard let manager, movingID == nil else { return }
        movingID = busyID
        failure = nil
        let wasEditing = isEditing
        if !wasEditing { manager.beginArranging() }

        DispatchQueue.global(qos: .userInitiated).async {
            if !wasEditing { usleep(500_000) } // let the expanded dividers settle
            let failures = work(manager)
            DispatchQueue.main.async {
                if !self.isEditing { manager.endArranging() }
                self.movingID = nil
                self.failure = failures.first
                self.refresh()
            }
        }
    }

    /// ⌘-drags one item across the divider and checks where it landed. Call off the main thread.
    private static func drag(_ id: String, to target: MenuBarSection, manager: MenuBarManager) -> Bool {
        for _ in 0..<2 {
            guard let current = MenuBarItemScanner.scan().first(where: { $0.id == id }) else { return false }
            let frames = DispatchQueue.main.sync { manager.dividerFrames() }
            let section = frames.section(of: current)
            if section == target { return true }
            guard let drop = frames.dropPoint(from: section, to: target, y: current.frame.midY) else { return false }
            MenuBarItemMover.commandDrag(from: CGPoint(x: current.frame.midX, y: current.frame.midY), to: drop)
            usleep(800_000) // positions take a moment to settle after a drop
        }
        guard let after = MenuBarItemScanner.scan().first(where: { $0.id == id }) else { return false }
        return DispatchQueue.main.sync { manager.dividerFrames() }.section(of: after) == target
    }
}

/// Moves items the way a person would: holding ⌘ and dragging them along the menu bar.
enum MenuBarItemMover {
    /// Points are in global top-left coordinates. Blocks for about half a second; call off the main thread.
    static func commandDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let restore = CGEvent(source: nil)?.location

        func mouse(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        func command(down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: down)
            event?.flags = down ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }

        command(down: true)
        mouse(.mouseMoved, start)
        usleep(50_000)
        mouse(.leftMouseDown, start)
        usleep(200_000)
        let steps = 20
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            usleep(15_000)
        }
        usleep(150_000)
        mouse(.leftMouseUp, end)
        usleep(50_000)
        command(down: false)
        if let restore { CGWarpMouseCursorPosition(restore) }
    }
}
