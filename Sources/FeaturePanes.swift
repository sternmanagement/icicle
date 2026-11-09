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
