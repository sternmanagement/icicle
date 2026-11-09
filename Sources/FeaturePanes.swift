import AppKit
import SwiftUI

// Settings panes for the extras: clipboard, windows and appearance.

struct ClipboardPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistory

    var body: some View {
        Form {
            Section {
                Toggle("Keep clipboard history", isOn: $settings.clipboardEnabled)
                LabeledContent("Open history") {
                    KeyRecorder(combo: $settings.clipboardHotKey)
                }
                .disabled(!settings.clipboardEnabled)
                Toggle("Paste the chosen item right away", isOn: $settings.clipboardAutoPaste)
                    .disabled(!settings.clipboardEnabled)
            } footer: {
                Text("Press the shortcut in any app, pick an item with the arrow keys or ⌘1–9, and press Return. Without automatic pasting, the item is just copied back so you can press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.clipboardEnabled {
                Section {
                    LabeledContent("Items remembered") {
                        Text("\(history.items.count) of \(ClipboardHistory.capacity)").monospacedDigit()
                    }
                    Button("Clear History", role: .destructive) { history.clear() }
                        .disabled(history.items.isEmpty)
                } footer: {
                    Text("History stays in memory and is forgotten when Icicle quits. Copies that password managers mark as private are never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.clipboardAutoPaste {
                Section {
                    AccessibilityRow(reason: "Needed to paste into other apps for you.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.clipboardEnabled)
    }
}

struct WindowsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var workspaces = WorkspaceStore.shared
    @State private var newName = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Window switcher", isOn: $settings.windowSwitcherEnabled)
                LabeledContent("Shortcut") {
                    KeyRecorder(combo: $settings.windowSwitcherHotKey)
                }
                .disabled(!settings.windowSwitcherEnabled)
            } header: {
                Text("Switcher")
            } footer: {
                Text("Hold the modifier and tap the key to step through every window, minimized ones included. Add ⇧ to go backwards, use the arrow keys, or click a window. Let go to switch; Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Saved workspaces", isOn: $settings.workspacesEnabled)
                if settings.workspacesEnabled {
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("e.g. Coding"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveLayout)
                        Button("Save Current Layout", action: saveLayout)
                    }
                    if let savedMessage {
                        Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(workspaces.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        HStack(spacing: 10) {
                            Image(systemName: "square.grid.3x1.below.line.grid.1x2").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(workspace.name)
                                Text("\(workspace.windows.count) windows · \(Set(workspace.windows.map(\.appName)).count) apps")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index < 9, settings.workspaceHotKeysEnabled {
                                Text("⌃⌥\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Button("Restore") { workspaces.restore(workspace) }
                            Button(role: .destructive) { workspaces.delete(workspace) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Toggle("Restore with ⌃⌥1 – ⌃⌥9", isOn: $settings.workspaceHotKeysEnabled)
                }
            } header: {
                Text("Workspaces")
            } footer: {
                Text("A workspace remembers where every app's windows are. Restoring opens apps that aren't running and puts their windows back. Also in the ❄ menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Outline the focused window", isOn: $settings.focusBorderEnabled)
                if settings.focusBorderEnabled {
                    ColorPicker("Colour", selection: $settings.focusBorderColor.color, supportsOpacity: true)
                    LabeledContent("Thickness") {
                        HStack {
                            Slider(value: $settings.focusBorderWidth, in: 2...10, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(settings.focusBorderWidth)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Focus border")
            } footer: {
                Text("Draws a coloured outline around whichever window you're typing in, so it's easy to spot. Hidden for full-screen windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                AccessibilityRow(reason: "Needed to list, move and bring forward other apps' windows.")
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.workspacesEnabled)
        .animation(.default, value: settings.focusBorderEnabled)
    }

    private func saveLayout() {
        guard AccessibilityAccess.isTrusted else { AccessibilityAccess.request(); return }
        let count = workspaces.saveCurrentLayout(named: newName)
        savedMessage = "Saved \(count) windows."
        newName = ""
    }
}

struct AppearancePane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Tint the menu bar", isOn: $settings.menuBarTintEnabled)
                if settings.menuBarTintEnabled {
                    Picker("Style", selection: $settings.menuBarTintStyle) {
                        ForEach(TintStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    tintRow("Light mode", start: $settings.tintLightStart, end: $settings.tintLightEnd, scheme: .light)
                    tintRow("Dark mode", start: $settings.tintDarkStart, end: $settings.tintDarkEnd, scheme: .dark)
                }
            } header: {
                Text("Menu bar tint")
            } footer: {
                Text("Pick separate colours for light and dark mode; lower the opacity in the colour picker for a subtler wash. macOS picks the menu bar's text colour from your wallpaper, so very dark or very light tints can make it harder to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Hide the notch", isOn: $settings.hideNotch)
                    .disabled(!NSScreen.screens.contains(where: MenuBarAppearance.hasNotch))
            } header: {
                Text("Notch")
            } footer: {
                Text(NSScreen.screens.contains(where: MenuBarAppearance.hasNotch)
                     ? "Paints the menu bar black on displays with a camera notch so the notch blends in. Takes priority over the tint there. Reads best in Dark Mode, where the menu bar text is white."
                     : "None of your displays has a camera notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.menuBarTintEnabled)
    }

    private func tintRow(_ title: String, start: Binding<String>, end: Binding<String>, scheme: ColorScheme) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                TintPreview(colors: settings.menuBarTintStyle == .gradient ? [start.wrappedValue, end.wrappedValue] : [start.wrappedValue],
                            scheme: scheme)
                ColorPicker("Start", selection: start.color, supportsOpacity: true).labelsHidden()
                if settings.menuBarTintStyle == .gradient {
                    ColorPicker("End", selection: end.color, supportsOpacity: true).labelsHidden()
                }
            }
        }
    }
}

/// A sliver of menu bar showing the tint over a wallpaper-ish backdrop.
private struct TintPreview: View {
    let colors: [String]
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.15), Color(white: 0.3)] : [Color(white: 0.85), Color(white: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Spacer()
                Image(systemName: "wifi")
                Text("9:41")
            }
            .font(.system(size: 9))
            .foregroundStyle(scheme == .dark ? .white : .black)
            .padding(.horizontal, 8)
        }
        .frame(width: 170, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}
