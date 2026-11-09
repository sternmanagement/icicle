import AppKit
import Combine

enum RehideStrategy: String, CaseIterable, Identifiable {
    case timed
    case focusedApp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .timed: return "After a delay"
        case .focusedApp: return "When the frontmost app changes"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case snowflake, chevron, dot, ellipsis

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var hiddenSymbol: String {
        switch self {
        case .snowflake: return "snowflake"
        case .chevron: return "chevron.left"
        case .dot: return "circle.fill"
        case .ellipsis: return "ellipsis"
        }
    }

    var visibleSymbol: String {
        switch self {
        case .snowflake: return "snowflake.circle"
        case .chevron: return "chevron.right"
        case .dot: return "circle"
        case .ellipsis: return "ellipsis.circle"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var autoRehide: Bool { didSet { defaults.set(autoRehide, forKey: Key.autoRehide) } }
    @Published var rehideStrategy: RehideStrategy { didSet { defaults.set(rehideStrategy.rawValue, forKey: Key.rehideStrategy) } }
    @Published var rehideDelay: Double { didSet { defaults.set(rehideDelay, forKey: Key.rehideDelay) } }
    @Published var showOnHover: Bool { didSet { defaults.set(showOnHover, forKey: Key.showOnHover) } }
    @Published var showOnClick: Bool { didSet { defaults.set(showOnClick, forKey: Key.showOnClick) } }
    @Published var showSectionDividers: Bool { didSet { defaults.set(showSectionDividers, forKey: Key.showSectionDividers) } }
    @Published var alwaysHiddenEnabled: Bool { didSet { defaults.set(alwaysHiddenEnabled, forKey: Key.alwaysHiddenEnabled) } }
    @Published var iconStyle: IconStyle { didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) } }
    @Published var toggleHiddenHotKey: KeyCombo? { didSet { save(toggleHiddenHotKey, forKey: Key.toggleHiddenHotKey) } }
    @Published var toggleAlwaysHiddenHotKey: KeyCombo? { didSet { save(toggleAlwaysHiddenHotKey, forKey: Key.toggleAlwaysHiddenHotKey) } }

