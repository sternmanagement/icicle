import SwiftUI

let claudeTint = Color(red: 0.85, green: 0.47, blue: 0.34)

// MARK: - Clawd: a little pixel creature for Claude Code

/// Walks and waves its claws while Claude Code is working; blinks and dozes when idle.
/// Small previews (thumbnails, Settings) set this so dozens of copies don't animate at once.
private struct StillPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var stillPreview: Bool { get { self[StillPreviewKey.self] } set { self[StillPreviewKey.self] = newValue } }
}

struct Clawd: View {
    var working: Bool
    var size: CGFloat = 40
    var color: Color = claudeTint
    @Environment(\.stillPreview) private var still

    var body: some View {
        // Walking needs ~6 frames a second; dozing only changes when it blinks or the "z" moves.
        TimelineView(.periodic(from: .now, by: still ? 3600 : (working ? 0.16 : 0.6))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, sz in
                let px = sz.width / 14
                let frame = Int(t / 0.16)
                let step = working ? frame % 2 : 0
                let bob: CGFloat = working ? (step == 0 ? 0 : -1) : 0
                let blink = !working && t.truncatingRemainder(dividingBy: 4.2) < 0.18
                func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ c: Color) {
                    g.fill(Path(CGRect(x: x * px, y: (y + bob) * px, width: w * px + 0.5, height: h * px + 0.5)), with: .color(c))
                }
                let eye = Color(red: 0.16, green: 0.09, blue: 0.07)
                // Body
                cell(2, 2, 10, 5, color)
                cell(3, 1, 8, 1, color)
                // Claws: raised in turn while working
                let left: CGFloat = working && step == 0 ? 2 : 3
                let right: CGFloat = working && step == 1 ? 2 : 3
                cell(0, left, 2, 2, color); cell(0, left - 1, 1, 1, color)
                cell(12, right, 2, 2, color); cell(13, right - 1, 1, 1, color)
                // Eyes
                if blink { cell(4, 4, 2, 0.5, eye); cell(8, 4, 2, 0.5, eye) }
                else { cell(4, 3, 1, 2, eye); cell(9, 3, 1, 2, eye) }
                // Legs: alternate pairs while working
                let up: CGFloat = 7, down: CGFloat = 7.5
                for (i, x) in [3.0, 5.0, 8.0, 10.0].enumerated() {
                    let y = working ? ((i % 2 == step) ? up : down) : up
                    g.fill(Path(CGRect(x: x * px, y: y * px, width: px, height: 1.6 * px)), with: .color(color))
                }
                // Idle: a small "z"
                if !working {
                    let z = Int(t / 1.2) % 3
                    g.draw(Text("z").font(.system(size: px * 2.6, weight: .bold, design: .rounded)).foregroundColor(.secondary.opacity(0.8)),
                           at: CGPoint(x: 12.5 * px + CGFloat(z) * px * 0.4, y: 0.4 * px - CGFloat(z) * px * 0.3))
                }
            }
        }
        .frame(width: size, height: size * 9 / 14)
        .accessibilityLabel(working ? "Claude Code is working" : "Claude Code is idle")
    }
}

// MARK: - Inline widget (the line above the clock)

struct InlineWidgetView: View {
    let kind: InlineWidget
    let date: Date
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var events = EventsService.shared
    @ObservedObject private var battery = Battery.shared
    @ObservedObject private var claude = ClaudeUsage.shared

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
            .onAppear(perform: start)
    }

    private func start() {
        if kind == .dateWeather || kind == .sunrise { weather.ensureStarted() }
        if kind == .nextEvent { events.ensureStarted(events: true, reminders: false) }
    }

    private var dateText: Text { Text(date, format: .dateTime.weekday(.wide).month(.wide).day()) }

    @ViewBuilder private var content: some View {
        switch kind {
        case .date: dateText
        case .dateWeather:
            Text(date, format: .dateTime.weekday(.abbreviated).day())
            if let t = weather.temperature { Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical); Text("\(t)°") }
        case .nextEvent:
            Image(systemName: "calendar")
            if let e = events.events.first {
                Text(e.title)
                Text((Calendar.current.isDateInToday(e.start) || e.start < date ? "" : "Tomorrow ") + (e.allDay ? "All Day" : e.start.formatted(date: .omitted, time: .shortened))).opacity(0.7)
            } else { Text("No more events today") }
        case .battery:
            Image(systemName: battery.symbol); Text(battery.percent.map { "\($0)%" } ?? "No battery")
        case .sunrise:
            if let rise = weather.sunrise, let set = weather.sunset {
                let nextIsRise = rise < set
                Image(systemName: nextIsRise ? "sunrise.fill" : "sunset.fill").symbolRenderingMode(.hierarchical)
                Text((nextIsRise ? rise : set).formatted(date: .omitted, time: .shortened))
            } else { Image(systemName: "sunrise.fill"); Text("—") }
        case .moon:
            let m = Moon.info(date)
            Image(systemName: m.symbol); Text(m.name)
        case .claude:
            Clawd(working: claude.isWorking, size: 26)
            Text("\(compactNumber(claude.totalTokens)) tokens today")
        case .none: EmptyView()
        }
    }
}

