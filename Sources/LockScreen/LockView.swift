import SwiftUI

enum EditTarget: String, Hashable { case wallpaper, inline, clock, widgets, content }

struct LockView: View {
    var faceOverride: LockFace? = nil
    let isMain: Bool
    var editing: Binding<EditTarget?>? = nil
    var chrome: CGFloat = 1             // multiplier that keeps edit outlines readable when the preview is scaled down
    var previewBackground = false       // draw the desktop picture instead of relying on the window's blur
    /// On the real lock screen macOS draws its own date and time on top, so the view leaves that space
    /// empty and starts its widgets this far down, with no name or hint at the bottom.
    var systemClockInset: CGFloat? = nil
    let dismiss: () -> Void

    @ObservedObject private var store = FaceStore.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var acts = Activities.shared
    @ObservedObject private var claude = ClaudeUsage.shared
    @ObservedObject private var music = NowPlaying.shared
    @State private var drag: CGFloat = 0
    @State private var leaving = false
    /// How far the screen has been pushed up by a swipe (0 at rest).
    private var lift: CGFloat { max(0, -drag) }

    /// Closing animation: everything slides up and away, shrinking a little, then the window fades.
    private func close() {
        guard !leaving else { return }
        leaving = true
        withAnimation(.easeIn(duration: 0.24)) { drag = -max(canvas.height, 600) * 0.55 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { leaving = false; drag = 0 }
        }
    }
    @State private var canvas: CGSize = .zero
    @Environment(\.editor) private var editor

    private var face: LockFace { faceOverride ?? store.active }
    private var isEditing: Bool { editing != nil }
    private var mediaMode: Bool { face.enabled(.nowPlaying) && music.hasTrack && music.isPlaying }
    private var showClaude: Bool { face.enabled(.claude) && claude.available && !claude.sessions.isEmpty }
    private var busy: Bool { mediaMode || (face.enabled(.activities) && !acts.items.isEmpty) || showClaude }
    private var tint: Color { face.colorHex == nil ? .primary : face.clockColor }

