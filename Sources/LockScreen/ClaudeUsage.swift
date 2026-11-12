import Foundation

/// Reads Claude Code's local session logs (~/.claude/projects/*/*.jsonl) and totals today's activity.
/// Files are read incrementally: each pass only parses lines appended since the last one.
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    struct Session: Identifiable, Equatable, Codable {
        let id: String
        var start: Date
        var last: Date
        var project: String
    }

    @Published var available = false
    @Published var sessions: [Session] = []
    @Published var currentSession: Session?
    @Published var isWorking = false
    @Published var inputTokens = 0
    @Published var outputTokens = 0
    @Published var cacheReadTokens = 0
    @Published var cacheWriteTokens = 0
    @Published var replies = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    /// Time spent in sessions today; a session that is still working counts up to now.
    func timeToday(at now: Date) -> TimeInterval {
        sessions.reduce(0) { sum, s in
            let end = (isWorking && s.id == currentSession?.id) ? now : s.last
            return sum + max(0, end.timeIntervalSince(s.start))
        }
    }

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let queue = DispatchQueue(label: "glasslock.claude-usage", qos: .utility)
    private var timer: Timer?
    private var lastQuietNotice = Date.distantPast

    // Owned by `queue`
    private var day = Calendar.current.startOfDay(for: Date())
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var byId: [String: Session] = [:]
    private var totals = (input: 0, output: 0, read: 0, write: 0, replies: 0)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    func start() {
        refresh()
        schedule()
        NotificationCenter.default.addObserver(forName: Live.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(); self?.schedule()
        }
    }

    /// Every 10 seconds while the lock screen or a window shows it, otherwise once a minute (for the menu and notifications).
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Live.active ? 10 : 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = Live.active ? 2 : 15
    }

    func refresh() { queue.async { self.scan() } }

    private func scan() {
        let fm = FileManager.default
        let today = Calendar.current.startOfDay(for: Date())
        if today != day {
            day = today; offsets = [:]; seen = []; byId = [:]; totals = (0, 0, 0, 0, 0)
        }
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            DispatchQueue.main.async { self.available = false }
            return
        }
        var newest: (id: String, modified: Date)?
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys),
                      let modified = values.contentModificationDate, modified >= day else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                if newest == nil || modified > newest!.modified { newest = (sessionId, modified) }
                read(file, size: UInt64(values.fileSize ?? 0), fallbackId: sessionId)
            }
        }
        let working = newest.map { Date().timeIntervalSince($0.modified) < 90 } ?? false
        let current = newest.flatMap { byId[$0.id] }
        let list = byId.values.sorted { $0.start < $1.start }
        let t = totals
        DispatchQueue.main.async {
            let wasWorking = self.isWorking, previous = self.currentSession
            self.available = true
            self.sessions = list
            self.currentSession = current
            self.isWorking = working
            (self.inputTokens, self.outputTokens, self.cacheReadTokens, self.cacheWriteTokens, self.replies) = t
            // Only for real work sessions (10+ minutes), at most every 30 minutes, replacing the previous one.
            if wasWorking && !working, let s = previous ?? current, s.last.timeIntervalSince(s.start) >= 600,
               Date().timeIntervalSince(self.lastQuietNotice) > 1800 {
                self.lastQuietNotice = Date()
                Inbox.shared.remove(source: .claude)
                Inbox.shared.add(.claude, title: "Claude Code went quiet",
                                 body: "No activity in \(s.project) for 90 seconds. Session time: \(formatHoursMinutes(s.last.timeIntervalSince(s.start))).")
            }
        }
    }

    private func read(_ url: URL, size: UInt64, fallbackId: String) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }           // file was rewritten
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        // Read in 512 KB pieces so a long session's log never sits in memory all at once.
        var carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 512 * 1024), !chunk.isEmpty else { return false }
                carry.append(chunk)
                guard let lastNewline = carry.lastIndex(of: 0x0A) else { return true }
                let complete = carry[carry.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A) { parse(line, fallbackId: fallbackId) }
                offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: lastNewline)...])   // a half-written last line waits for next time
                return true
            }
            if !more { break }
        }
        offsets[url.path] = offset
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let stampMarker = Data("\"timestamp\":\"".utf8)

    private func parse(_ line: Data.SubSequence, fallbackId: String) {
        // Most lines carry no token usage; for those only the time and session matter, which a quick scan finds
        // without building the whole JSON object.
        if line.range(of: Self.usageMarker) == nil {
            guard let r = line.range(of: Self.stampMarker), let end = line[r.upperBound...].firstIndex(of: 0x22),
                  let stamp = String(data: line[r.upperBound..<end], encoding: .utf8),
                  let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp), date >= day else { return }
            if var s = byId[fallbackId] {
                s.start = min(s.start, date); s.last = max(s.last, date); byId[fallbackId] = s
                return
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp),
              date >= day else { return }
        let id = obj["sessionId"] as? String ?? fallbackId
        let project = (obj["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Claude Code"
        if var s = byId[id] {
            s.start = min(s.start, date); s.last = max(s.last, date)
            byId[id] = s
        } else {
            byId[id] = Session(id: id, start: date, last: date, project: project.isEmpty ? "~" : project)
        }
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let key = "\(message["id"] ?? "")|\(obj["requestId"] ?? "")"
        guard seen.insert(key).inserted else { return }
        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        totals.input += n("input_tokens")
        totals.output += n("output_tokens")
        totals.read += n("cache_read_input_tokens")
        totals.write += n("cache_creation_input_tokens")
        totals.replies += 1
    }
}
