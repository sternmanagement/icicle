import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum HotCornerPosition: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var name: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    func point(in frame: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.minY)
        }
    }
}

enum HotCornerAction: String, CaseIterable, Identifiable {
    case none, lockScreen, lockMac, menuBarItems, clipboard, missionControl, appWindows, showDesktop,
         screenSaver, displaySleep, openApp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .lockScreen: return "Open Lock Screen"
        case .lockMac: return "Lock Mac"
        case .menuBarItems: return "Show or Hide Menu Bar Icons"
        case .clipboard: return "Clipboard History"
        case .missionControl: return "Mission Control"
        case .appWindows: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .screenSaver: return "Start Screen Saver"
        case .displaySleep: return "Put Display to Sleep"
        case .openApp: return "Open an App…"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "minus"
        case .lockScreen: return "lock.display"
        case .lockMac: return "lock.fill"
        case .menuBarItems: return "menubar.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .showDesktop: return "desktopcomputer"
        case .screenSaver: return "sparkles.tv"
        case .displaySleep: return "moon.fill"
        case .openApp: return "app.badge"
        }
    }
}

/// A key to hold while pushing into a corner, so corners don't go off by accident.
enum HotCornerModifier: String, CaseIterable, Identifiable {
    case none, command, option, control, shift

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
}

extension AppSettings {
    func hotCornerAction(_ corner: HotCornerPosition) -> HotCornerAction {
        HotCornerAction(rawValue: hotCorners[corner.rawValue] ?? "") ?? .none
    }

    func hotCornerAppName(_ corner: HotCornerPosition) -> String? {
        hotCornerApps[corner.rawValue].map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
    }

    /// The corner that opens the lock screen, as its raw value ("" for none), for the pickers that offer just that.
    var lockScreenCorner: Binding<String> {
        Binding(get: { HotCornerPosition.allCases.first { self.hotCornerAction($0) == .lockScreen }?.rawValue ?? "" },
                set: { new in
                    var map = self.hotCorners.filter { $0.value != HotCornerAction.lockScreen.rawValue }
                    if !new.isEmpty { map[new] = HotCornerAction.lockScreen.rawValue }
                    self.hotCorners = map
                })
    }
}

/// Icicle's hot corners: push the pointer into a screen corner and hold it there a moment to run that
/// corner's action. Watching the pointer needs no special permission; it's one cheap position check per
/// mouse movement, and nothing is watched while every corner is set to Nothing.
final class HotCorners {
    static let shared = HotCorners()

    var toggleMenuBarItems: (() -> Void)?
    var toggleClipboard: (() -> Void)?

    private let settings = AppSettings.shared
    private var monitors: [Any] = []
    private var armed: HotCornerPosition?
    private var waitingToLeave = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        apply()
    }

    private var isActive: Bool {
        HotCornerPosition.allCases.contains { settings.hotCornerAction($0) != .none }
    }

    private func apply() {
        guard isActive != !monitors.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard isActive else { return }
        // Flag changes count too: with a key required, the pointer may already be resting in the corner.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.check() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in self?.check(); return e }) { monitors.append(m) }
    }

    /// The corner the pointer is pressed into, if any.
    private func cornerUnderPointer(tolerance: CGFloat) -> HotCornerPosition? {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return nil }
        return HotCornerPosition.allCases.first {
            let target = $0.point(in: screen.frame)
            return hypot(p.x - target.x, p.y - target.y) < tolerance
        }
    }

    private var modifierHeld: Bool {
        let required = settings.hotCornerModifier.flags
        return required.isEmpty || NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(required)
    }

    private func check() {
        // After a corner fires, the pointer has to leave it before any corner can fire again.
        if waitingToLeave {
            if cornerUnderPointer(tolerance: 60) == nil { waitingToLeave = false }
            return
        }
        guard let corner = cornerUnderPointer(tolerance: 4), settings.hotCornerAction(corner) != .none, modifierHeld,
              NSEvent.pressedMouseButtons == 0 else {
            armed = nil
            return
        }
        guard armed != corner else { return }
        armed = corner
        // A short pause in the corner, so brushing past it does nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, settings.hotCornerDelay)) { [weak self] in self?.fire(corner) }
    }

    private func fire(_ corner: HotCornerPosition) {
        guard armed == corner, cornerUnderPointer(tolerance: 6) == corner, modifierHeld else {
            if armed == corner { armed = nil }
            return
        }
        armed = nil
        waitingToLeave = true
        perform(settings.hotCornerAction(corner), corner: corner)
    }

    func perform(_ action: HotCornerAction, corner: HotCornerPosition) {
        switch action {
        case .none:
            break
        case .lockScreen:
            if settings.lockScreenEnabled { LockController.shared.toggle() }
        case .lockMac:
            Self.lockMac()
        case .menuBarItems:
            toggleMenuBarItems?()
        case .clipboard:
            toggleClipboard?()
        case .missionControl:
            Self.missionControl()
        case .appWindows:
            Self.missionControl(argument: "2")
        case .showDesktop:
            Self.missionControl(argument: "1")
        case .screenSaver:
            // Any movement ends a screen saver, so wait for the pointer to settle in the corner first.
            LockScreenSetup.shared.startWhenHandsOff()
        case .displaySleep:
            Self.displaySleep()
        case .openApp:
            guard let path = settings.hotCornerApps[corner.rawValue] else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Mission Control is an app; an argument picks Show Desktop ("1") or Application Windows ("2").
    private static func missionControl(argument: String? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let argument { configuration.arguments = [argument] }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: configuration)
    }

    private static func displaySleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// With Icicle's lock screen set up, locks into it. Otherwise asks macOS for its own lock screen, the
    /// same call the Apple menu's Lock Screen makes; there's no public one.
    private static func lockMac() {
        if AppSettings.shared.lockScreenEnabled, LockScreenSetup.shared.isSelected {
            LockScreenSetup.shared.lockNow()
            return
        }
        typealias LockFunction = @convention(c) () -> Int32
        if let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(login, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
        } else {
            displaySleep()
        }
    }
}

