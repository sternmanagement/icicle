import AppKit
import ApplicationServices
import Combine

/// Windows 11-style snapping: drag a window to the top of the screen to get the Snap Layouts flyout,
/// or to a side/corner to snap it to a half/quarter. Moving other apps' windows requires Accessibility.
final class WindowSnapper {
    private let settings = AppSettings.shared
    private let flyout = SnapFlyoutPanel()
    private let preview = SnapPreviewPanel()

    private var monitor: Any?
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var candidate: AXWindow?
    private var candidateStartFrame: CGRect?
    private var isDraggingWindow = false
    private var target: CGRect?

    private static let edgeMargin: CGFloat = 6
    private static let cornerSize: CGFloat = 120
    private static let flyoutStickyMargin: CGFloat = 48

    func start() {
        AXWindow.configureTimeout()
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Public actions

    func snapFocusedWindow(to unit: CGRect) {
        guard AccessibilityAccess.isTrusted else {
            AccessibilityAccess.request()
            return
        }
        guard let window = AXWindow.focused(), window.isSnappable, let frame = window.cocoaFrame else {
            NSSound.beep()
            return
        }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screen(containing: center) ?? NSScreen.main
        guard let screen else { return }
        window.setFrame(SnapLayout.frame(for: unit, in: screen, gap: settings.snapGap))
    }

    // MARK: - Setup

    private var wantsDragMonitoring: Bool {
        settings.snapLayoutsEnabled || settings.edgeSnappingEnabled
    }

    private func refresh() {
        registerHotKeys()

        if wantsDragMonitoring, AccessibilityAccess.isTrusted {
            installMonitor()
            trustTimer?.invalidate()
            trustTimer = nil
        } else {
            removeMonitor()
            if wantsDragMonitoring, trustTimer == nil {
                // Pick up a permission grant without requiring a relaunch.
                trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    if AccessibilityAccess.isTrusted { self?.refresh() }
                }
            } else if !wantsDragMonitoring {
                trustTimer?.invalidate()
                trustTimer = nil
            }
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishDrag()
    }

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.register(id: 10, combo: settings.snapLeftHotKey) { [weak self] in self?.snapFocusedWindow(to: SnapLayout.Zone.leftHalf) }
        center.register(id: 11, combo: settings.snapRightHotKey) { [weak self] in self?.snapFocusedWindow(to: SnapLayout.Zone.rightHalf) }
        center.register(id: 12, combo: settings.snapMaximizeHotKey) { [weak self] in self?.snapFocusedWindow(to: SnapLayout.Zone.full) }
    }

    // MARK: - Drag tracking

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            finishDrag()
            if let window = AXWindow.at(NSEvent.mouseLocation), window.isSnappable {
                candidate = window
                candidateStartFrame = window.cocoaFrame
            }

        case .leftMouseDragged:
            guard let window = candidate else { return }
            if !isDraggingWindow {
                // A drag is a window move only if the window's origin changes while its size doesn't.
                guard let start = candidateStartFrame, let now = window.cocoaFrame else { return }
                let resized = abs(now.width - start.width) > 1 || abs(now.height - start.height) > 1
                if resized {
                    candidate = nil
                    return
                }
                let moved = abs(now.minX - start.minX) > 2 || abs(now.minY - start.minY) > 2
                guard moved else { return }
                isDraggingWindow = true
            }
            evaluate(NSEvent.mouseLocation)

        case .leftMouseUp:
            if isDraggingWindow, let window = candidate, let target {
                // Let the window server finish its own drag first, or it can overwrite our frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    window.setFrame(target)
                }
            }
            finishDrag()

        default:
            break
        }
    }

    private func finishDrag() {
        candidate = nil
        candidateStartFrame = nil
        isDraggingWindow = false
        target = nil
        flyout.hide()
        preview.hide()
    }

    // MARK: - Snap targets

    private func evaluate(_ point: NSPoint) {
        guard let screen = screen(containing: point) else {
            setTarget(nil, at: point)
            return
        }
        let gap = settings.snapGap

        if settings.snapLayoutsEnabled {
            let atTop = point.y >= screen.frame.maxY - topTriggerHeight(for: screen)

            if flyout.isVisible {
                if let zone = flyout.hitTest(point) {
                    flyout.highlight(zone)
                    let unit = SnapLayout.all[zone.layout].zones[zone.zone]
                    setTarget(SnapLayout.frame(for: unit, in: screen, gap: gap), at: point)
                    return
                }
                flyout.highlight(nil)
                let nearFlyout = flyout.frame.insetBy(dx: -Self.flyoutStickyMargin, dy: -Self.flyoutStickyMargin).contains(point)
                if nearFlyout || atTop {
                    setTarget(nil, at: point)
                    return
                }
                flyout.hide()
            } else if atTop {
                flyout.show(on: screen)
                setTarget(nil, at: point)
                return
            }
        }

        if settings.edgeSnappingEnabled, let unit = edgeZone(for: point, on: screen) {
            setTarget(SnapLayout.frame(for: unit, in: screen, gap: gap), at: point)
        } else {
            setTarget(nil, at: point)
        }
    }

    private func setTarget(_ rect: CGRect?, at point: NSPoint) {
        target = rect
        if let rect {
            preview.show(rect, growingFrom: point)
        } else {
            preview.hide()
        }
    }

    private func edgeZone(for p: NSPoint, on screen: NSScreen) -> CGRect? {
        let f = screen.frame
        let nearTop = p.y >= f.maxY - Self.cornerSize
        let nearBottom = p.y <= f.minY + Self.cornerSize

        if p.x <= f.minX + Self.edgeMargin, !hasNeighbor(of: screen, onLeft: true) {
            return nearTop ? SnapLayout.Zone.topLeft : nearBottom ? SnapLayout.Zone.bottomLeft : SnapLayout.Zone.leftHalf
        }
        if p.x >= f.maxX - Self.edgeMargin - 1, !hasNeighbor(of: screen, onLeft: false) {
            return nearTop ? SnapLayout.Zone.topRight : nearBottom ? SnapLayout.Zone.bottomRight : SnapLayout.Zone.rightHalf
        }
        if !settings.snapLayoutsEnabled, p.y >= f.maxY - topTriggerHeight(for: screen) {
            return SnapLayout.Zone.full
        }
        return nil
    }

    /// The menu bar strip; windows can't be dragged into it, but the cursor can.
    private func topTriggerHeight(for screen: NSScreen) -> CGFloat {
        max(Self.edgeMargin, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Edges shared with another display aren't snap edges — the cursor just crosses over.
    private func hasNeighbor(of screen: NSScreen, onLeft: Bool) -> Bool {
        let f = screen.frame
        return NSScreen.screens.contains { other in
            guard other != screen else { return false }
            let o = other.frame
            let touches = onLeft ? abs(o.maxX - f.minX) < 2 : abs(o.minX - f.maxX) < 2
            return touches && o.maxY > f.minY && o.minY < f.maxY
        }
    }

    private func screen(containing p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { s in
            p.x >= s.frame.minX && p.x <= s.frame.maxX && p.y >= s.frame.minY && p.y <= s.frame.maxY
        }
    }
}
