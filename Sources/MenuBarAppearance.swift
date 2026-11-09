import AppKit
import Combine
import ImageIO
import SwiftUI

enum TintStyle: String, CaseIterable, Identifiable {
    case solid, gradient, wallpaper

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MenuBarShape: String, CaseIterable, Identifiable {
    case full, floating, split

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// How far the two "islands" of the split shape reach: the app menus from the left edge, the status items from the right.
struct Islands: Equatable {
    var left: CGFloat
    var right: CGFloat
}

/// What the overlay needs beyond settings, gathered from other apps and the desktop.
final class MenuBarAppearanceState: ObservableObject {
    @Published var islands: Islands?
    /// Hex colours sampled from the top of each display's wallpaper, left and right.
    @Published var wallpaperColors: [CGDirectDisplayID: [String]] = [:]
}

/// Decorates the menu bar on every display: a tint, a shape, a border and a shadow. The menu bar has been
/// transparent since macOS 26, so a click-through window just below its level shows through behind the items.
final class MenuBarAppearance {
    /// Extra room below the menu bar for the shadow to fall into.
    static let shadowMargin: CGFloat = 12

    /// The left edge of Icicle's own icon, which the status-item island has to include.
    var ownIconMinX: (() -> CGFloat?)?
    /// Where Icicle's collapsed hidden section ends; icons left of it aren't really showing.
    var hiddenItemsBoundary: (() -> CGFloat?)?

    private let settings = AppSettings.shared
    private let state = MenuBarAppearanceState()
    private var panels: [MenuBarOverlayPanel] = []
    private var cancellables = Set<AnyCancellable>()
    private var islandTimer: Timer?
    private var wallpaperTimer: Timer?
    private var wallpaperURLs: [CGDirectDisplayID: URL] = [:]
    private let scanQueue = DispatchQueue(label: "local.icicle.islands", qos: .utility)
    private var isScanning = false

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // The newly active app's menus land in the menu bar a moment after it activates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.updateIslands() }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateWallpaper()
        }
        rebuild()
    }

    // MARK: - Panels

    /// Colours and shapes update live through SwiftUI; panels only need rebuilding when one appears or disappears.
    private struct Build: Equatable {
        var decorated: Bool
        var hideNotch: Bool
    }

    private var builtFor: Build?

    private var currentBuild: Build {
        Build(decorated: settings.menuBarTintEnabled || settings.menuBarShape != .full || settings.menuBarBorder || settings.menuBarShadow,
              hideNotch: settings.hideNotch)
    }

    private func settingsChanged() {
        if currentBuild != builtFor { rebuild() } else { updateTimers() }
    }

    private func rebuild() {
        let build = currentBuild
        builtFor = build
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        for screen in NSScreen.screens {
            // Hiding the notch wins on displays that have one: a black bar makes the cut-out vanish.
            let hidesNotch = build.hideNotch && Self.hasNotch(screen)
            guard hidesNotch || build.decorated else { continue }
            let barFrame = Self.menuBarFrame(of: screen)
            let panel = makePanel(frame: CGRect(x: barFrame.minX, y: barFrame.minY - Self.shadowMargin,
                                                width: barFrame.width, height: barFrame.height + Self.shadowMargin))
            panel.contentView = NSHostingView(rootView: MenuBarOverlayView(settings: settings, state: state, displayID: screen.displayID,
                                                                           barHeight: barFrame.height, hidesNotch: hidesNotch))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        updateTimers()
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil
    }

    private func makePanel(frame: CGRect) -> MenuBarOverlayPanel {
        let panel = MenuBarOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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

    private func updateTimers() {
        let wantsIslands = !panels.isEmpty && settings.menuBarShape == .split
        if wantsIslands, islandTimer == nil {
            // Status items come and go and change width (the clock, battery percentage), and nothing announces it.
            islandTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.updateIslands() }
            updateIslands()
        } else if !wantsIslands, islandTimer != nil {
            islandTimer?.invalidate()
            islandTimer = nil
            state.islands = nil
        }

        let wantsWallpaper = !panels.isEmpty && settings.menuBarTintEnabled && settings.menuBarTintStyle == .wallpaper
        if wantsWallpaper, wallpaperTimer == nil {
            // There's no notification for a wallpaper change, so check which file each display shows now and then.
            wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateWallpaper() }
            updateWallpaper()
        } else if !wantsWallpaper, wallpaperTimer != nil {
            wallpaperTimer?.invalidate()
            wallpaperTimer = nil
        }
    }

