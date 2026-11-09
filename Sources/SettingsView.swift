import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var navigation: SettingsNavigation
    let itemsModel: MenuBarItemsModel
    let showAllItems: () -> Void

    var body: some View {
        let selected = navigation.tab ?? .general
        HStack(spacing: 0) {
            // A hand-built sidebar: NavigationSplitView ignores column widths in a fixed-size window.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarRow(tab: tab, isSelected: tab == selected) { navigation.tab = tab }
                }
                Spacer()
            }
            .padding(.top, 50)
            .padding(.horizontal, 10)
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .background(SidebarMaterial().ignoresSafeArea())

            Divider().ignoresSafeArea()

            VStack(spacing: 0) {
                PaneHeader(tab: selected)
                detail(for: selected)
            }
            .id(selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780)
        // Flexible height: with a full-size content view the window adds the title bar's height on top of this.
        .frame(minHeight: 580, idealHeight: 580, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPane(settings: settings)
        case .layout: LayoutPane(settings: settings, items: itemsModel, showAllItems: showAllItems)
        case .snapping: SnappingPane(settings: settings)
        case .windows: WindowsPane(settings: settings)
        case .clipboard: ClipboardPane(settings: settings, history: .shared)
        case .appearance: AppearancePane(settings: settings)
        case .hotkeys: HotkeysPane(settings: settings)
        case .about: AboutPane()
        }
    }
}

// MARK: - Shared pieces

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconBadge(tab: tab, size: 22)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct IconBadge: View {
    let tab: SettingsTab
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: tab.colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: tab.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: size * 0.04, y: size * 0.03)
    }
}

private struct PaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(tab: tab, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.title2.weight(.semibold))
                Text(tab.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 4)
    }
}

/// Green "Granted" pill, or a button that opens the system prompt.
struct AccessibilityRow: View {
    let reason: String
    @State private var trusted = AccessibilityAccess.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: trusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(trusted ? .green : .orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access")
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if trusted {
                Text("Granted")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access…") { AccessibilityAccess.request() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onReceive(poll) { _ in trusted = AccessibilityAccess.isTrusted }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Menu bar icon") {
                    IconStylePicker(selection: $settings.iconStyle)
                }
                Toggle("Show section divider icons", isOn: $settings.showSectionDividers)
            }

            Section("Showing hidden items") {
                Toggle("Click an empty area of the menu bar", isOn: $settings.showOnClick)
                Toggle("Hover over an empty area of the menu bar", isOn: $settings.showOnHover)
                if settings.showOnHover {
                    AccessibilityRow(reason: "Lets Icicle tell empty menu bar space apart from app menus.")
                }
            }

