import AppKit
import Combine
import SwiftUI

enum TintStyle: String, CaseIterable, Identifiable {
    case solid, gradient

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Paints a colour strip behind the menu bar on every display. The menu bar has been transparent since
/// macOS 26, so a click-through window just below its level shows through behind the items.
final class MenuBarAppearance {
    private let settings = AppSettings.shared
    private var panels: [MenuBarOverlayPanel] = []
    private var cancellables = Set<AnyCancellable>()

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    /// Colours update live through the SwiftUI view; panels only need rebuilding when a feature flips.
    private var builtFor: (tint: Bool, notch: Bool) = (false, false)

    private func settingsChanged() {
        if settings.menuBarTintEnabled != builtFor.tint || settings.hideNotch != builtFor.notch { rebuild() }
    }

    private func rebuild() {
        builtFor = (settings.menuBarTintEnabled, settings.hideNotch)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        for screen in NSScreen.screens {
            // Hiding the notch wins on displays that have one: a black bar makes the cut-out vanish.
            let content: AnyView
            if settings.hideNotch, Self.hasNotch(screen) {
                content = AnyView(Color.black)
            } else if settings.menuBarTintEnabled {
                content = AnyView(MenuBarTintView(settings: settings))
            } else {
                continue
            }
            let panel = makePanel(for: screen)
            panel.contentView = NSHostingView(rootView: content)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil
    }

    private func makePanel(for screen: NSScreen) -> MenuBarOverlayPanel {
        let panel = MenuBarOverlayPanel(contentRect: Self.menuBarFrame(of: screen), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        // No full-screen flag: .fullScreenNone gets the panel hidden in the menu bar strip, and without
        // .fullScreenAuxiliary it still stays out of full-screen apps, where it would cover their content.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }

    static func menuBarFrame(of screen: NSScreen) -> CGRect {
        let fromVisible = screen.frame.maxY - screen.visibleFrame.maxY
        // An auto-hiding menu bar leaves no gap in visibleFrame; fall back to the notch inset or the usual height.
        let height = fromVisible > 0 ? fromVisible : (screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }
}

/// AppKit keeps windows below the menu bar's level out of the menu bar strip, nudging them down under it.
/// This panel opts out so it can sit exactly behind the menu bar.
final class MenuBarOverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct MenuBarTintView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = colorScheme == .dark
            ? [settings.tintDarkStart, settings.tintDarkEnd]
            : [settings.tintLightStart, settings.tintLightEnd]
        if settings.menuBarTintStyle == .gradient {
            LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
        } else {
            Color(hex: colors[0])
        }
    }
}

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" in sRGB.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let hasAlpha = hex.count > 7
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000FF" }
        let parts = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}

extension Binding where Value == String {
    /// Edits a stored hex string through a ColorPicker.
    var color: Binding<Color> {
        Binding<Color>(get: { Color(hex: wrappedValue) }, set: { wrappedValue = $0.hexString })
    }
}
