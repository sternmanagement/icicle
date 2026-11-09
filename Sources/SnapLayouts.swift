import AppKit
import SwiftUI

/// A snap layout: zones are unit rects (0…1) with a top-left origin, like the screen as you see it.
struct SnapLayout: Identifiable {
    let id: Int
    let name: String
    let zones: [CGRect]

    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    static let all: [SnapLayout] = [
        SnapLayout(id: 0, name: "Halves", zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)]),
        SnapLayout(id: 1, name: "Thirds", zones: [r(0, 0, 1 / 3, 1), r(1 / 3, 0, 1 / 3, 1), r(2 / 3, 0, 1 / 3, 1)]),
        SnapLayout(id: 2, name: "Wide left", zones: [r(0, 0, 2 / 3, 1), r(2 / 3, 0, 1 / 3, 1)]),
        SnapLayout(id: 3, name: "Wide right", zones: [r(0, 0, 1 / 3, 1), r(1 / 3, 0, 2 / 3, 1)]),
        SnapLayout(id: 4, name: "Main and stack", zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
        SnapLayout(id: 5, name: "Quarters", zones: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
        SnapLayout(id: 6, name: "Focus", zones: [r(0, 0, 0.25, 1), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 1)]),
        SnapLayout(id: 7, name: "Full screen", zones: [r(0, 0, 1, 1)]),
    ]

    enum Zone {
        static let leftHalf = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        static let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        static let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        static let topRight = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        static let bottomLeft = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        static let bottomRight = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Screen rect (Cocoa coordinates) for a unit zone, with an even `gap` between windows and screen edges.
    static func frame(for unit: CGRect, in screen: NSScreen, gap: CGFloat) -> CGRect {
        let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let rect = CGRect(
            x: area.minX + unit.minX * area.width,
            y: area.maxY - (unit.minY + unit.height) * area.height,
            width: unit.width * area.width,
            height: unit.height * area.height
        )
        return rect.insetBy(dx: gap / 2, dy: gap / 2).integral
    }
}

struct ZoneID: Equatable {
    let layout: Int
    let zone: Int
}

extension Color {
    /// The accent color, except Graphite (AppleAccentColor = -1), whose gray makes a highlighted zone
    /// look darker than an idle one; snapping falls back to blue there.
    static var snapHighlight: Color {
        let isGraphite = (UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int) == -1
        return isGraphite ? Color(nsColor: .systemBlue) : Color(nsColor: .controlAccentColor)
    }
}

// MARK: - Overlay panels

/// Borderless, click-through, translucent panel that floats over every Space.
class OverlayPanel: NSPanel {
    let effectView = NSVisualEffectView()
    private var fadeGeneration = 0

    init(cornerRadius: CGFloat, material: NSVisualEffectView.Material, level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        effectView.material = material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMask(radius: cornerRadius)
        contentView = effectView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func embed<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.frame = effectView.bounds
        host.autoresizingMask = [.width, .height]
        effectView.addSubview(host)
    }

    func fadeIn(to frame: NSRect, from startFrame: NSRect? = nil, duration: TimeInterval = 0.16) {
        fadeGeneration += 1
        if !isVisible {
            setFrame(startFrame ?? frame, display: false)
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A fadeIn during the fade-out means the panel is wanted again.
            guard let self, self.fadeGeneration == generation else { return }
            self.orderOut(nil)
        })
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The translucent rectangle showing where the window will land.
final class SnapPreviewPanel: OverlayPanel {
    private var currentTarget: CGRect?

    init() {
        super.init(cornerRadius: 14, material: .popover, level: .floating)
        hasShadow = false
        embed(SnapPreviewView())
    }

    func show(_ target: CGRect, growingFrom point: NSPoint) {
        guard target != currentTarget else { return }
        let start = NSRect(x: point.x - 60, y: point.y - 40, width: 120, height: 80)
        currentTarget = target
        fadeIn(to: target, from: start, duration: 0.18)
    }

    func hide() {
        currentTarget = nil
        fadeOut()
    }
}

private struct SnapPreviewView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.snapHighlight.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.snapHighlight.opacity(0.85), lineWidth: 2.5)
            )
    }
}

// MARK: - Snap Layouts flyout

/// Shared geometry so the SwiftUI drawing and the hit-testing agree exactly. Top-left origin.
enum FlyoutGeometry {
    static let padding: CGFloat = 14
    static let header: CGFloat = 26
    static let tile = CGSize(width: 92, height: 58)
    static let spacing: CGFloat = 10
    static let columns = 4
    static let tileInset: CGFloat = 5
    static let zoneGap: CGFloat = 1.5