            Section("Rehiding") {
                Toggle("Automatically rehide", isOn: $settings.autoRehide)
                if settings.autoRehide {
                    Picker("Rehide", selection: $settings.rehideStrategy) {
                        ForEach(RehideStrategy.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.rehideStrategy == .timed {
                        LabeledContent("Delay") {
                            HStack {
                                Slider(value: $settings.rehideDelay, in: 2...60, step: 1)
                                    .frame(maxWidth: 220)
                                Text("\(Int(settings.rehideDelay)) s")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.autoRehide)
        .animation(.default, value: settings.showOnHover)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct IconStylePicker: View {
    @Binding var selection: IconStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(IconStyle.allCases) { style in
                let isOn = style == selection
                Button { selection = style } label: {
                    Image(systemName: style.hiddenSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.07))
                        )
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(style.title)
            }
        }
    }
}

// MARK: - Layout

private struct LayoutPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var items: MenuBarItemsModel
    let showAllItems: () -> Void
    @State private var trusted = AccessibilityAccess.isTrusted
    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var sections: [MenuBarSection] {
        settings.alwaysHiddenEnabled ? [.visible, .hidden, .alwaysHidden] : [.visible, .hidden]
    }

    var body: some View {
        Form {
            if trusted, !items.isEditing {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash").font(.title3).foregroundStyle(.secondary)
                        Text("Hidden icons are tucked away again. Edit the layout to show every icon and rearrange them.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Edit Layout") { items.startEditing() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if trusted {
                Section {
                    HStack {
                        Toggle("Hide all non-Apple icons", isOn: Binding(
                            get: { settings.hideNonAppleIcons },
                            set: { hide in
                                settings.hideNonAppleIcons = hide
                                items.moveAllNonApple(to: hide ? .hidden : .visible)
                            }
                        ))
                        .disabled(items.movingID != nil)
                        if items.isBatchMoving {
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    Text(items.isBatchMoving
                         ? "Moving icons… the pointer will jump around for a moment."
                         : "Puts every app's icon in the Hidden section so only Apple's (battery, Wi-Fi, clock…) stay out. Click ❄ to see them. Turn it off to bring them all back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(sections) { section in
                    Section {
                        let entries = items.entries.filter { $0.section == section && !$0.item.isInSystemOverflow }
                        if entries.isEmpty {
                            Text(section == .visible ? "No other icons are visible." : "Nothing here yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            MenuBarItemRow(entry: entry, sections: sections, items: items)
                        }
                    } header: {
                        SectionHeader(section: section)
                    } footer: {
                        if section == sections.last {
                            VStack(alignment: .leading, spacing: 6) {
                                if let failure = items.failure {
                                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                Text("Pick a section for any icon. Icicle ⌘-drags it there for you, so the pointer jumps for a moment. Every icon stays shown while you edit; click ❄ when you're done to hide them.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                let overflow = items.entries.filter { $0.item.isInSystemOverflow }
                if !overflow.isEmpty {
                    Section {
                        ForEach(overflow) { entry in
                            MenuBarItemRow(entry: entry, sections: [], items: items)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right.2")
                            Text("No Room").fontWeight(.semibold)
                            Text("· In the macOS overflow menu").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("The menu bar is full (the camera notch takes space), so macOS tucked these away. Hide a few other icons to make room for them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Section {
                    AccessibilityRow(reason: "Lets Icicle list your menu bar icons and move them between sections.")
                }
            }

            Section {
                Toggle("Always-hidden section", isOn: $settings.alwaysHiddenEnabled)
            } footer: {
                Text("Adds a second divider. Icons in it stay hidden until you ⌥-click the ❄ icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Arrange by hand") {
                    VStack(alignment: .leading, spacing: 16) {
                        MenuBarMock(alwaysHiddenEnabled: settings.alwaysHiddenEnabled)
                        VStack(alignment: .leading, spacing: 8) {
                            Step(number: 1, text: "Click **Show All Items** so every icon is on screen.")
                            Step(number: 2, text: "Hold **⌘ Command** and drag icons in the menu bar. Anything left of the **‹** divider gets hidden.")
                            Step(number: 3, text: "Click the **❄** icon to hide or show that section.")
                        }
                        Button(action: showAllItems) {
                            Label("Show All Items", systemImage: "eye")
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.alwaysHiddenEnabled)
        .onAppear { if trusted { items.startEditing() } }
        .onDisappear { items.stopEditing() }
        .onReceive(poll) { _ in
            if !trusted, AccessibilityAccess.isTrusted { items.startEditing() }
            trusted = AccessibilityAccess.isTrusted
            if trusted { items.refresh() }
        }
    }
}

private struct SectionHeader: View {
    let section: MenuBarSection

    private var detail: String {
        switch section {
        case .visible: return "Always in the menu bar"
        case .hidden: return "Shown when you click ❄"
        case .alwaysHidden: return "Shown when you ⌥-click ❄"
        }
    }

    private var symbol: String {
        switch section {
        case .visible: return "eye"
        case .hidden: return "eye.slash"
        case .alwaysHidden: return "lock"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(section.title).fontWeight(.semibold)
            Text("· \(detail)").foregroundStyle(.secondary)
        }
    }
}

private struct MenuBarItemRow: View {
    let entry: MenuBarItemsModel.Entry
    let sections: [MenuBarSection]
    @ObservedObject var items: MenuBarItemsModel

    var body: some View {
        let item = entry.item
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon, icon.isTemplate {
                    Image(nsImage: icon).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                        .padding(2)
                        .foregroundStyle(.secondary)
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if item.title != item.appName {
                    Text(item.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if items.movingID == entry.id {
                ProgressView().controlSize(.small)
            }
            if sections.isEmpty {
                EmptyView()
            } else if item.isMovable {
                Picker("", selection: Binding(
                    get: { entry.section },
                    set: { items.move(entry, to: $0) }
                )) {
                    ForEach(sections) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(items.movingID != nil)
            } else {
                Text("Fixed by macOS").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A miniature menu bar over a wallpaper gradient, with each section tinted and labelled.
private struct MenuBarMock: View {
    let alwaysHiddenEnabled: Bool

    private let alwaysHiddenTint = Color.gray
    private let hiddenTint = Color.blue
    private let visibleTint = Color.green

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.62, blue: 0.48), Color(red: 0.56, green: 0.40, blue: 0.86), Color(red: 0.20, green: 0.36, blue: 0.80)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(height: 96)

                HStack(spacing: 9) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Spacer(minLength: 8)
                    if alwaysHiddenEnabled {
                        group(["cloud", "printer"], tint: alwaysHiddenTint)
                        divider(dimmed: true)
                    }
                    group(["music.note", "message", "bolt.horizontal"], tint: hiddenTint)
                    divider(dimmed: false)
                    group(["paperplane", "calendar"], tint: visibleTint)
                    Image(systemName: "snowflake").fontWeight(.semibold)
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("9:41")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(.regularMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            HStack(spacing: 16) {
                if alwaysHiddenEnabled { legend("Always hidden", tint: alwaysHiddenTint) }
                legend("Hidden", tint: hiddenTint)
                legend("Visible", tint: visibleTint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func group(_ symbols: [String], tint: Color) -> some View {
        HStack(spacing: 7) {
            ForEach(symbols, id: \.self) { Image(systemName: $0) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.28)))
    }

    private func divider(dimmed: Bool) -> some View {
        Image(systemName: "chevron.compact.left")
            .fontWeight(.bold)
            .opacity(dimmed ? 0.4 : 1)
    }

    private func legend(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint.opacity(0.7)).frame(width: 8, height: 8)
            Text(title)
        }
    }
}

// MARK: - Snapping

private struct SnappingPane: View {
    @ObservedObject var settings: AppSettings
    @State private var demoHighlight = 0
    private let cycle = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(SnapLayout.all) { layout in
                            VStack(spacing: 5) {
                                LayoutThumbnail(layout: layout, highlight: demoHighlight % layout.zones.count)
                                    .frame(height: 50)
                                Text(layout.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: demoHighlight)
                    Text("Drag a window by its title bar into the menu bar. Keep the mouse button held, move onto a zone in the flyout, and let go.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Show Snap Layouts when dragging a window to the top", isOn: $settings.snapLayoutsEnabled)
                Toggle("Snap to halves and corners at screen edges", isOn: $settings.edgeSnappingEnabled)
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $settings.snapGap, in: 0...24, step: 2)
                            .frame(maxWidth: 220)
                        Text("\(Int(settings.snapGap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                SystemDragRow()
                AccessibilityRow(reason: "Required to move and resize other apps' windows.")
            }
        }
        .formStyle(.grouped)
        .onReceive(cycle) { _ in demoHighlight += 1 }
    }
}

/// Switch that turns off Mission Control's top-edge drag and macOS tiling so Icicle gets the drag.
private struct SystemDragRow: View {
    @State private var icicleHandles = SystemDragSettings.icicleHandlesDrags
    @State private var detail = SystemDragRow.currentDetail()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icicleHandles ? "rectangle.split.2x1.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(icicleHandles ? .green : .orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Let Icicle handle window dragging")
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { icicleHandles },
                set: { enabled in
                    SystemDragSettings.setIcicleHandlesDrags(enabled)
                    refresh()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        icicleHandles = SystemDragSettings.icicleHandlesDrags
        detail = Self.currentDetail()
    }

    private static func currentDetail() -> String {
        var conflicts: [String] = []
        if SystemDragSettings.missionControlOnTopDrag { conflicts.append("dragging to the top opens Mission Control") }
        if SystemDragSettings.systemTiling { conflicts.append("macOS tiling shows its own previews") }
        guard !conflicts.isEmpty else {
            return "Mission Control and macOS tiling no longer react to drags. Turn off to restore them."
        }
        let joined = conflicts.joined(separator: " and ")
        return "Right now \(joined). Turning this on switches those off and restarts the Dock."
    }
}

// MARK: - Hotkeys

private struct HotkeysPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu bar") {
                LabeledContent("Show or hide hidden items") {
                    KeyRecorder(combo: $settings.toggleHiddenHotKey)
                }
                LabeledContent("Show or hide always-hidden items") {
                    KeyRecorder(combo: $settings.toggleAlwaysHiddenHotKey)
                }
                .disabled(!settings.alwaysHiddenEnabled)
            }

            Section {
                LabeledContent("Snap to left half") {
                    KeyRecorder(combo: $settings.snapLeftHotKey)
                }
                LabeledContent("Snap to right half") {
                    KeyRecorder(combo: $settings.snapRightHotKey)
                }
                LabeledContent("Fill screen") {
                    KeyRecorder(combo: $settings.snapMaximizeHotKey)
                }
            } header: {
                Text("Window snapping")
            } footer: {
                Text("Click a shortcut, then press the new key combination. It must include ⌘, ⌥ or ⌃. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { isRecording ? stop() : start() }) {
                Text(isRecording ? "Type shortcut…" : (combo?.displayString ?? "Record Shortcut"))
                    .font(combo == nil || isRecording ? .callout : .system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                    .frame(minWidth: 130)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(isRecording ? 0.0 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isRecording ? 1.5 : 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: { combo = nil }) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
            .opacity(combo != nil && !isRecording ? 1 : 0)
            .disabled(combo == nil || isRecording)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        HotKeyCenter.shared.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyCenter.shared.isPaused = false
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .blue.opacity(0.25), radius: 18, y: 8)
            VStack(spacing: 4) {
                Text("Icicle").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Hide the menu bar icons you rarely need, and snap windows into tidy layouts.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 8) {
                FeatureChip(symbol: "menubar.rectangle", title: "Menu bar sections")
                FeatureChip(symbol: "rectangle.split.2x2", title: "Snap Layouts")
                FeatureChip(symbol: "command", title: "Global hotkeys")
            }
            Spacer()
            HStack {
                Text("Inspired by Ice by Jordan Baird.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Icicle") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeatureChip: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