    var body: some View {
        ZStack {
            WallpaperView(wallpaper: face.wallpaper, preview: previewBackground)
                .scaleEffect(1 + lift / 8000)
                .overlay(Color.black.opacity(min(0.35, lift / 1400)).allowsHitTesting(false))
                .overlay {
                    // The background takes clicks and swipes: a click or a two-finger (or click-drag) swipe up closes
                    // Glass Lock; on cards, scrolling and dragging work on the cards instead.
                    BackgroundInput(
                        onTap: { if let editing { editing.wrappedValue = .wallpaper } else { close() } },
                        onSwipe: { amount in if !isEditing && !leaving { drag = -max(0, amount) } },
                        onSwipeEnd: { amount, velocity in
                            guard !isEditing && !leaving else { return }
                            if amount > 110 || velocity > 900 { close() }
                            else { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { drag = 0 } }
                        })
                }
            if mediaMode && !isEditing {
                RadialGradient(colors: [Color.accentColor.opacity(0.3), .clear], center: .top, startRadius: 0, endRadius: 900)
                    .allowsHitTesting(false)
            }
            content
            freeWidgetLayer
            if let editor, editor.guideV { Rectangle().fill(Color.yellow).frame(width: 2 * chrome).allowsHitTesting(false) }
            if let editor, editor.guideH { Rectangle().fill(Color.yellow).frame(height: 2 * chrome).allowsHitTesting(false) }
            if editing?.wrappedValue == .wallpaper {
                Rectangle().strokeBorder(Color.white, lineWidth: 4 * chrome).allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .coordinateSpace(name: "lockCanvas")
        .background(GeometryReader { g in Color.clear.onAppear { canvas = g.size }.onChange(of: g.size) { _, s in canvas = s } })
        .contextMenu {
            if !isEditing {
                Button("Customize Lock Screen…") { dismiss(); CustomizeWindow.show() }
                Menu("Switch Lock Screen") {
                    ForEach(store.faces) { f in
                        Button(f.id == store.activeId ? "✓ \(f.name)" : f.name) { store.activeId = f.id }
                    }
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: busy)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: mediaMode)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: face)
    }

    private var content: some View {
        VStack(spacing: 0) {
            top
            if isMain {
                if systemClockInset != nil, face.widgetsPlacement == .belowClock {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in widgetRow(ctx.date) }
                        .frame(maxWidth: .infinity, alignment: face.alignment.frame)
                }
                // The middle column takes all the height that's left, so a long list scrolls instead of running off screen.
                middle
                    .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
                    .modifier(EditableRegion(target: .content, editing: editing, chrome: chrome))
                    .frame(maxWidth: .infinity, alignment: face.alignment.frame)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                if face.widgetsPlacement == .bottom {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in widgetRow(ctx.date) }
                        .modifier(EditableRegion(target: .widgets, editing: editing, chrome: chrome))
                        .padding(.bottom, 20)
                }
                if systemClockInset == nil { footer.padding(.bottom, 34) }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, face.alignment == .leading ? 90 : 24)
        .padding(.top, systemClockInset ?? (isMain ? 48 : 120))
        .offset(y: -lift)
        .scaleEffect(1 - min(0.08, lift / 4000), anchor: .top)
        .opacity(1 - Double(min(lift, 520)) / 600)
    }

    // MARK: Top: inline widget, clock, widgets

    @ViewBuilder private var top: some View {
        if systemClockInset == nil { clockArea }
    }

    private var clockArea: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: face.alignment.horizontal, spacing: 4) {
                Group {
                    if face.inline == .none {
                        if isEditing { Text("Add Widget").font(.system(size: 20, weight: .semibold)).opacity(0.5) }
                    } else {
                        InlineWidgetView(kind: face.inline, date: ctx.date)
                        .modifier(OpensApp { AppLink.open(face.inline) })
                    }
                }
                .foregroundStyle(face.colorHex == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(face.clockColor.opacity(0.85)))
                .modifier(EditableRegion(target: .inline, editing: editing, chrome: chrome))

                Text(clock(ctx.date))
                    .font(face.font.font(size: (busy ? 108 : 150) * face.clockScale, weight: face.fontWeight))
                    .foregroundStyle(face.clockColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .modifier(EditableRegion(target: .clock, editing: editing, chrome: chrome))

                if isMain && face.widgetsPlacement == .belowClock {
                    widgetRow(ctx.date)
                        .modifier(EditableRegion(target: .widgets, editing: editing, chrome: chrome))
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: face.alignment.frame)
        }
    }

    @ViewBuilder private func widgetRow(_ date: Date) -> some View {
        if face.rowWidgets.isEmpty {
            if isEditing {
                Text("Add Widgets").font(.system(size: 15, weight: .semibold)).opacity(0.6)
                    .frame(width: LockWidget.unit * 4 + LockWidget.gap * 3, height: LockWidget.unit)
                    .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            HStack(spacing: LockWidget.gap) {
                ForEach(face.rowWidgets) { item in
                    LockWidget(item: item, date: date, tint: tint)
                        .modifier(OpensApp { AppLink.open(item.kind) })
                        .modifier(RowWidgetEditing(item: item, chrome: chrome, canvas: canvas))
                }
            }
        }
    }

    /// Widgets placed anywhere on the screen, positioned by their center as a fraction of the screen.
    @ViewBuilder private var freeWidgetLayer: some View {
        if isMain, !face.freeWidgets.isEmpty, canvas.width > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ZStack {
                    ForEach(face.freeWidgets) { item in
                        FreeWidget(item: item, date: ctx.date, tint: tint, canvas: canvas, chrome: chrome)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
            }
        }
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = prefs.use24h ? "HH:mm" : "h:mm"
        return f.string(from: d)
    }

    // MARK: Middle: the sections, in the order this face sets

    private var middle: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(face.sections.filter(\.enabled)) { s in section(s.section) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func section(_ s: LockSection) -> some View {
        switch s {
        case .nowPlaying:
            if music.hasTrack { NowPlayingCard(autoExpanded: mediaMode, interactive: !GL.isSaver && !isEditing) }
            else if isEditing { placeholder(s, "Appears while Music or Spotify is playing") }
        case .activities:
            if acts.items.isEmpty { if isEditing { placeholder(s, "Appears while a timer or stopwatch runs") } }
            else { ForEach(acts.items) { ActivityCard(activity: $0) } }
        case .claude:
            if showClaude { ClaudeCard() }
            else if isEditing { placeholder(s, "Appears after you use Claude Code today") }
        case .notifications:
            NotificationsSection(style: face.notificationStyle, collapsedByMedia: mediaMode)
        }
    }

    private func placeholder(_ s: LockSection, _ note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.symbol).font(.system(size: 20)).frame(width: 36, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 14, weight: .semibold))
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .glassCard(padding: 12)
        .opacity(0.7)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if face.showProfile {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                    } else {
                        Text(initials).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                if !prefs.displayName.isEmpty {
                    Text(prefs.displayName).font(.system(size: 14, weight: .semibold))
                }
            }
            Button(action: dismiss) {
                Text(GL.isSaver ? "Press any key to unlock" : "Click, swipe up or press Return to go back")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isEditing)
        }
    }

    private var initials: String {
        prefs.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

// MARK: - Editing chrome

struct EditableRegion: ViewModifier {
    let target: EditTarget
    let editing: Binding<EditTarget?>?
    let chrome: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if let editing {
            let selected = editing.wrappedValue == target
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.45),
                                      style: StrokeStyle(lineWidth: (selected ? 3 : 1.5) * chrome, dash: selected ? [] : [8 * chrome, 6 * chrome]))
                        .padding(-8)
                )
                .overlay(
                    Color.white.opacity(0.001).padding(-8).contentShape(Rectangle())
                        .onTapGesture { editing.wrappedValue = target }
                )
        } else {
            content
        }
    }
}

