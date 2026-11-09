import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SwitcherWindow: Identifiable {
    let id = UUID()
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let isMinimized: Bool

    /// Brings the window forward. macOS 14+ won't let a background app activate another one directly,
    /// so this goes through Accessibility: un-minimize, raise, and mark the app frontmost.
    func focus() {
        if isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum WindowCatalog {
    /// Every standard window of every regular app, most recently used apps first; minimized windows last.
    static func windows(appOrder: [pid_t]) -> [SwitcherWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        let rank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = apps.sorted { (rank[$0.processIdentifier] ?? .max) < (rank[$1.processIdentifier] ?? .max) }

        var open: [SwitcherWindow] = []
        var minimized: [SwitcherWindow] = []
        for app in ordered {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            // The windows attribute lists front to back within the app.
            for element in axApp.elements(kAXWindowsAttribute) {
                guard element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
                let isMinimized = (element.value(kAXMinimizedAttribute) as? Bool) ?? false
                let title = element.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Window"
                let window = SwitcherWindow(element: element, pid: app.processIdentifier, appName: app.localizedName ?? "",
                                            icon: app.icon, title: title, isMinimized: isMinimized)
                if isMinimized { minimized.append(window) } else { open.append(window) }
            }
        }
        return open + minimized
    }
}

final class WindowSwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
}

/// Alt-Tab-style switching: hold the modifier, tap the key to step through windows, release to switch.
final class WindowSwitcher {
    static let columns = 6

    private let model = WindowSwitcherModel()
    private var panel: KeyablePanel?
    private var modifierPoll: Timer?
    private var keyMonitor: Any?
    private var heldModifiers: NSEvent.ModifierFlags = []
    /// Apps in the order they were last active, most recent first.
    private var appOrder: [pid_t] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { appOrder = [front.processIdentifier] }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.appOrder.removeAll { $0 == app.processIdentifier }
            self.appOrder.insert(app.processIdentifier, at: 0)
        }
    }

    /// Called for each press of the shortcut; `backwards` for the ⇧ variant.
    func advance(backwards: Bool, combo: KeyCombo) {
        guard AccessibilityAccess.isTrusted else {
            AccessibilityAccess.request()
            return
        }
        if panel?.isVisible == true {
            step(backwards ? -1 : 1)
            return
        }
        let windows = WindowCatalog.windows(appOrder: appOrder)
        guard !windows.isEmpty else { NSSound.beep(); return }
        model.windows = windows
        // The first window is usually the one you're in, so start on the next one.
        model.selection = windows.count > 1 ? (backwards ? windows.count - 1 : 1) : 0
        heldModifiers = combo.modifierFlags.subtracting(.shift)
        show()
    }

    private func step(_ delta: Int) {
        guard !model.windows.isEmpty else { return }
        model.selection = (model.selection + delta + model.windows.count) % model.windows.count
    }

    private func show() {
        let count = model.windows.count
        let cols = min(count, Self.columns)
        let rows = Int(ceil(Double(count) / Double(Self.columns)))
        let size = NSSize(width: CGFloat(cols) * SwitcherTile.size.width + CGFloat(cols - 1) * 8 + 32,
                          height: CGFloat(min(rows, 4)) * (SwitcherTile.size.height + 8) + 24)
        let panel = KeyablePanel(size: size)
        panel.setContent(WindowSwitcherView(model: model, choose: { [weak self] index in
            self?.model.selection = index
            self?.commit()
        }), cornerRadius: 20)
        panel.onResignKey = { [weak self] in self?.cancel() }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: self.cancel()
            case kVK_RightArrow: self.step(1)
            case kVK_LeftArrow: self.step(-1)
            case kVK_DownArrow: self.step(Self.columns)
            case kVK_UpArrow: self.step(-Self.columns)
            case kVK_Return: self.commit()
            default: return event
            }
            return nil
        }
        // Releasing the held modifier picks the selected window.
        modifierPoll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !NSEvent.modifierFlags.isSuperset(of: self.heldModifiers) { self.commit() }
        }
    }

    private func commit() {
        let chosen = model.windows.indices.contains(model.selection) ? model.windows[model.selection] : nil
        dismiss()
        chosen?.focus()
    }

    private func cancel() { dismiss() }

    private func dismiss() {
        modifierPoll?.invalidate()
        modifierPoll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

extension KeyCombo {
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// The same shortcut with ⇧ added, for stepping backwards.
    var withShift: KeyCombo {
        KeyCombo(keyCode: keyCode, carbonModifiers: carbonModifiers | UInt32(shiftKey), keyName: keyName)
    }
}

struct WindowSwitcherView: View {
    @ObservedObject var model: WindowSwitcherModel
    let choose: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(SwitcherTile.size.width), spacing: 8),
                                         count: min(model.windows.count, WindowSwitcher.columns)), spacing: 8) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                        SwitcherTile(window: window, isSelected: index == model.selection)
                            .id(index)
                            .onTapGesture { choose(index) }
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selection) { _, selection in proxy.scrollTo(selection) }
        }
    }
}

private struct SwitcherTile: View {
    static let size = CGSize(width: 128, height: 138)

    let window: SwitcherWindow
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 60, height: 60)
                        .opacity(window.isMinimized ? 0.55 : 1)
                }
                if window.isMinimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .gray)
                }
            }
            Text(window.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(window.appName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.snapHighlight.opacity(0.35) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.snapHighlight : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}