    static var rows: Int { (SnapLayout.all.count + columns - 1) / columns }

    static var size: CGSize {
        CGSize(
            width: padding * 2 + CGFloat(columns) * tile.width + CGFloat(columns - 1) * spacing,
            height: padding * 2 + header + CGFloat(rows) * tile.height + CGFloat(rows - 1) * spacing
        )
    }

    static func tileRect(_ index: Int) -> CGRect {
        let col = index % columns
        let row = index / columns
        return CGRect(
            x: padding + CGFloat(col) * (tile.width + spacing),
            y: padding + header + CGFloat(row) * (tile.height + spacing),
            width: tile.width, height: tile.height
        )
    }

    static func zoneRect(layout: Int, zone unit: CGRect) -> CGRect {
        let inner = tileRect(layout).insetBy(dx: tileInset, dy: tileInset)
        return CGRect(
            x: inner.minX + unit.minX * inner.width,
            y: inner.minY + unit.minY * inner.height,
            width: unit.width * inner.width,
            height: unit.height * inner.height
        ).insetBy(dx: zoneGap, dy: zoneGap)
    }
}

final class SnapFlyoutModel: ObservableObject {
    @Published var hovered: ZoneID?
}

final class SnapFlyoutPanel: OverlayPanel {
    private let model = SnapFlyoutModel()

    init() {
        super.init(cornerRadius: 16, material: .hudWindow, level: .popUpMenu)
        embed(SnapFlyoutView(model: model))
    }

    func show(on screen: NSScreen) {
        let size = FlyoutGeometry.size
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 10,
            width: size.width, height: size.height
        )
        model.hovered = nil
        fadeIn(to: frame, from: frame.offsetBy(dx: 0, dy: 12))
    }

    func hide() {
        model.hovered = nil
        fadeOut()
    }

    func highlight(_ zone: ZoneID?) {
        if model.hovered != zone { model.hovered = zone }
    }

    func hitTest(_ screenPoint: NSPoint) -> ZoneID? {
        guard isVisible else { return nil }
        let local = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        for layout in SnapLayout.all {
            for (index, unit) in layout.zones.enumerated() {
                let rect = FlyoutGeometry.zoneRect(layout: layout.id, zone: unit)
                    .insetBy(dx: -FlyoutGeometry.zoneGap, dy: -FlyoutGeometry.zoneGap)
                if rect.contains(local) { return ZoneID(layout: layout.id, zone: index) }
            }
        }
        return nil
    }
}

private struct SnapFlyoutView: View {
    @ObservedObject var model: SnapFlyoutModel

    private var title: String {
        model.hovered.map { SnapLayout.all[$0.layout].name } ?? "Snap Layouts"
    }

    var body: some View {
        let size = FlyoutGeometry.size
        ZStack(alignment: .topLeading) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: FlyoutGeometry.header)
                .offset(y: FlyoutGeometry.padding - 5)
                .animation(nil, value: title)

            ForEach(SnapLayout.all) { layout in
                let tile = FlyoutGeometry.tileRect(layout.id)
                let layoutHovered = model.hovered?.layout == layout.id

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(layoutHovered ? 0.14 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(layoutHovered ? 0.25 : 0.1))
                    )
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY)

                ForEach(Array(layout.zones.enumerated()), id: \.offset) { index, unit in
                    let rect = FlyoutGeometry.zoneRect(layout: layout.id, zone: unit)
                    let isOn = model.hovered == ZoneID(layout: layout.id, zone: index)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Color.snapHighlight : Color.white.opacity(0.28))
                        .shadow(color: isOn ? Color.snapHighlight.opacity(0.6) : .clear, radius: 4)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(.easeOut(duration: 0.12), value: isOn)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
}

/// Small static picture of a layout, for the settings window.
struct LayoutThumbnail: View {
    let layout: SnapLayout
    var highlight: Int?

    var body: some View {
        GeometryReader { geo in
            let inner = CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                ForEach(Array(layout.zones.enumerated()), id: \.offset) { index, unit in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index == highlight ? Color.snapHighlight : Color.snapHighlight.opacity(0.3))
                        .frame(width: unit.width * inner.width - 3, height: unit.height * inner.height - 3)
                        .offset(x: inner.minX + unit.minX * inner.width + 1.5,
                                y: inner.minY + unit.minY * inner.height + 1.5)
                }
            }
        }
    }
}