// MARK: - Wallpaper

struct WallpaperView: View {
    let wallpaper: Wallpaper
    let preview: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch wallpaper.kind {
                case .desktop:
                    if preview {
                        if let img = DesktopPicture.image() {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).blur(radius: wallpaper.blur)
                        } else {
                            LinearGradient(colors: [Color(hex: "#30466E"), Color(hex: "#5A3F7E")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    } else {
                        Color.clear
                    }
                case .color:
                    Color(hex: wallpaper.color1)
                case .gradient:
                    LinearGradient(colors: [Color(hex: wallpaper.color1), Color(hex: wallpaper.color2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                case .photo:
                    if let path = wallpaper.photoPath, let img = ImageCache.image(path) {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: wallpaper.blur)
                    } else {
                        Color.black
                    }
                }
                Color.black.opacity(wallpaper.dim)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

enum ImageCache {
    private static var images: [String: NSImage] = [:]
    static func purge() { images.removeAll(); DesktopPicture.purge() }
    static func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        images[path] = i
        return i
    }
}

// MARK: - Card chrome

extension View {
    func glassCard(radius: CGFloat = 22, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct RoundIconButton: View {
    let symbol: String
    var tint: Color = .primary
    var size: CGFloat = 34
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint == .primary ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint.opacity(0.22)), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now Playing

private struct NowPlayingCard: View {
    let autoExpanded: Bool
    var interactive = false
    @ObservedObject private var music = NowPlaying.shared
    @State private var scrub: Double?
    @State private var opened: Bool?     // the viewer's own choice; nil follows whether music is playing

    private var expanded: Bool { opened ?? autoExpanded }

    var body: some View {
        VStack(spacing: 12) {
            if expanded {
                art.frame(width: 200, height: 200).shadow(color: .black.opacity(0.25), radius: 18, y: 8).padding(.top, 4)
            }
            HStack(spacing: 12) {
                if !expanded { art.frame(width: 46, height: 46) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(music.artist) — \(music.album)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !expanded {
                    Button { music.playPause() } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { music.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 16))
                            .frame(width: 28, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else if interactive {
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { opened = false } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain).help("Smaller")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard interactive, !expanded else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { opened = true }
            }
            if expanded {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let pos = scrub ?? music.currentPosition(at: ctx.date)
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { pos }, set: { scrub = $0 }), in: 0...max(1, music.duration)) { editing in
                            if !editing, let s = scrub { music.seek(to: s); scrub = nil }
                        }
                        .controlSize(.small)
                        HStack {
                            Text(formatDuration(pos))
                            Spacer()
                            Text("-" + formatDuration(music.duration - pos))
                        }
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 34) {
                    Button { music.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 22)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32)).frame(width: 52, height: 52).contentShape(Rectangle()) }
                    Button { music.next() } label: { Image(systemName: "forward.fill").font(.system(size: 22)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Button { music.setVolume(max(0, music.volume - 10)) } label: { Image(systemName: "speaker.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Quieter")
                    Slider(value: Binding(get: { music.volume }, set: { music.setVolume($0) }), in: 0...100).controlSize(.mini)
                    Button { music.setVolume(min(100, music.volume + 10)) } label: { Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Louder")
                }
                if interactive, let player = music.player {
                    Button { music.openPlayer() } label: {
                        Label("Open \(player.rawValue)", systemImage: "arrow.up.forward.app").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .glassCard(padding: expanded ? 18 : 12)
    }

    private var art: some View {
        Group {
            if let img = music.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 14 : 9, style: .continuous))
    }
}

// MARK: - Live Activities

private struct ActivityCard: View {
    let activity: Activity
    @ObservedObject private var acts = Activities.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 14) {
                if activity.kind == .timer {
                    let frac = activity.total > 0 ? activity.remaining(at: ctx.date) / activity.total : 0
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 5)
                        Circle().trim(from: 0, to: frac).stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: frac)
                    }
                    .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "stopwatch.fill").font(.system(size: 20)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.displayLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(formatDuration(activity.kind == .timer ? activity.remaining(at: ctx.date) : activity.elapsed(at: ctx.date)))
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: activity.kind == .timer))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                RoundIconButton(symbol: "xmark") { withAnimation { acts.cancel(activity.id) } }
                RoundIconButton(symbol: activity.paused ? "play.fill" : "pause.fill", tint: .orange) { acts.toggle(activity.id) }
            }
        }
        .glassCard()
    }

    private var subtitle: String {
        if activity.paused { return "Paused" }
        if activity.kind == .timer, let end = activity.end { return "Ends \(end.formatted(date: .omitted, time: .shortened))" }
        return "Running"
    }
}

private struct ClaudeCard: View {
    @ObservedObject private var claude = ClaudeUsage.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Clawd(working: claude.isWorking, size: 52)
                        .frame(width: 52, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(claude.isWorking ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text("Claude Code · \(claude.isWorking ? "Working" : "Idle")")
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(formatDuration(sessionLength(ctx.date)))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("\(claude.isWorking ? "Current" : "Last") session · \(claude.currentSession?.project ?? "")")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack(alignment: .top) {
                    stat("\(claude.sessions.count)", "Sessions today")
                    stat(formatHoursMinutes(claude.timeToday(at: ctx.date)), "Time today")
                    stat(compactNumber(claude.totalTokens), "Tokens · \(compactNumber(claude.outputTokens)) out")
                }
            }
        }
        .glassCard()
    }

    private func sessionLength(_ now: Date) -> TimeInterval {
        guard let s = claude.currentSession else { return 0 }
        return (claude.isWorking ? now : s.last).timeIntervalSince(s.start)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notification Center

private struct NotificationsSection: View {
    let style: String
    let collapsedByMedia: Bool
    @ObservedObject private var inbox = Inbox.shared
    @State private var showAll = false
    @State private var expandedGroups = Set<String>()
    @State private var confirmClear = false

    private var collapsed: Bool { (collapsedByMedia || style == "count") && !showAll }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Notification Center").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !inbox.all.isEmpty && !GL.isSaver {
                    Button(confirmClear ? "Clear" : "Clear All") {
                        if confirmClear { withAnimation { inbox.clear() }; confirmClear = false }
                        else { confirmClear = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmClear = false } }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(confirmClear ? Color.white : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(confirmClear ? AnyShapeStyle(Color.red) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                }
            }
            .padding(.horizontal, 4)

            if inbox.all.isEmpty {
                Text("No Older Notifications").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary).padding(.vertical, 14)
            } else if collapsed {
                Button { withAnimation { showAll = true } } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: -8) {
                            ForEach(Array(groups.prefix(3)), id: \.0) { g in AppIcon(item: g.1[0], size: 26) }
                        }
                        Text("\(inbox.all.count) Notification\(inbox.all.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if GL.isSaver {
                // The lock screen can't scroll, so it shows one compact stack per app and sums up the rest.
                let shown = groups.prefix(3)
                ForEach(Array(shown), id: \.0) { _, items in
                    NotificationCard(item: items[0], moreCount: items.count - 1, compact: true)
                }
                if groups.count > shown.count {
                    let rest = groups.dropFirst(shown.count)
                    HStack(spacing: 10) {
                        HStack(spacing: -8) { ForEach(Array(rest.prefix(4)), id: \.0) { AppIcon(item: $0.1[0], size: 24) } }
                        Text("\(rest.reduce(0) { $0 + $1.1.count }) more from \(rest.count) app\(rest.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                }
            } else if style == "list" || style == "count" {
                ForEach(inbox.all) { NotificationCard(item: $0) }
            } else {
                ForEach(groups, id: \.0) { source, items in
                    if items.count > 1 && !expandedGroups.contains(source) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.thinMaterial).frame(height: 30).padding(.horizontal, 22).offset(y: 14)
                            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial).frame(height: 30).padding(.horizontal, 11).offset(y: 7)
                            NotificationCard(item: items[0], moreCount: items.count - 1)
                                .onTapGesture { withAnimation(.spring) { _ = expandedGroups.insert(source) } }
                        }
                        .padding(.bottom, 14)
                    } else {
                        if items.count > 1 {
                            HStack {
                                Text(items[0].appName).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Button("Show Less") { withAnimation(.spring) { _ = expandedGroups.remove(source) } }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4).background(.ultraThinMaterial, in: Capsule())
                            }
                            .padding(.horizontal, 4)
                        }
                        ForEach(items) { NotificationCard(item: $0) }
                    }
                }
            }
        }
        .onChange(of: collapsedByMedia) { _, _ in showAll = false }
    }

    private var groups: [(String, [InboxItem])] {
        var order: [String] = []
        var map: [String: [InboxItem]] = [:]
        for item in inbox.all {
            if map[item.groupKey] == nil { order.append(item.groupKey) }
            map[item.groupKey, default: []].append(item)
        }
        return order.map { ($0, map[$0]!) }
    }
}

