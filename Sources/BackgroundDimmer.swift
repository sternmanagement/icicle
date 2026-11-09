import AppKit
import Combine
import SwiftUI

/// Dims everything except the focused window: a dark click-through sheet per display with a hole cut where
/// that window is. macOS won't let one app slot a window between another app's windows, so the sheet sits
/// on top and follows the window instead; there's no notification for other apps' windows moving, so it polls.
final class BackgroundDimmer {
    private static let pollInterval: TimeInterval = 1.0 / 30

    private let settings = AppSettings.shared
    private var panels: [(panel: NSPanel, model: DimModel)] = []
    private var timer: Timer?
    private var lastFrame: CGRect?
    private var lastPID: pid_t?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        apply()
    }

    private func apply() {
        if settings.dimEnabled {
            if panels.isEmpty { rebuild() }
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            panels.forEach { $0.panel.orderOut(nil) }
            panels.removeAll()
            lastFrame = nil
        }
    }

    private func rebuild() {
        panels.forEach { $0.panel.orderOut(nil) }
        panels.removeAll()
        lastFrame = nil
        guard settings.dimEnabled else { return }
        for screen in NSScreen.screens {
            let model = DimModel()
            let panel = MenuBarOverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // Normal level, re-raised whenever focus moves: above the focused window (which shows through the
            // hole) but below menus, popovers and floating palettes.
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: DimView(model: model, settings: settings))
            panels.append((panel, model))
        }
    }

    private func tick() {
        guard AccessibilityAccess.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = AXWindow.focused(), window.isSnappable,
              (window.element.value("AXFullScreen") as? Bool) != true,
              let frame = window.cocoaFrame, frame.width > 80, frame.height > 80 else {
            hide()
            return
        }
        let focusMoved = app.processIdentifier != lastPID || lastFrame == nil
        guard frame != lastFrame || focusMoved else { return }
        lastFrame = frame
        lastPID = app.processIdentifier
        for (panel, model) in panels {
            // The hole in this display's coordinates, flipped for SwiftUI's top-left origin.
            let local = CGRect(x: frame.minX - panel.frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            model.hole = local
            if focusMoved { panel.orderFrontRegardless() }
            if !model.visible { model.visible = true }
        }
    }

    private func hide() {
        guard lastFrame != nil else { return }
        lastFrame = nil
        lastPID = nil
        panels.forEach { $0.model.visible = false }
    }
}

private final class DimModel: ObservableObject {
    @Published var hole: CGRect?
    @Published var visible = false
}

private struct DimView: View {
    @ObservedObject var model: DimModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        DimShape(hole: model.hole)
            .fill(Color.black.opacity(settings.dimAmount), style: FillStyle(eoFill: true))
            .opacity(model.visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: model.visible)
    }
}

/// The whole display minus a rounded hole where the focused window is.
private struct DimShape: Shape {
    let hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        // Roughly the corner radius of macOS 26+ windows.
        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14), style: .continuous) }
        return path
    }
}