    // MARK: - Split shape

    private func updateIslands() {
        guard islandTimer != nil, !isScanning, AccessibilityAccess.isTrusted,
              let menusEnd = AccessibilityAccess.frontmostAppMenusMaxX() else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != ownPID }
        let ownMinX = ownIconMinX?()
        let boundary = hiddenItemsBoundary?() ?? -.infinity
        isScanning = true
        scanQueue.async { [weak self] in
            let shown = MenuBarItemScanner.visibleFrames(of: pids)
                .filter { $0.isOverflowButton || $0.frame.minX >= boundary }
                .map(\.frame.minX)
            let itemsStart = (shown + [ownMinX].compactMap { $0 }).min()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                guard let itemsStart else { self.state.islands = nil; return }
                // AX positions are global; measure against whichever display they're on, then apply to all of them.
                let screens = NSScreen.screens
                let menuScreen = screens.first { $0.frame.minX <= menusEnd && menusEnd <= $0.frame.maxX } ?? screens.first
                let itemScreen = screens.first { $0.frame.minX <= itemsStart && itemsStart < $0.frame.maxX } ?? screens.first
                guard let menuScreen, let itemScreen else { return }
                let islands = Islands(left: (menusEnd - menuScreen.frame.minX).rounded(),
                                      right: (itemScreen.frame.maxX - itemsStart).rounded())
                if self.state.islands != islands { self.state.islands = islands }
            }
        }
    }

    // MARK: - Wallpaper tint

    private func updateWallpaper() {
        guard wallpaperTimer != nil else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  wallpaperURLs[id] != url else { continue }
            wallpaperURLs[id] = url
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let colors = Self.topColors(of: url)
                DispatchQueue.main.async { self?.state.wallpaperColors[id] = colors }
            }
        }
    }

    /// The average colours of the left and right halves of the wallpaper's top strip, the part behind the menu bar.
    static func topColors(of url: URL) -> [String]? {
        // A small thumbnail is plenty for averaging and avoids decoding a 6K image.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 320,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = 32, height = 6
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            // Stretch the image so only its top tenth lands in the bitmap.
            let drawHeight = CGFloat(height) * 10
            context.draw(image, in: CGRect(x: 0, y: CGFloat(height) - drawHeight, width: CGFloat(width), height: drawHeight))
            return true
        }
        guard drawn else { return nil }
        return [0..<width / 2, width / 2..<width].map { columns in
            var sum = [0.0, 0.0, 0.0]
            for y in 0..<height {
                for x in columns {
                    for c in 0..<3 { sum[c] += Double(pixels[(y * width + x) * 4 + c]) }
                }
            }
            let count = Double(height * columns.count)
            let color = NSColor(srgbRed: sum[0] / count / 255, green: sum[1] / count / 255, blue: sum[2] / count / 255, alpha: 1)
            // A touch more saturation keeps the wash from looking muddy over the same wallpaper.
            let tuned = NSColor(hue: color.hueComponent, saturation: min(1, color.saturationComponent * 1.25),
                                brightness: color.brightnessComponent, alpha: 0.7)
            return Color(nsColor: tuned).hexString
        }
    }
}