private struct AppIcon: View {
    let item: InboxItem
    var size: CGFloat = 36
    var body: some View {
        Group {
            if item.source == .claude {
                Clawd(working: false, size: size * 0.8).frame(width: size, height: size)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else if item.source == .system, let id = item.bundleId, let icon = SystemNotifications.icon(for: id) {
                Image(nsImage: icon).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(item.tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            }
        }
    }
}

private struct NotificationCard: View {
    let item: InboxItem
    var moreCount = 0
    var compact = false
    @State private var hovering = false
    @State private var swipe: CGFloat = 0
    @State private var fullText = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            AppIcon(item: item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    // On hover the time turns into a close button, inside the card so it's never cut off.
                    if hovering && !GL.isSaver && moreCount == 0 {
                        Button { withAnimation { Inbox.shared.remove(item.id) } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22).background(.regularMaterial, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).help("Clear").transition(.scale.combined(with: .opacity))
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(relative(item.date)).font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(item.body).font(.system(size: 13.5)).lineLimit(fullText ? nil : (compact ? 2 : 3))
                    .fixedSize(horizontal: false, vertical: fullText)
                if fullText && AppLink.canOpen(item) && !GL.isSaver {
                    Button { AppLink.open(item) } label: {
                        Label(item.source == .update ? "Install" : "Open \(item.appName)", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
                if moreCount > 0 {
                    Text("\(moreCount) more notification\(moreCount == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
        }
        .glassCard(radius: 20, padding: 12)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu { Button("Dismiss") { Inbox.shared.remove(item.id) } }
        // Like a phone: drag sideways to clear it; click to read the whole message.
        .offset(x: swipe)
        .opacity(1 - min(0.8, abs(swipe) / 300))
        .gesture(GL.isSaver || moreCount > 0 ? nil :
            DragGesture(minimumDistance: 10)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { swipe = v.translation.width } }
                .onEnded { v in
                    if abs(v.translation.width) > 130 || abs(v.predictedEndTranslation.width) > 320 {
                        withAnimation(.easeOut(duration: 0.2)) { swipe = v.translation.width > 0 ? 600 : -600 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.spring) { Inbox.shared.remove(item.id) } }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipe = 0 }
                    }
                })
        .onTapGesture { if moreCount == 0 { withAnimation(.spring(response: 0.3)) { fullText.toggle() } } }
    }

    private func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Editing widgets on the canvas

/// Shared state for the lock screen editor: which widget is selected, alignment guides, and how to change the face.
final class EditorState: ObservableObject {
    @Published var selectedWidget: UUID?
    @Published var guideV = false
    @Published var guideH = false
    var update: (((inout LockFace) -> Void)) -> Void = { _ in }
    var onSelectWidgets: () -> Void = {}

    func move(_ id: UUID, to point: CGPoint, canvas: CGSize) {
        // Snap to the vertical and horizontal center lines, otherwise to a fine grid.
        var x = point.x / canvas.width, y = point.y / canvas.height
        guideV = abs(x - 0.5) < 0.012; guideH = abs(y - 0.5) < 0.012
        if guideV { x = 0.5 } else { x = (x * 96).rounded() / 96 }
        if guideH { y = 0.5 } else { y = (y * 96).rounded() / 96 }
        x = min(0.97, max(0.03, x)); y = min(0.96, max(0.04, y))
        update { face in
            if let i = face.widgets.firstIndex(where: { $0.id == id }) { face.widgets[i].x = x; face.widgets[i].y = y }
        }
    }
    func endDrag() { guideV = false; guideH = false }

    func putInRow(_ id: UUID) {
        update { face in
            guard let i = face.widgets.firstIndex(where: { $0.id == id }) else { return }
            var w = face.widgets[i]
            guard face.usedSlots + w.size.slots <= 4 else { return }
            w.x = nil; w.y = nil
            face.widgets.remove(at: i); face.widgets.append(w)
        }
    }
    func setSize(_ id: UUID, _ size: WidgetSize) {
        update { face in
            guard let i = face.widgets.firstIndex(where: { $0.id == id }) else { return }
            let w = face.widgets[i]
            if !w.isFree, face.usedSlots - w.size.slots + size.slots > 4 { return }
            face.widgets[i].size = size
        }
    }
    func remove(_ id: UUID) {
        update { face in face.widgets.removeAll { $0.id == id } }
        if selectedWidget == id { selectedWidget = nil }
    }
}

private struct EditorKey: EnvironmentKey { static let defaultValue: EditorState? = nil }
extension EnvironmentValues {
    var editor: EditorState? { get { self[EditorKey.self] } set { self[EditorKey.self] = newValue } }
}

/// The right-click menu shared by widgets in the row and widgets placed anywhere.
private struct WidgetMenu: View {
    let item: WidgetItem
    let editor: EditorState
    var body: some View {
        Button("Small") { editor.setSize(item.id, .small) }.disabled(item.size == .small)
        Button("Wide") { editor.setSize(item.id, .wide) }.disabled(item.size == .wide)
        Divider()
        if item.isFree { Button("Put Back Under the Clock") { editor.putInRow(item.id) } }
        Button("Remove", role: .destructive) { editor.remove(item.id) }
    }
}

private struct FreeWidget: View {
    let item: WidgetItem
    let date: Date
    let tint: Color
    let canvas: CGSize
    let chrome: CGFloat
    @Environment(\.editor) private var editor
    @State private var dragStart: CGPoint?

    var body: some View {
        let center = CGPoint(x: (item.x ?? 0.5) * canvas.width, y: (item.y ?? 0.5) * canvas.height)
        let widget = LockWidget(item: item, date: date, tint: tint)
        if let editor {
            let selected = editor.selectedWidget == item.id
            widget
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.4), lineWidth: (selected ? 3 : 1.5) * chrome).padding(-4))
                .contentShape(Rectangle())
                .onTapGesture { editor.selectedWidget = item.id; editor.onSelectWidgets() }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("lockCanvas"))
                    .onChanged { v in
                        if dragStart == nil { dragStart = center; editor.selectedWidget = item.id; editor.onSelectWidgets() }
                        let s = dragStart ?? center
                        editor.move(item.id, to: CGPoint(x: s.x + v.translation.width, y: s.y + v.translation.height), canvas: canvas)
                    }
                    .onEnded { _ in dragStart = nil; editor.endDrag() })
                .contextMenu { WidgetMenu(item: item, editor: editor) }
                .position(center)
        } else {
            widget.modifier(OpensApp { AppLink.open(item.kind) }).position(center)
        }
    }
}

