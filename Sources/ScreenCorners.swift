import AppKit
import Combine
import SwiftUI

/// Rounds off the corners of every display with four small black click-through panels, above everything
/// including the menu bar and full-screen apps.
final class ScreenCorners {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private let settings = AppSettings.shared
    private var panels: [NSPanel] = []
    private var builtFor: (enabled: Bool, radius: Double)?
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

    private func settingsChanged() {
        if builtFor?.enabled != settings.roundedCornersEnabled || builtFor?.radius != settings.roundedCornerRadius { rebuild() }
    }

    private func rebuild() {
        builtFor = (settings.roundedCornersEnabled, settings.roundedCornerRadius)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        guard settings.roundedCornersEnabled else { return }
        let radius = CGFloat(settings.roundedCornerRadius)
        for screen in NSScreen.screens {
            let f = screen.frame
            for corner in Corner.allCases {
                let origin: CGPoint
                switch corner {
                case .topLeft: origin = CGPoint(x: f.minX, y: f.maxY - radius)
                case .topRight: origin = CGPoint(x: f.maxX - radius, y: f.maxY - radius)
                case .bottomLeft: origin = CGPoint(x: f.minX, y: f.minY)
                case .bottomRight: origin = CGPoint(x: f.maxX - radius, y: f.minY)
                }
                let panel = MenuBarOverlayPanel(contentRect: CGRect(origin: origin, size: CGSize(width: radius, height: radius)),
                                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                panel.contentView = NSHostingView(rootView: CornerShape(corner: corner).fill(Color.black, style: FillStyle(eoFill: true)))
                panel.orderFrontRegardless()
                panels.append(panel)
            }
        }
    }
}

/// A square with a quarter circle cut out of the side facing the middle of the screen.
private struct CornerShape: Shape {
    let corner: ScreenCorners.Corner

    func path(in rect: CGRect) -> Path {
        let center: CGPoint
        switch corner {
        case .topLeft: center = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: center = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: center = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: center = CGPoint(x: rect.minX, y: rect.minY)
        }
        var path = Path(rect)
        path.addEllipse(in: CGRect(x: center.x - rect.width, y: center.y - rect.height, width: rect.width * 2, height: rect.height * 2))
        return path
    }
}
