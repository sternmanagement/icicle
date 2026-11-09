import AppKit
import Combine
import SwiftUI

/// Draws a coloured outline around the focused window. It's a click-through panel that follows the
/// window's frame; there's no notification for other apps' windows moving, so it polls.
final class FocusBorder {
    private static let pollInterval: TimeInterval = 0.1

    private let settings = AppSettings.shared
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastFrame: CGRect?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        apply()
    }

    private func apply() {
        if settings.focusBorderEnabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        } else if !settings.focusBorderEnabled {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            lastFrame = nil
        }
    }

    private func tick() {
        guard AccessibilityAccess.isTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = AXWindow.focused(), window.isSnappable,
              (window.element.value("AXFullScreen") as? Bool) != true,
              let frame = window.cocoaFrame, frame.width > 40, frame.height > 40 else {
            panel?.orderOut(nil)
            lastFrame = nil
            return
        }
        let panel = self.panel ?? makePanel()
        let width = CGFloat(settings.focusBorderWidth)
        let target = frame.insetBy(dx: -width, dy: -width)
        if target != lastFrame {
            panel.setFrame(target, display: true)
            lastFrame = target
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FocusBorderView(settings: settings))
        self.panel = panel
        return panel
    }
}

private struct FocusBorderView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let width = CGFloat(settings.focusBorderWidth)
        // Roughly follows the corner radius of macOS 26+ windows, grown by the border's own width.
        RoundedRectangle(cornerRadius: 14 + width, style: .continuous)
            .strokeBorder(Color(hex: settings.focusBorderColor), lineWidth: width)
    }
}