/// In the editor, widgets in the row can be selected, right-clicked, or dragged out to anywhere on the screen.
private struct RowWidgetEditing: ViewModifier {
    let item: WidgetItem
    let chrome: CGFloat
    let canvas: CGSize
    @Environment(\.editor) private var editor
    @State private var offset: CGSize = .zero

    @ViewBuilder func body(content: Content) -> some View {
        if let editor {
            let selected = editor.selectedWidget == item.id
            content
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 3 * chrome).padding(-4))
                .offset(offset)
                .zIndex(offset == .zero ? 0 : 1)
                .onTapGesture { editor.selectedWidget = item.id; editor.onSelectWidgets() }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("lockCanvas"))
                    .onChanged { v in offset = v.translation; editor.selectedWidget = item.id }
                    .onEnded { v in
                        // A real drag pulls it out of the row and drops it where you let go.
                        if hypot(v.translation.width, v.translation.height) > 40, canvas.width > 0 {
                            editor.move(item.id, to: v.location, canvas: canvas)
                            editor.endDrag()
                        }
                        withAnimation(.spring(response: 0.3)) { offset = .zero }
                    })
                .contextMenu { WidgetMenu(item: item, editor: editor) }
        } else {
            content
        }
    }
}

// MARK: - Background clicks and swipes

