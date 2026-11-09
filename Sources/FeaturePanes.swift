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
                AccessibilityRow(reason: "Needed to list, move and bring forward other apps' windows.")
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.workspacesEnabled)
    }

    private func saveLayout() {
        guard AccessibilityAccess.isTrusted else { AccessibilityAccess.request(); return }
        let count = workspaces.saveCurrentLayout(named: newName)
        savedMessage = "Saved \(count) windows."
        newName = ""
    }
}
