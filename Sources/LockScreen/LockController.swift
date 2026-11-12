import AppKit
import SwiftUI

/// Borderless, blurred windows above everything on every display.
/// This is a glance screen, not a security lock: macOS's own login window still protects the Mac.
final class LockController {
    static let shared = LockController()
    private(set) var isShowing = false
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    func toggle() { isShowing ? hide() : show() }

    func show() {
        guard !isShowing else { return }
        isShowing = true
        Live.overlay = true
        previousApp = NSWorkspace.shared.frontmostApplication
        NowPlaying.shared.fastPolling = true
        NowPlaying.shared.poll()
        ClaudeUsage.shared.refresh()
        Battery.shared.refresh()

        let main = NSScreen.main ?? NSScreen.screens.first
        windows = NSScreen.screens.map { screen in
            let view = LockView(isMain: screen == main, previewBackground: true, dismiss: { [weak self] in self?.hide() })
            let w = OverlayWindow(screen: screen, content: AnyView(view))
            w.alphaValue = 0
            w.orderFrontRegardless()
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first { $0.screen == main }?.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch Int(event.keyCode) {
            case 36, 76, 53: self?.hide(); return nil          // Return, Enter, Escape
            case 49: NowPlaying.shared.playPause(); return nil  // Space
            case 123: NowPlaying.shared.previous(); return nil  // ←
            case 124: NowPlaying.shared.next(); return nil      // →
            case 126: NowPlaying.shared.setVolume(min(100, NowPlaying.shared.volume + 6)); return nil  // ↑
            case 125: NowPlaying.shared.setVolume(max(0, NowPlaying.shared.volume - 6)); return nil    // ↓
            default: return event
            }
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        Live.overlay = false
        NowPlaying.shared.fastPolling = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            closing.forEach { w in
                w.animator().alphaValue = 0
                var f = w.frame; f.origin.y += 40
                w.animator().setFrame(f, display: true)
            }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil); $0.contentView = nil }
            ImageCache.purge()
        })
        if let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier { app.activate() }
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, content: AnyView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        // The view draws the wallpaper itself (sharp unless the face asks for blur); this only fills in while it loads.
        blur.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: content)
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        contentView = blur
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