/// An AppKit view behind the cards that turns trackpad scrolling into a swipe, like the iPhone's swipe up to go home.
/// Scrolling over the notification list still scrolls the list; only the background closes the lock screen.
private struct BackgroundInput: NSViewRepresentable {
    let onTap: () -> Void
    let onSwipe: (CGFloat) -> Void
    let onSwipeEnd: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ v: InputView, context: Context) {
        v.onTap = onTap; v.onSwipe = onSwipe; v.onSwipeEnd = onSwipeEnd
    }

    final class InputView: NSView {
        var onTap: () -> Void = {}
        var onSwipe: (CGFloat) -> Void = { _ in }
        var onSwipeEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
        private var amount: CGFloat = 0
        private var lastTime = Date()
        private var velocity: CGFloat = 0
        private var downAt: NSPoint?
        private var ended = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Two-finger swipe on the trackpad
        override func scrollWheel(with e: NSEvent) {
            if e.phase == .began { amount = 0; velocity = 0; ended = false }
            // Momentum after lifting the fingers isn't part of the swipe.
            guard e.momentumPhase == [] else {
                if !ended { ended = true; onSwipeEnd(amount, velocity) }
                return
            }
            guard e.hasPreciseScrollingDeltas else { return }   // a mouse wheel isn't a swipe
            // How far the fingers moved up, whichever scroll direction the Mac is set to.
            let up = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            amount += up
            let dt = max(0.001, Date().timeIntervalSince(lastTime)); lastTime = Date()
            velocity = up / CGFloat(dt)
            onSwipe(rubberBand(amount))
            if e.phase == .ended || e.phase == .cancelled {
                ended = true
                onSwipeEnd(amount, e.phase == .cancelled ? 0 : velocity)
            }
        }

        // Click, or click-drag up
        override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; amount = 0; lastTime = Date(); velocity = 0 }
        override func mouseDragged(with e: NSEvent) {
            guard let start = downAt else { return }
            let up = e.locationInWindow.y - start.y
            let dt = max(0.001, Date().timeIntervalSince(lastTime)); lastTime = Date()
            velocity = (up - amount) / CGFloat(dt)
            amount = up
            onSwipe(rubberBand(amount))
        }
        override func mouseUp(with e: NSEvent) {
            defer { downAt = nil }
            if abs(amount) < 4 { onTap() } else { onSwipeEnd(amount, velocity) }
            amount = 0
        }

        /// Follows the fingers one-to-one at first, then resists, so it feels attached.
        private func rubberBand(_ x: CGFloat) -> CGFloat {
            guard x > 0 else { return x / 3 }
            return x < 240 ? x : 240 + (x - 240) * 0.45
        }
    }
}