    @Published var snapLayoutsEnabled: Bool { didSet { defaults.set(snapLayoutsEnabled, forKey: Key.snapLayoutsEnabled) } }
    @Published var edgeSnappingEnabled: Bool { didSet { defaults.set(edgeSnappingEnabled, forKey: Key.edgeSnappingEnabled) } }
    @Published var snapGap: Double { didSet { defaults.set(snapGap, forKey: Key.snapGap) } }
    @Published var snapLeftHotKey: KeyCombo? { didSet { save(snapLeftHotKey, forKey: Key.snapLeftHotKey) } }
    @Published var snapRightHotKey: KeyCombo? { didSet { save(snapRightHotKey, forKey: Key.snapRightHotKey) } }
    @Published var snapMaximizeHotKey: KeyCombo? { didSet { save(snapMaximizeHotKey, forKey: Key.snapMaximizeHotKey) } }

    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) } }
    @Published var clipboardAutoPaste: Bool { didSet { defaults.set(clipboardAutoPaste, forKey: Key.clipboardAutoPaste) } }
    @Published var clipboardHotKey: KeyCombo? { didSet { save(clipboardHotKey, forKey: Key.clipboardHotKey) } }

    @Published var windowSwitcherEnabled: Bool { didSet { defaults.set(windowSwitcherEnabled, forKey: Key.windowSwitcherEnabled) } }
    @Published var windowSwitcherHotKey: KeyCombo? { didSet { save(windowSwitcherHotKey, forKey: Key.windowSwitcherHotKey) } }
    @Published var workspacesEnabled: Bool { didSet { defaults.set(workspacesEnabled, forKey: Key.workspacesEnabled) } }
    @Published var workspaceHotKeysEnabled: Bool { didSet { defaults.set(workspaceHotKeysEnabled, forKey: Key.workspaceHotKeysEnabled) } }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    private enum Key {
        static let autoRehide = "autoRehide"
        static let rehideStrategy = "rehideStrategy"
        static let rehideDelay = "rehideDelay"
        static let showOnHover = "showOnHover"
        static let showOnClick = "showOnClick"
        static let showSectionDividers = "showSectionDividers"
        static let alwaysHiddenEnabled = "alwaysHiddenEnabled"
        static let iconStyle = "iconStyle"
        static let toggleHiddenHotKey = "toggleHiddenHotKey"
        static let toggleAlwaysHiddenHotKey = "toggleAlwaysHiddenHotKey"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let snapLayoutsEnabled = "snapLayoutsEnabled"
        static let edgeSnappingEnabled = "edgeSnappingEnabled"
        static let snapGap = "snapGap"
        static let snapLeftHotKey = "snapLeftHotKey"
        static let snapRightHotKey = "snapRightHotKey"
        static let snapMaximizeHotKey = "snapMaximizeHotKey"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardAutoPaste = "clipboardAutoPaste"
        static let clipboardHotKey = "clipboardHotKey"
        static let windowSwitcherEnabled = "windowSwitcherEnabled"
        static let windowSwitcherHotKey = "windowSwitcherHotKey"
        static let workspacesEnabled = "workspacesEnabled"
        static let workspaceHotKeysEnabled = "workspaceHotKeysEnabled"
    }

    private init() {
        defaults.register(defaults: [
            Key.autoRehide: true,
            Key.rehideStrategy: RehideStrategy.timed.rawValue,
            Key.rehideDelay: 10.0,
            Key.showOnHover: false,
            Key.showOnClick: true,
            Key.showSectionDividers: true,
            Key.alwaysHiddenEnabled: false,
            Key.iconStyle: IconStyle.snowflake.rawValue,
            Key.snapLayoutsEnabled: true,
            Key.edgeSnappingEnabled: true,
            Key.snapGap: 8.0,
            Key.clipboardEnabled: true,
            Key.clipboardAutoPaste: true,
            Key.windowSwitcherEnabled: false,
            Key.workspacesEnabled: false,
            Key.workspaceHotKeysEnabled: true,
        ])

        autoRehide = defaults.bool(forKey: Key.autoRehide)
        rehideStrategy = RehideStrategy(rawValue: defaults.string(forKey: Key.rehideStrategy) ?? "") ?? .timed
        rehideDelay = defaults.double(forKey: Key.rehideDelay)
        showOnHover = defaults.bool(forKey: Key.showOnHover)
        showOnClick = defaults.bool(forKey: Key.showOnClick)
        showSectionDividers = defaults.bool(forKey: Key.showSectionDividers)
        alwaysHiddenEnabled = defaults.bool(forKey: Key.alwaysHiddenEnabled)
        iconStyle = IconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .snowflake
        toggleHiddenHotKey = Self.load(Key.toggleHiddenHotKey, from: defaults, fallback: .defaultToggleHidden)
        toggleAlwaysHiddenHotKey = Self.load(Key.toggleAlwaysHiddenHotKey, from: defaults, fallback: nil)
        snapLayoutsEnabled = defaults.bool(forKey: Key.snapLayoutsEnabled)
        edgeSnappingEnabled = defaults.bool(forKey: Key.edgeSnappingEnabled)
        snapGap = defaults.double(forKey: Key.snapGap)
        snapLeftHotKey = Self.load(Key.snapLeftHotKey, from: defaults, fallback: .defaultSnapLeft)
        snapRightHotKey = Self.load(Key.snapRightHotKey, from: defaults, fallback: .defaultSnapRight)
        snapMaximizeHotKey = Self.load(Key.snapMaximizeHotKey, from: defaults, fallback: .defaultMaximize)
        clipboardEnabled = defaults.bool(forKey: Key.clipboardEnabled)
        clipboardAutoPaste = defaults.bool(forKey: Key.clipboardAutoPaste)
        clipboardHotKey = Self.load(Key.clipboardHotKey, from: defaults, fallback: .defaultClipboard)
        windowSwitcherEnabled = defaults.bool(forKey: Key.windowSwitcherEnabled)
        windowSwitcherHotKey = Self.load(Key.windowSwitcherHotKey, from: defaults, fallback: .defaultWindowSwitcher)
        workspacesEnabled = defaults.bool(forKey: Key.workspacesEnabled)
        workspaceHotKeysEnabled = defaults.bool(forKey: Key.workspaceHotKeysEnabled)
    }

    // Empty data marks a shortcut the user deliberately cleared, so it doesn't fall back to the default.
    private func save(_ combo: KeyCombo?, forKey key: String) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults, fallback: KeyCombo?) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