/// AppKit keeps windows below the menu bar's level out of the menu bar strip, nudging them down under it.
/// This panel opts out so it can sit exactly behind the menu bar.
final class MenuBarOverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private struct MenuBarOverlayView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: MenuBarAppearanceState
    let displayID: CGDirectDisplayID?
    let barHeight: CGFloat
    let hidesNotch: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if hidesNotch {
            VStack(spacing: 0) {
                Color.black.frame(height: barHeight)
                Spacer(minLength: 0)
            }
        } else {
            MenuBarDecoration(fill: fill, shape: settings.menuBarShape, islands: state.islands,
                              border: settings.menuBarBorder, shadow: settings.menuBarShadow, barHeight: barHeight) { outline, size in
                AnyView(GlassView(outline: outline, size: size))
            }
        }
    }

    private var fill: [Color]? {
        guard settings.menuBarTintEnabled else { return nil }
        if settings.menuBarTintStyle == .wallpaper, let displayID, let sampled = state.wallpaperColors[displayID] {
            return sampled.map { Color(hex: $0) }
        }
        let colors = colorScheme == .dark
            ? [settings.tintDarkStart, settings.tintDarkEnd]
            : [settings.tintLightStart, settings.tintLightEnd]
        return (settings.menuBarTintStyle == .solid ? [colors[0]] : colors).map { Color(hex: $0) }
    }
}

/// The outline of the menu bar background: the whole strip, one floating pill, or a pill at each end.
struct BarOutline: Shape {
    var shape: MenuBarShape
    var islands: Islands?
    var barHeight: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(islands?.left ?? 0, islands?.right ?? 0) }
        set { if islands != nil { islands = Islands(left: newValue.first, right: newValue.second) } }
    }

    func path(in rect: CGRect) -> Path {
        let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight)
        if shape == .full { return Path(bar) }

        let inset: CGFloat = 6
        let pillHeight = min(barHeight - 4, 26)
        let y = bar.minY + (barHeight - pillHeight) / 2
        let corner = CGSize(width: pillHeight / 2, height: pillHeight / 2)
        func pill(_ minX: CGFloat, _ maxX: CGFloat) -> CGRect {
            CGRect(x: minX, y: y, width: max(maxX - minX, pillHeight), height: pillHeight)
        }
        var path = Path()
        if shape == .split, let islands {
            let left = pill(bar.minX + inset, bar.minX + max(islands.left + 10, 60))
            let right = pill(bar.maxX - islands.right - 10, bar.maxX - inset)
            // Islands that would touch merge back into one pill.
            if left.maxX + 12 < right.minX {
                path.addRoundedRect(in: left, cornerSize: corner, style: .continuous)
                path.addRoundedRect(in: right, cornerSize: corner, style: .continuous)
                return path
            }
        }
        path.addRoundedRect(in: pill(bar.minX + inset, bar.maxX - inset), cornerSize: corner, style: .continuous)
        return path
    }
}

/// Draws the menu bar background into a view the size of the overlay: the bar along the top, room for the shadow below.
struct MenuBarDecoration: View {
    /// Tint colours, or nil for frosted glass (pill shapes) or nothing at all (the full shape).
    let fill: [Color]?
    let shape: MenuBarShape
    let islands: Islands?
    let border: Bool
    let shadow: Bool
    let barHeight: CGFloat
    let glass: (BarOutline, CGSize) -> AnyView
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let outline = BarOutline(shape: shape, islands: islands, barHeight: barHeight)
            ZStack(alignment: .topLeading) {
                if shadow {
                    outline
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.3))
                        .blur(radius: shape == .full ? 5 : 4)
                        .offset(y: 2)
                        .mask {
                            // Only the part falling outside the bar, so translucent fills stay clean.
                            Rectangle().overlay { outline.fill(.black).blendMode(.destinationOut) }.compositingGroup()
                        }
                }
                if let fill {
                    Group {
                        if fill.count > 1 {
                            LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing)
                        } else {
                            fill.first ?? .clear
                        }
                    }
                    .mask(outline)
                } else if shape != .full {
                    glass(outline, proxy.size)
                }
                if border {
                    if shape == .full {
                        borderColor.frame(height: 1).offset(y: barHeight - 1)
                    } else {
                        outline.stroke(borderColor, lineWidth: 1)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.smooth(duration: 0.3), value: islands)
        }
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
    }
}

/// Frosted glass that blurs whatever is behind the window, cut to the outline. SwiftUI masks don't reach
/// AppKit-backed views reliably, so the cut is the visual effect view's own mask image.
private struct GlassView: NSViewRepresentable {
    let outline: BarOutline
    let size: CGSize

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let path = outline.path(in: CGRect(origin: .zero, size: size)).cgPath
        view.maskImage = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
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