// MARK: - Settings

struct HotCornersPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    HStack {
                        picker(.topLeft)
                        Spacer(minLength: 12)
                        picker(.topRight)
                    }
                    ScreenMock(active: Set(HotCornerPosition.allCases.filter { settings.hotCornerAction($0) != .none }))
                        .frame(width: 250, height: 150)
                    HStack {
                        picker(.bottomLeft)
                        Spacer(minLength: 12)
                        picker(.bottomRight)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                caption("Choose what each corner of the screen does, on every display. macOS has hot corners of its own (System Settings → Desktop & Dock → Hot Corners); if both use the same corner, both things happen.")
            }

            Section {
                Picker("Only while holding", selection: $settings.hotCornerModifier) {
                    ForEach(HotCornerModifier.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Wait in the corner") {
                    HStack {
                        Slider(value: $settings.hotCornerDelay, in: 0.05...1, step: 0.05)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.2f s", settings.hotCornerDelay))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("Trigger")
            } footer: {
                caption("A longer wait, or a key to hold, keeps corners from going off when the pointer only passes through.")
            }
        }
        .formStyle(.grouped)
    }

    private func picker(_ corner: HotCornerPosition) -> some View {
        Picker(corner.name, selection: action(corner)) {
            ForEach(availableActions(for: corner)) { action in
                Label(title(action, corner), systemImage: action.symbol).tag(action)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(corner.name)
    }

    /// The lock screen action is only offered while the lock screen is on (or already chosen).
    private func availableActions(for corner: HotCornerPosition) -> [HotCornerAction] {
        HotCornerAction.allCases.filter { $0 != .lockScreen || settings.lockScreenEnabled || settings.hotCornerAction(corner) == .lockScreen }
    }

    private func title(_ action: HotCornerAction, _ corner: HotCornerPosition) -> String {
        if action == .openApp, settings.hotCornerAction(corner) == .openApp, let name = settings.hotCornerAppName(corner) {
            return "Open \(name)"
        }
        return action.title
    }

    private func action(_ corner: HotCornerPosition) -> Binding<HotCornerAction> {
        Binding(get: { settings.hotCornerAction(corner) },
                set: { new in
                    if new == .openApp {
                        // Choosing "Open an App…" again picks a different app; cancelling leaves things as they were.
                        guard let path = chooseApp() else { return }
                        settings.hotCornerApps[corner.rawValue] = path
                    }
                    settings.hotCorners[corner.rawValue] = new == .none ? nil : new.rawValue
                })
    }

    private func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A little display with its active corners lit up.
private struct ScreenMock: View {
    let active: Set<HotCornerPosition>

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#3B6FD9"), Color(hex: "#7B4FD6")], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 2)
            ForEach(HotCornerPosition.allCases) { corner in
                Circle()
                    .fill(active.contains(corner) ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 12, height: 12)
                    .shadow(color: .white.opacity(active.contains(corner) ? 0.8 : 0), radius: 6)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
            }
        }
        .animation(.easeOut(duration: 0.2), value: active)
    }

    private func alignment(_ corner: HotCornerPosition) -> Alignment {
        switch corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}
