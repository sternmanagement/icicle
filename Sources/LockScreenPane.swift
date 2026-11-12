import AppKit
import SwiftUI

/// Settings → Lock Screen: the design, how to open it, and getting it onto the real macOS lock screen.
struct LockScreenPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var faces = FaceStore.shared
    @ObservedObject private var setup = LockScreenSetup.shared
    @ObservedObject private var systemNotes = SystemNotifications.shared
    @ObservedObject private var claude = ClaudeUsage.shared

    var body: some View {
        Form {
            Section {
                Toggle("Lock screen", isOn: $settings.lockScreenEnabled)
            } footer: {
                caption("A lock screen with a clock, Now Playing, timers, widgets, your notifications and Claude Code activity. Open it over your desktop any time, or have it appear whenever your Mac locks.")
            }

            if settings.lockScreenEnabled {
                Section("Design") {
                    FacePreview(face: faces.active)
                        .frame(height: 250)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .onTapGesture { CustomizeWindow.show() }
                    HStack {
                        Picker("Current", selection: $faces.activeId) {
                            ForEach(faces.faces) { Text($0.name).tag($0.id) }
                        }
                        Button("Customize…") { CustomizeWindow.show() }
                    }
                }

                Section {
                    Picker("Hot corner", selection: settings.lockScreenCorner) {
                        Text("Off").tag("")
                        ForEach(HotCornerPosition.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    LabeledContent("Open or close") { KeyRecorder(combo: $settings.lockScreenOpenHotKey) }
                    Button("Open Now") { LockController.shared.show() }
                } header: {
                    Text("On your desktop")
                } footer: {
                    caption("Push the pointer into the corner, or press the shortcut, to open the lock screen on top of your desktop without locking. Press the shortcut again, Esc, or click the background to close it. The other corners are yours to set in Hot Corners.")
                }

                Section {
                    realLockScreen
                } header: {
                    Text("When your Mac locks")
                } footer: {
                    caption("Apple doesn't let apps replace the password screen itself, so the lock screen runs on top of it as a screen saver named Glass Lock. Press any key or click to get the password prompt.")
                }

                Section("Notifications") {
                    switch systemNotes.access {
                    case .granted:
                        LabeledContent("Notifications from your apps") {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    default:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show notifications from your other apps")
                            caption("macOS keeps them in a protected place. Turn on Icicle under Full Disk Access, then come back here. Icicle only reads your notifications; nothing leaves your Mac.")
                        }
                        HStack {
                            Button("Open Full Disk Access…") { systemNotes.openFullDiskAccessSettings() }
                            Button("Check Again") { systemNotes.refresh() }
                        }
                    }
                }

                Section("Claude Code") {
                    LabeledContent("Today") {
                        Text(claude.available
                             ? "\(compactNumber(claude.totalTokens)) tokens · \(claude.sessions.count) session\(claude.sessions.count == 1 ? "" : "s")"
                             : "No activity found")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Reads") { Text("~/.claude/projects").foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.lockScreenEnabled)
        .onAppear { setup.refresh(); systemNotes.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refresh(); systemNotes.refresh()
        }
    }

    @ViewBuilder private var realLockScreen: some View {
        if setup.isInstalled && !setup.isSelected {
            VStack(alignment: .leading, spacing: 4) {
                Label("One more step", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                caption("In System Settings → Screen Saver, scroll to Other and click Glass Lock. Until then your Mac shows Apple's screen saver when it locks.")
            }
            HStack {
                Button("Open Screen Saver Settings…") { setup.openSettings() }
                Button("Check Again") { setup.refresh() }
            }
        } else if setup.isInstalled {
            LabeledContent("Icicle is your lock screen") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Toggle("Show it whenever you lock your Mac", isOn: $prefs.saverOnLock)
            LabeledContent("Lock now") { KeyRecorder(combo: $settings.lockNowHotKey) }
            HStack {
                Button("Lock Now") { setup.lockNow() }
                Button("Screen Saver Settings…") { setup.openSettings() }
                Button("Lock Screen Settings…") { setup.openLockSettings() }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use it as your Mac's lock screen")
                caption("macOS asks to install the Glass Lock screen saver. Choose Install, and it appears whenever your Mac locks or goes idle.")
            }
            Button("Set Up Lock Screen…") { setup.install() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings → About: checking for and installing new versions from GitHub.
struct UpdateRow: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if !statusText.isEmpty { Text(statusText).font(.callout).foregroundStyle(.secondary) }
                if case .available = updater.status {
                    Button("Install Update…") { updater.promptInstall() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Check for Updates") { updater.check(userInitiated: true) }
                        .disabled(updater.status == .checking || updater.status == .downloading || updater.status == .installing)
                }
            }
            Toggle("Check automatically", isOn: $prefs.autoCheckUpdates)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }

    private var statusText: String {
        switch updater.status {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let version): return "Version \(version) is available"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed: return "Couldn't check"
        }
    }
}
