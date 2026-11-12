import SwiftUI
import EventKit
import CoreLocation
import ServiceManagement

/// The first-run guide: every permission and setting Icicle needs, each with one button and a live check mark.
/// Opens by itself on first launch (and after an update that needs something new); reopen it from the menu bar.
enum SetupWindow {
    private static var window: NSWindow?
    /// Bump when a new step is added, so existing users see the guide once more.
    static let version = 1

    static var needsShowing: Bool { UserDefaults.standard.integer(forKey: "setupVersion") < version }

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Set Up Icicle"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView())
            w.center()
            window = w
            Live.track(w) { window = nil; UserDefaults.standard.set(version, forKey: "setupVersion") }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

private struct SetupStep: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let done: Bool
    var optional = false
    var button: String? = nil
    var action: (() -> Void)? = nil
}

struct SetupView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var notes = SystemNotifications.shared
    @ObservedObject private var setup = LockScreenSetup.shared
    @State private var tick = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to Icicle").font(.title.weight(.semibold))
                Text("A few quick steps and everything works. Each one has a button; the check mark turns green when it's done.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            .padding(.top, 36).padding(.bottom, 16)

            // Reading `tick` makes the checks re-run every refresh without rebuilding the window.
            let list = steps(tick)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(list) { row($0) }
                    if settings.lockScreenEnabled { openRow }
                }
                .padding(.horizontal, 24).padding(.vertical, 6)
            }

            Divider()
            HStack {
                let required = list.filter { !$0.optional }
                let left = required.filter { !$0.done }.count
                Text(left == 0 ? "You're all set." : "\(left) step\(left == 1 ? "" : "s") left")
                    .foregroundStyle(left == 0 ? Color.green : Color.secondary)
                Spacer()
                Button(left == 0 ? "Done" : "Finish Later") { SetupWindow.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 600, height: 720)
        .onReceive(timer) { _ in recheck() }
        .onAppear(perform: recheck)
    }

    /// Re-reads the permission states (cheap; only while this window is open).
    private func recheck() {
        setup.refresh()
        if notes.access != .granted { notes.refresh() }
        tick &+= 1
    }

    private func row(_ s: SetupStep) -> some View {
        HStack(spacing: 14) {
            Image(systemName: s.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.title).font(.headline)
                    if s.optional { Text("Optional").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                Text(s.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if s.done {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            } else if let title = s.button, let action = s.action {
                Button(title, action: action).controlSize(.large)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Choosing how to open the lock screen is always "done"; it just shows the current choices.
    private var openRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "cursorarrow.motionlines").font(.system(size: 20)).foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("How to open the lock screen").font(.headline)
                HStack {
                    Text("Hot corner").foregroundStyle(.secondary)
                    Picker("", selection: settings.lockScreenCorner) {
                        Text("Off").tag("")
                        ForEach(HotCornerPosition.allCases) { Text($0.name).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 140)
                }
                HStack {
                    Text("Shortcut").foregroundStyle(.secondary)
                    KeyRecorder(combo: $settings.lockScreenOpenHotKey)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static let location = CLLocationManager()

    private func steps(_ refresh: Int) -> [SetupStep] {
        var list: [SetupStep] = []

        let inApps = AppLocation.isInApplications
        list.append(SetupStep(id: "apps", symbol: "folder", title: "Move to Applications",
                              detail: "Icicle updates itself from there.", done: inApps,
                              button: "Move", action: { AppLocation.moveToApplications() }))

        list.append(SetupStep(id: "ax", symbol: "accessibility", title: "Accessibility",
                              detail: "Lets Icicle snap windows, arrange menu bar icons and switch between windows. Click Allow, then switch Icicle on in the list.",
                              done: AccessibilityAccess.isTrusted,
                              button: "Allow…", action: { AccessibilityAccess.request() }))

        let login = SMAppService.mainApp.status == .enabled
        list.append(SetupStep(id: "login", symbol: "power", title: "Open at login",
                              detail: "Icicle is there after every restart, and the lock screen stays up to date.", done: login,
                              button: "Turn On", action: { try? SMAppService.mainApp.register(); recheck() }))

        // The rest sets up the lock screen, which is optional.
        guard settings.lockScreenEnabled else {
            list.append(SetupStep(id: "lockscreen", symbol: "lock.display", title: "Lock screen with widgets",
                                  detail: "A lock screen with Now Playing, timers, widgets, notifications and Claude Code activity.",
                                  done: false, optional: true, button: "Turn On", action: { settings.lockScreenEnabled = true }))
            return list
        }

        let fda = notes.access == .granted
        list.append(SetupStep(id: "fda", symbol: "bell.badge", title: "Notifications from your apps",
                              detail: "For the lock screen. Click Allow, then drag Icicle into the Full Disk Access list and switch it on. Icicle only reads your notifications.",
                              done: fda, button: "Allow…", action: {
                                  notes.openFullDiskAccessSettings()
                                  NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                              }))

        let cal = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let rem = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        list.append(SetupStep(id: "cal", symbol: "calendar", title: "Calendar and Reminders",
                              detail: "For the Calendar and Reminders widgets.", done: cal && rem,
                              button: "Allow", action: {
                                  let denied = [EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder)].contains(.denied)
                                  if denied { AppStatus.openPrivacy("Privacy_Calendars") }
                                  EventsService.shared.ensureStarted(events: true, reminders: true)
                              }))

        let loc = Self.location.authorizationStatus
        let hasCity = !prefs.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty
        list.append(SetupStep(id: "loc", symbol: "location", title: "Location for weather",
                              detail: hasCity ? "Using \(prefs.weatherCity)." : "Or type a city in Customize → Widgets instead.",
                              done: hasCity || loc == .authorizedAlways || loc == .authorized, optional: true,
                              button: "Allow", action: {
                                  if loc == .denied { AppStatus.openPrivacy("Privacy_LocationServices") }
                                  WeatherService.shared.ensureStarted(); WeatherService.shared.refresh()
                              }))

        list.append(SetupStep(id: "music", symbol: "music.note", title: "Music and Spotify",
                              detail: "Play something in Music or Spotify, click Allow, and say OK when macOS asks.",
                              done: UserDefaults.standard.bool(forKey: "musicAllowed"), optional: true,
                              button: "Allow", action: {
                                  NowPlaying.shared.poll()
                                  if NowPlaying.shared.hasTrack { UserDefaults.standard.set(true, forKey: "musicAllowed") }
                              }))

        list.append(SetupStep(id: "lock", symbol: "lock.display", title: "Show it when your Mac locks",
                              detail: "Choose Glass Lock, Icicle's screen saver, so the lock screen shows when your Mac locks or goes idle.",
                              done: setup.isSelected, optional: true,
                              button: setup.isInstalled ? "Choose…" : "Set Up…",
                              action: { setup.isInstalled ? setup.openSettings() : setup.install() }))
        return list
    }
}

/// Where the app is running from. Updates replace the app in place, which needs it in an Applications folder.
enum AppLocation {
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Copies the app to /Applications (replacing an older copy) and reopens it from there.
    static func moveToApplications() {
        let src = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(q(dest.path)) && /usr/bin/ditto \(q(src.path)) \(q(dest.path)) || exit 1
        /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path)) 2>/dev/null
        /usr/bin/open \(q(dest.path))
        """
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            let a = NSAlert()
            a.messageText = "Drag Icicle to Applications"
            a.informativeText = "Icicle can't copy itself there. Open the download, drag Icicle onto the Applications folder, and open it from there."
            a.runModal(); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// On launch from a download or the disk image, offer to move first. A copy run from anywhere else
    /// (a build folder, say) was put there on purpose.
    static func offerMoveIfNeeded() {
        let path = Bundle.main.bundlePath
        let fromDownload = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") || path.hasPrefix(NSHomeDirectory() + "/Downloads/")
        guard !isInApplications, fromDownload, Bundle.main.bundleIdentifier != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move Icicle to Applications?"
        a.informativeText = "Icicle works best, and can update itself, from your Applications folder."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { moveToApplications() }
    }
}
