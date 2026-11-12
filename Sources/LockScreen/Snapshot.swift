import AppKit

/// Everything the lock screen shows, written by the app every couple of seconds and read by the screen saver.
/// The screen saver runs inside Apple's sandboxed host, where it can't talk to Music, read Claude Code's logs
/// or use Location and Calendar, so the app does that work and hands over the result.
struct Snapshot: Codable {
    struct Track: Codable, Equatable {
        var player: String
        var title, artist, album: String
        var isPlaying: Bool
        var duration, position, volume: Double
        var polledAt: Date
        var artworkFile: String?
    }
    struct Weather: Codable {
        var temperature, high, low: Int?
        var code: Int
        var isDay: Bool
        var sunrise, sunset: Date?
        var place: String
    }
    struct Event: Codable { var id, title: String; var start, end: Date; var allDay: Bool; var color: String }
    struct Reminder: Codable { var id, title: String; var due: Date?; var color: String }
    struct Claude: Codable {
        var available, isWorking: Bool
        var sessions: [ClaudeUsage.Session]
        var currentSession: ClaudeUsage.Session?
        var input, output, cacheRead, cacheWrite, replies: Int
    }

    var faces: [LockFace]
    var activeFace: UUID
    var use24h: Bool
    var displayName: String
    var desktopPicture: String?
    var track: Track?
    var activities: [Activity]
    var inbox: [InboxItem]
    var battery: Int?
    var charging: Bool
    var weather: Weather
    var events: [Event]
    var reminders: [Reminder]
    var reminderCount: Int
    var claude: Claude

    /// The real home folder; inside the screen saver's sandbox NSHomeDirectory() points at its container.
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Glass Lock/Lock Screen")
    }
    static var file: URL { folder.appendingPathComponent("snapshot.json") }
}

// MARK: - App side

final class SnapshotWriter {
    static let shared = SnapshotWriter()
    private var timer: Timer?
    private var lastData: Data?
    private var artworkKey = ""

    func start() {
        try? FileManager.default.createDirectory(at: Snapshot.folder, withIntermediateDirectories: true)
        write()
        // Weather, calendar and Claude Code finish loading a few seconds after launch; save them for the lock screen.
        for delay in [10.0, 60.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.write() } }
        NotificationCenter.default.addObserver(forName: Live.changed, object: nil, queue: .main) { [weak self] _ in self?.schedule() }
    }

    /// The screen saver only needs fresh data while the Mac is locked; the rest of the time this does nothing.
    private func schedule() {
        if Live.locked, timer == nil {
            write()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.write() }
            timer?.tolerance = 0.5
        } else if !Live.locked {
            timer?.invalidate(); timer = nil
        }
    }

    func write() {
        startServicesForActiveFace()
        let music = NowPlaying.shared, w = WeatherService.shared, ev = EventsService.shared, c = ClaudeUsage.shared
        var track: Snapshot.Track?
        if music.hasTrack {
            track = .init(player: music.player?.rawValue ?? "Music", title: music.title, artist: music.artist, album: music.album, isPlaying: music.isPlaying,
                          duration: music.duration, position: music.position, volume: music.volume,
                          polledAt: music.polledAt, artworkFile: saveArtwork(music))
        }
        let snap = Snapshot(
            faces: FaceStore.shared.faces, activeFace: FaceStore.shared.activeId,
            use24h: Prefs.shared.use24h, displayName: Prefs.shared.displayName,
            desktopPicture: DesktopPicture.url()?.path,
            track: track, activities: Activities.shared.items, inbox: Inbox.shared.all,
            battery: Battery.shared.percent, charging: Battery.shared.charging,
            weather: .init(temperature: w.temperature, high: w.high, low: w.low, code: w.code, isDay: w.isDay,
                           sunrise: w.sunrise, sunset: w.sunset, place: w.place),
            events: ev.events.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay, color: $0.color.hexString) },
            reminders: ev.reminders.map { .init(id: $0.id, title: $0.title, due: $0.due, color: $0.color.hexString) },
            reminderCount: ev.reminderCount,
            claude: .init(available: c.available, isWorking: c.isWorking, sessions: c.sessions, currentSession: c.currentSession,
                          input: c.inputTokens, output: c.outputTokens, cacheRead: c.cacheReadTokens,
                          cacheWrite: c.cacheWriteTokens, replies: c.replies))
        guard let data = try? JSONEncoder().encode(snap), data != lastData else { return }
        lastData = data
        try? data.write(to: Snapshot.file, options: .atomic)
    }

    /// Widgets normally start their services when they appear; with no window open the app starts them here.
    private func startServicesForActiveFace() {
        let face = FaceStore.shared.active
        let kinds = Set(face.widgets.map(\.kind))
        if kinds.contains(.weather) || kinds.contains(.sunrise) || [.dateWeather, .sunrise].contains(face.inline) {
            WeatherService.shared.ensureStarted()
        }
        let events = kinds.contains(.calendar) || face.inline == .nextEvent
        if events || kinds.contains(.reminders) {
            EventsService.shared.ensureStarted(events: events, reminders: kinds.contains(.reminders))
        }
    }

    private func saveArtwork(_ music: NowPlaying) -> String? {
        guard let art = music.artwork else { return nil }
        let key = "\(music.title)|\(music.artist)|\(music.album)"
        let name = "artwork-\(abs(key.hashValue) % 1_000_000).png"
        if key != artworkKey {
            guard let tiff = art.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            if let old = try? FileManager.default.contentsOfDirectory(atPath: Snapshot.folder.path) {
                for f in old where f.hasPrefix("artwork-") { try? FileManager.default.removeItem(at: Snapshot.folder.appendingPathComponent(f)) }
            }
            try? png.write(to: Snapshot.folder.appendingPathComponent(name), options: .atomic)
            artworkKey = key
        }
        return name
    }
}

