import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, layout, snapping, hotkeys, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Menu Bar Layout"
        case .snapping: return "Window Snapping"
        case .hotkeys: return "Hotkeys"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How hidden items appear and disappear."
        case .layout: return "Choose which icons stay in your menu bar."
        case .snapping: return "Drag a window to the top of the screen to pick a layout."
        case .hotkeys: return "Keyboard shortcuts that work in any app."
        case .about: return "Icicle, a tidy menu bar for your Mac."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .layout: return "menubar.rectangle"
        case .snapping: return "rectangle.split.2x2.fill"
        case .hotkeys: return "command"
        case .about: return "snowflake"
        }
    }

    var colors: [Color] {
        switch self {
        case .general: return [Color(white: 0.62), Color(white: 0.45)]
        case .layout: return [Color(red: 0.36, green: 0.70, blue: 1.0), Color(red: 0.13, green: 0.45, blue: 0.95)]
        case .snapping: return [Color(red: 0.70, green: 0.48, blue: 1.0), Color(red: 0.47, green: 0.27, blue: 0.92)]
        case .hotkeys: return [Color(red: 1.0, green: 0.62, blue: 0.30), Color(red: 0.96, green: 0.40, blue: 0.20)]
        case .about: return [Color(red: 0.50, green: 0.85, blue: 1.0), Color(red: 0.15, green: 0.50, blue: 0.90)]
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab? = .general
}

final class SettingsWindowController {
    var showAllItems: (() -> Void)?

    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(tab: SettingsTab) {
        navigation.tab = tab
        if window == nil {
            let root = SettingsView(
                settings: .shared,
                navigation: navigation,
                showAllItems: { [weak self] in self?.showAllItems?() }
            )
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Icicle Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
