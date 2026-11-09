import AppKit
import ApplicationServices

/// Converts between Cocoa screen coordinates (origin bottom-left of the primary display)
/// and Accessibility coordinates (origin top-left of the primary display, y pointing down).
enum AXGeometry {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The flip is its own inverse, so this converts in both directions.
    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        value(attribute) as? [AXUIElement] ?? []
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let v = value(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let v = value(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Frame in AX coordinates.
    var axFrame: CGRect? {
        guard let p = point(kAXPositionAttribute), let s = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

struct AXWindow {
    let element: AXUIElement

    /// Keeps a hung app from freezing Icicle; applies to every AX call made through any element.
    static func configureTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    static func at(_ cocoaPoint: NSPoint) -> AXWindow? {
        let p = AXGeometry.toAX(cocoaPoint)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              var current = hit else { return nil }

        for _ in 0..<25 {
            if current.string(kAXRoleAttribute) == kAXWindowRole { return AXWindow(element: current) }
            if let window = current.element(kAXWindowAttribute) { return AXWindow(element: window) }
            guard let parent = current.element(kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
            .element(kAXFocusedWindowAttribute)
            .map(AXWindow.init)
    }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// Standard app windows only — skips sheets, panels, popovers and Icicle's own windows.
    var isSnappable: Bool {
        guard pid != getpid() else { return false }
        guard let subrole = element.string(kAXSubroleAttribute) else { return true }
        return subrole == kAXStandardWindowSubrole
    }

    var cocoaFrame: CGRect? {
        element.axFrame.map(AXGeometry.flip)
    }

    func setFrame(_ cocoaRect: CGRect) {
        let ax = AXGeometry.flip(cocoaRect)
        var origin = ax.origin
        var size = ax.size
        // Position → size → position: moving first lets the size fit on a new display,
        // and the second move fixes the origin if the app clamped the size.
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
    }
}

enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Right edge (Cocoa x) of the frontmost app's menus — File, Edit, View… — or nil without access.
    static func frontmostAppMenusMaxX() -> CGFloat? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let menuBar = AXUIElementCreateApplication(app.processIdentifier).element(kAXMenuBarAttribute)
        let frames = menuBar?.elements(kAXChildrenAttribute).compactMap(\.axFrame) ?? []
        return frames.map(\.maxX).max() ?? 0
    }
}