// MARK: - Screen saver side

enum SnapshotReader {
    private static var lastModified: Date?
    private static var artworkFile: String?

    /// Loads the latest snapshot into the shared models the lock screen views observe. Returns false when there is none.
    @discardableResult
    static func load() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Snapshot.file.path)
        let modified = attrs?[.modificationDate] as? Date
        if modified != nil, modified == lastModified { return true }
        guard let data = try? Data(contentsOf: Snapshot.file),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        lastModified = modified
        apply(s)
        return true
    }

    private static func apply(_ s: Snapshot) {
        let store = FaceStore.shared
        if store.faces != s.faces, !s.faces.isEmpty { store.faces = s.faces }
        if store.activeId != s.activeFace { store.activeId = s.activeFace }
        let prefs = Prefs.shared
        if prefs.use24h != s.use24h { prefs.use24h = s.use24h }
        if prefs.displayName != s.displayName { prefs.displayName = s.displayName }
        DesktopPicture.overridePath = s.desktopPicture

        let m = NowPlaying.shared
        if let t = s.track {
            m.player = NowPlaying.Player(rawValue: t.player) ?? .music
            m.title = t.title; m.artist = t.artist; m.album = t.album
            m.isPlaying = t.isPlaying; m.duration = t.duration; m.volume = t.volume
            m.position = t.position; m.polledAt = t.polledAt
            if t.artworkFile != artworkFile {
                artworkFile = t.artworkFile
                m.artwork = t.artworkFile.flatMap { NSImage(contentsOf: Snapshot.folder.appendingPathComponent($0)) }
            }
        } else if m.player != nil {
            m.player = nil; m.title = ""; m.isPlaying = false; m.artwork = nil; artworkFile = nil
        }

        if Activities.shared.items != s.activities { Activities.shared.items = s.activities }
        if Inbox.shared.items != s.inbox { Inbox.shared.items = s.inbox }
        Battery.shared.percent = s.battery
        Battery.shared.charging = s.charging

        let w = WeatherService.shared
        w.temperature = s.weather.temperature; w.high = s.weather.high; w.low = s.weather.low
        w.code = s.weather.code; w.isDay = s.weather.isDay
        w.sunrise = s.weather.sunrise; w.sunset = s.weather.sunset; w.place = s.weather.place

        let ev = EventsService.shared
        ev.events = s.events.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay, color: NSColor(hex: $0.color) ?? .systemRed) }
        ev.reminders = s.reminders.map { .init(id: $0.id, title: $0.title, due: $0.due, color: NSColor(hex: $0.color) ?? .systemOrange) }
        ev.reminderCount = s.reminderCount
        ev.calendarAccess = true
        ev.reminderAccess = true

        let c = ClaudeUsage.shared
        c.available = s.claude.available; c.isWorking = s.claude.isWorking
        c.sessions = s.claude.sessions; c.currentSession = s.claude.currentSession
        c.inputTokens = s.claude.input; c.outputTokens = s.claude.output
        c.cacheReadTokens = s.claude.cacheRead; c.cacheWriteTokens = s.claude.cacheWrite; c.replies = s.claude.replies
    }
}
