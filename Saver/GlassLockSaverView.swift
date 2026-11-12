import ScreenSaver
import SwiftUI

/// Glass Lock as a macOS screen saver, so it appears on the real lock screen.
/// Built from the app's own view code; the app writes a snapshot of live data that this reads.
@objc(GlassLockSaverView)
final class GlassLockSaverView: ScreenSaverView {
    private var host: NSHostingView<AnyView>?

    override init?(frame: NSRect, isPreview: Bool) {
        GL.isSaver = true
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 2
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        SnapshotReader.load()
        install()

        if !isPreview {
            // Since macOS 14 the host process keeps running after the screen saver ends; quit with it.
            // Only a full-screen instance does this, so previews in System Settings are never cut off.
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in
                guard let self, let window = self.window, let screen = window.screen, window.frame == screen.frame else { return }
                exit(0)
            }
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    private func install() {
        // Every display gets the full lock screen: inside Apple's screen saver host the window's screen
        // can't be matched reliably to the main display, and a clock-only screen hid all the widgets.
        let root: AnyView = isPreview ? AnyView(SaverPreview()) : AnyView(SaverRoot(isMain: true))
        if let host { host.rootView = root; return }
        let h = NSHostingView(rootView: root)
        h.frame = bounds
        h.autoresizingMask = [.width, .height]
        addSubview(h)
        host = h
    }

    override func animateOneFrame() { SnapshotReader.load() }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}

private struct SaverRoot: View {
    let isMain: Bool
    @ObservedObject private var store = FaceStore.shared
    var body: some View {
        // macOS draws its own date and large clock in the top third; the widgets start just below it.
        GeometryReader { geo in
            LockView(faceOverride: store.active, isMain: isMain, previewBackground: true,
                     systemClockInset: geo.size.height * 0.34, dismiss: {})
        }
        .background(Color.black)
    }
}

private struct SaverPreview: View {
    @ObservedObject private var store = FaceStore.shared
    var body: some View {
        FacePreview(face: store.active, cornerRadius: 0)
            .background(Color.black)
    }
}
