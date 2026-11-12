import AppKit

/// Now Playing for Music and Spotify through AppleScript. macOS asks once for permission
/// ("Icicle wants to control Music"). Apps that aren't running are never launched.
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    enum Player: String { case music = "Music", spotify = "Spotify"
        var bundleId: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    @Published var player: Player?
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var volume: Double = 50
    @Published var artwork: NSImage?
    var position: Double = 0
    var polledAt = Date()

    var hasTrack: Bool { player != nil && !title.isEmpty }
    func currentPosition(at now: Date) -> Double {
        min(duration, position + (isPlaying ? now.timeIntervalSince(polledAt) : 0))
    }

    private var timer: Timer?
    private var artworkKey = ""
    var fastPolling = false { didSet { schedule() } }

    func start() {
        poll()
        // Music and Spotify announce every play, pause and track change, so there's nothing to poll in the background.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.poll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if id == Player.music.bundleId || id == Player.spotify.bundleId { self?.poll() }
        }
    }

    /// While the overlay is up, refresh every second so the seek bar and volume stay exact.
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard fastPolling else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func running(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleId).isEmpty
    }

    func poll() {
        // Prefer whichever app is actually playing.
        let candidates = [Player.spotify, .music].filter(running)
        var best: (Player, [String])?
        for p in candidates {
            guard let fields = fetch(p) else { continue }
            if fields[0] == "playing" { best = (p, fields); break }
            if best == nil { best = (p, fields) }
        }
        guard let (p, f) = best else { clear(); return }
        if !UserDefaults.standard.bool(forKey: "musicAllowed") { UserDefaults.standard.set(true, forKey: "musicAllowed") }
        player = p
        isPlaying = f[0] == "playing"
        title = f[1]; artist = f[2]; album = f[3]
        duration = Self.number(f[4]) / (p == .spotify ? 1000 : 1)
        position = Self.number(f[5]); polledAt = Date()
        volume = Self.number(f[6])
        let key = "\(p.rawValue)|\(title)|\(album)"
        if key != artworkKey { artworkKey = key; loadArtwork(p, url: f.count > 7 ? f[7] : "") }
    }

    private func clear() {
        if player != nil { player = nil; title = ""; isPlaying = false; artwork = nil; artworkKey = "" }
    }

    private func fetch(_ p: Player) -> [String]? {
        let extra = p == .spotify ? " & linefeed & (artwork url of t)" : ""
        let source = """
        with timeout of 2 seconds
          tell application "\(p.rawValue)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (sound volume)\(extra)
          end tell
        end timeout
        """
        guard let out = run(source)?.stringValue, out != "stopped" else { return nil }
        let fields = out.components(separatedBy: "\n")
        return fields.count >= 7 ? fields : nil
    }

    private func loadArtwork(_ p: Player, url: String) {
        artwork = nil
        if p == .spotify, let u = URL(string: url) {
            URLSession.shared.dataTask(with: u) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { self.artwork = img }
            }.resume()
        } else if p == .music {
            let src = "with timeout of 2 seconds\ntell application \"Music\" to get data of artwork 1 of current track\nend timeout"
            if let d = run(src)?.data, let img = NSImage(data: d) { artwork = img }
        }
    }

    // MARK: Controls

    func playPause() { send("playpause"); isPlaying.toggle(); position = currentPosition(at: Date()); polledAt = Date() }
    func next() { send("next track"); refreshSoon() }
    func previous() { send("previous track"); refreshSoon() }
    func seek(to seconds: Double) { send("set player position to \(Int(seconds))"); position = seconds; polledAt = Date() }
    func openPlayer() {
        guard let p = player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleId) else { return }
        LockController.shared.hide()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setVolume(_ v: Double) { volume = v; send("set sound volume to \(Int(v))") }

    private func send(_ command: String) {
        guard let p = player, running(p) else { return }
        _ = run("with timeout of 2 seconds\ntell application \"\(p.rawValue)\" to \(command)\nend timeout")
    }
    private func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() } }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