// MARK: - Small and wide widgets

struct LockWidget: View {
    let item: WidgetItem
    let date: Date
    var tint: Color = .primary
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var events = EventsService.shared
    @ObservedObject private var battery = Battery.shared
    @ObservedObject private var claude = ClaudeUsage.shared

    static let unit: CGFloat = 78
    static let gap: CGFloat = 10
    @Environment(\.stillPreview) private var still

    var body: some View {
        Group {
            if item.size == .small { small } else { wide }
        }
        .foregroundStyle(tint)
        .frame(width: item.size == .small ? Self.unit : Self.unit * 2 + Self.gap, height: Self.unit)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.07)))
        .onAppear(perform: start)
    }

    private func start() {
        // Library tiles and thumbnails show what's already loaded; they never trigger permission prompts.
        guard !still else { return }
        switch item.kind {
        case .weather, .sunrise: weather.ensureStarted()
        case .calendar: events.ensureStarted(events: true, reminders: false)
        case .reminders: events.ensureStarted(events: false, reminders: true)
        default: break
        }
    }

    private var zone: TimeZone { item.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var city: String { WorldClocks.name(for: item.timeZone) }
    private func zoneTime(_ style: Date.FormatStyle.TimeStyle = .shortened) -> String {
        var f = Date.FormatStyle(date: .omitted, time: style); f.timeZone = zone
        return date.formatted(f)
    }

    // MARK: Small

    @ViewBuilder private var small: some View {
        switch item.kind {
        case .weather:
            VStack(spacing: 2) {
                Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical).font(.system(size: 22))
                Text(weather.temperature.map { "\($0)°" } ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded))
            }
        case .calendar:
            VStack(spacing: 0) {
                Text(date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 12, weight: .bold)).textCase(.uppercase).foregroundStyle(.red)
                Text(date, format: .dateTime.day()).font(.system(size: 32, weight: .semibold, design: .rounded))
            }
        case .reminders:
            VStack(spacing: 2) {
                Image(systemName: "checklist").font(.system(size: 20))
                Text("\(events.reminderCount)").font(.system(size: 20, weight: .semibold, design: .rounded))
            }
        case .battery:
            Gauge(value: Double(battery.percent ?? 0), in: 0...100) {
                Image(systemName: battery.charging ? "bolt.fill" : "laptopcomputer")
            } currentValueLabel: { Text("\(battery.percent ?? 0)") }
            .gaugeStyle(.accessoryCircularCapacity)
        case .worldClock:
            VStack(spacing: 2) {
                Text(String(city.prefix(3)).uppercased()).font(.system(size: 12, weight: .bold)).opacity(0.7)
                Text(zoneTime()).font(.system(size: 15, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6)
        case .sunrise:
            VStack(spacing: 3) {
                let next = nextSun
                Image(systemName: next.rise ? "sunrise.fill" : "sunset.fill").symbolRenderingMode(.hierarchical).font(.system(size: 22))
                Text(next.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        case .moon:
            let m = Moon.info(date)
            VStack(spacing: 3) {
                Image(systemName: m.symbol).font(.system(size: 26))
                Text("\(m.illumination)%").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        case .claude:
            VStack(spacing: 4) {
                Clawd(working: claude.isWorking, size: 40)
                Text(compactNumber(claude.totalTokens)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }

    private var nextSun: (rise: Bool, date: Date?) {
        guard let r = weather.sunrise, let s = weather.sunset else { return (true, nil) }
        return r < s ? (true, r) : (false, s)
    }

    // MARK: Wide

    @ViewBuilder private var wide: some View {
        HStack(alignment: .center, spacing: 10) {
            switch item.kind {
            case .weather:
                Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 1) {
                    Text(weather.temperature.map { "\($0)°" } ?? "—").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(weather.problem == nil ? weather.condition : "Set a city").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let h = weather.high, let l = weather.low { Text("H:\(h)° L:\(l)°").font(.system(size: 11)).opacity(0.7) }
                }
            case .calendar:
                if let e = events.events.first {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text((Calendar.current.isDateInToday(e.start) || e.start < date ? "" : "Tomorrow, ") + (e.allDay ? "All Day" : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"))
                            .font(.system(size: 12)).opacity(0.75)
                    }
                } else {
                    Image(systemName: "calendar").font(.system(size: 24))
                    Text(events.calendarAccess == false ? "Allow Calendar access in System Settings" : "No more events today")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
            case .reminders:
                VStack(alignment: .leading, spacing: 4) {
                    if events.reminders.isEmpty {
                        Label(events.reminderAccess == false ? "Allow Reminders access" : "All done", systemImage: "checkmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    ForEach(events.reminders.prefix(2)) { r in
                        HStack(spacing: 6) {
                            Circle().strokeBorder(Color(nsColor: r.color), lineWidth: 1.5).frame(width: 11, height: 11)
                            Text(r.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                    }
                }
            case .battery:
                Image(systemName: battery.charging ? "laptopcomputer.and.arrow.down" : "laptopcomputer").font(.system(size: 24))
                VStack(alignment: .leading, spacing: 4) {
                    Text(battery.percent.map { "\($0)%" } ?? "No battery").font(.system(size: 18, weight: .semibold, design: .rounded))
                    ProgressView(value: Double(battery.percent ?? 0), total: 100).progressViewStyle(.linear).frame(width: 80)
                }
            case .worldClock:
                VStack(alignment: .leading, spacing: 1) {
                    Text(city).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(zoneTime()).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(WorldClocks.offset(zone, at: date)).font(.system(size: 11)).opacity(0.7)
                }
            case .sunrise:
                Image(systemName: "sun.horizon.fill").symbolRenderingMode(.hierarchical).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Label(weather.sunrise?.formatted(date: .omitted, time: .shortened) ?? "—", systemImage: "sunrise.fill")
                    Label(weather.sunset?.formatted(date: .omitted, time: .shortened) ?? "—", systemImage: "sunset.fill")
                }
                .font(.system(size: 13, weight: .semibold))
            case .moon:
                let m = Moon.info(date)
                Image(systemName: m.symbol).font(.system(size: 32))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name).font(.system(size: 14, weight: .semibold))
                    Text("\(m.illumination)% illuminated").font(.system(size: 12)).opacity(0.75)
                }
            case .claude:
                Clawd(working: claude.isWorking, size: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(claude.isWorking ? "Working" : "Idle").font(.system(size: 12, weight: .semibold)).opacity(0.75)
                    Text(compactNumber(claude.totalTokens)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("tokens · \(claude.sessions.count) session\(claude.sessions.count == 1 ? "" : "s")").font(.system(size: 11)).opacity(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

enum WorldClocks {
    static let cities: [(String, String)] = [
        ("Cupertino", "America/Los_Angeles"), ("New York", "America/New_York"), ("Chicago", "America/Chicago"),
        ("Denver", "America/Denver"), ("London", "Europe/London"), ("Paris", "Europe/Paris"), ("Berlin", "Europe/Berlin"),
        ("Tel Aviv", "Asia/Jerusalem"), ("Dubai", "Asia/Dubai"), ("Mumbai", "Asia/Kolkata"), ("Singapore", "Asia/Singapore"),
        ("Hong Kong", "Asia/Hong_Kong"), ("Tokyo", "Asia/Tokyo"), ("Sydney", "Australia/Sydney"), ("São Paulo", "America/Sao_Paulo"),
        ("Honolulu", "Pacific/Honolulu"),
    ]
    static func name(for id: String?) -> String {
        guard let id else { return "Local" }
        return cities.first { $0.1 == id }?.0 ?? id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
    }
    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let diff = (zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
        if diff == 0 { return "Same time" }
        let day = Calendar.current.dateComponents(in: zone, from: date).day != Calendar.current.component(.day, from: date)
        return (day ? (diff > 0 ? "Tomorrow, " : "Yesterday, ") : "Today, ") + (diff > 0 ? "+\(diff)" : "\(diff)") + " hrs"
    }
}

// MARK: - Opening the app behind a widget or notification

/// Like widgets on iPhone: clicking one opens the app it comes from (and closes the lock screen).
enum AppLink {
    static func open(_ kind: WidgetKind) {
        switch kind {
        case .weather, .sunrise, .moon: openApp("com.apple.weather")
        case .calendar: openApp("com.apple.iCal")
        case .reminders: openApp("com.apple.reminders")
        case .worldClock: openApp("com.apple.clock")
        case .battery: openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        case .claude: openTerminal()
        }
    }

    static func open(_ inline: InlineWidget) {
        switch inline {
        case .date, .nextEvent: openApp("com.apple.iCal")
        case .dateWeather, .sunrise, .moon: openApp("com.apple.weather")
        case .battery: openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        case .claude: openTerminal()
        case .none: break
        }
    }

    /// The app a notification came from, if there is one to open.
    static func canOpen(_ item: InboxItem) -> Bool {
        switch item.source { case .system: item.bundleId != nil; case .claude, .update: true; case .timer: false }
    }
    static func open(_ item: InboxItem) {
        switch item.source {
        case .system: if let id = item.bundleId { openApp(id) }
        case .claude: openTerminal()
        case .update: LockController.shared.hide(); Updater.shared.promptInstall()
        case .timer: break
        }
    }

    static func openApp(_ bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        LockController.shared.hide()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        LockController.shared.hide()
        NSWorkspace.shared.open(url)
    }

    /// Claude Code runs in a terminal: bring forward whichever terminal app is running, else Terminal.
    static func openTerminal() {
        let terminals = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.apple.Terminal"]
        let running = terminals.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        openApp(running ?? "com.apple.Terminal")
    }
}

/// Makes a widget open its app when clicked, except in the editor and on the real lock screen (which can't be clicked).
struct OpensApp: ViewModifier {
    let action: () -> Void
    @Environment(\.editor) private var editor
    @ViewBuilder func body(content: Content) -> some View {
        if editor == nil && !GL.isSaver {
            content.contentShape(Rectangle()).onTapGesture(perform: action).onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            content
        }
    }
}
