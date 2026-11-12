import Foundation
import CoreLocation
import EventKit
import Photos
import AppKit

// MARK: - Weather (Open-Meteo: free, no account; location from a city name or Location Services)

final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    @Published var temperature: Int?
    @Published var high: Int?
    @Published var low: Int?
    @Published var code = 0
    @Published var isDay = true
    @Published var sunrise: Date?
    @Published var sunset: Date?
    @Published var place = ""
    @Published var problem: String?

    private var started = false
    private var timer: Timer?
    private var location: CLLocationManager?

    var useCelsius: Bool { Locale.current.measurementSystem != .us }
    var symbol: String { Self.symbol(code, day: isDay) }
    var condition: String { Self.condition(code) }

    func ensureStarted() {
        guard !started, !GL.isSaver else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let city = Prefs.shared.weatherCity.trimmingCharacters(in: .whitespaces)
        if !city.isEmpty { geocode(city) } else { requestLocation() }
    }

    private func geocode(_ city: String) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        fetchJSON(c.url!) { obj in
            guard let r = (obj?["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
                self.problem = "Couldn't find “\(city)”. Check the spelling in Customize → Widgets."; return
            }
            self.place = r["name"] as? String ?? city
            self.forecast(lat: lat, lon: lon)
        }
    }

    private func requestLocation() {
        if location == nil { location = CLLocationManager(); location?.delegate = self }
        switch location!.authorizationStatus {
        case .notDetermined: location!.requestWhenInUseAuthorization()
        case .denied, .restricted: problem = "Allow Location for Icicle in System Settings, or type a city in Customize → Widgets."
        default: location!.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        place = ""
        CLGeocoder().reverseGeocodeLocation(l) { marks, _ in
            DispatchQueue.main.async { self.place = marks?.first?.locality ?? "" }
        }
        forecast(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        problem = "Location isn't available. Type a city in Customize → Widgets."
    }

    private func forecast(lat: Double, lon: Double) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "2"),
            .init(name: "temperature_unit", value: useCelsius ? "celsius" : "fahrenheit"),
        ]
        fetchJSON(c.url!) { obj in
            guard let cur = obj?["current"] as? [String: Any], let daily = obj?["daily"] as? [String: Any] else {
                self.problem = "Weather isn't available right now."; return
            }
            self.problem = nil
            self.temperature = (cur["temperature_2m"] as? Double).map { Int($0.rounded()) }
            self.code = cur["weather_code"] as? Int ?? 0
            self.isDay = (cur["is_day"] as? Int ?? 1) == 1
            self.high = ((daily["temperature_2m_max"] as? [Double])?.first).map { Int($0.rounded()) }
            self.low = ((daily["temperature_2m_min"] as? [Double])?.first).map { Int($0.rounded()) }
            let tz = TimeZone(identifier: obj?["timezone"] as? String ?? "") ?? .current
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; f.timeZone = tz
            let rises = (daily["sunrise"] as? [String] ?? []).compactMap(f.date(from:))
            let sets = (daily["sunset"] as? [String] ?? []).compactMap(f.date(from:))
            let now = Date()
            self.sunrise = rises.first { $0 > now } ?? rises.first
            self.sunset = sets.first { $0 > now } ?? sets.first
        }
    }

    private func fetchJSON(_ url: URL, _ done: @escaping ([String: Any]?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(obj) }
        }.resume()
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: "cloud.heavyrain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear"; case 1: "Mostly Clear"; case 2: "Partly Cloudy"; case 3: "Cloudy"; case 45, 48: "Foggy"
        case 51...57: "Drizzle"; case 61...67: "Rain"; case 71...77: "Snow"; case 80...82: "Showers"
        case 85, 86: "Snow Showers"; case 95...99: "Thunderstorms"; default: "Cloudy"
        }
    }
}

// MARK: - Calendar and Reminders

final class EventsService: ObservableObject {
    static let shared = EventsService()

    struct Event: Identifiable { let id: String; let title: String; let start: Date; let end: Date; let allDay: Bool; let color: NSColor }
    struct Reminder: Identifiable { let id: String; let title: String; let due: Date?; let color: NSColor }

    @Published var events: [Event] = []
    @Published var reminders: [Reminder] = []
    @Published var reminderCount = 0
    @Published var calendarAccess: Bool?
    @Published var reminderAccess: Bool?

    private let store = EKEventStore()
    private var timer: Timer?
    private var wantsEvents = false, wantsReminders = false

    func ensureStarted(events: Bool, reminders: Bool) {
        let newE = events && !wantsEvents, newR = reminders && !wantsReminders
        guard newE || newR, !GL.isSaver else { return }
        wantsEvents = wantsEvents || events; wantsReminders = wantsReminders || reminders
        if timer == nil {
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        }
        Task {
            if newE { let ok = (try? await store.requestFullAccessToEvents()) ?? false; await MainActor.run { calendarAccess = ok } }
            if newR { let ok = (try? await store.requestFullAccessToReminders()) ?? false; await MainActor.run { reminderAccess = ok } }
            await MainActor.run { refresh() }
        }
    }

    func refresh() {
        if calendarAccess == true {
            let now = Date(), end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
            events = store.events(matching: pred)
                .filter { $0.endDate > now && !$0.isAllDay || ($0.isAllDay && Calendar.current.isDateInToday($0.startDate)) }
                .sorted { ($0.isAllDay ? 1 : 0, $0.startDate) < ($1.isAllDay ? 1 : 0, $1.startDate) }
                .prefix(4)
                .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                             allDay: $0.isAllDay, color: $0.calendar?.color ?? .systemRed) }
        }
        if reminderAccess == true {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: pred) { list in
                let items = (list ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                DispatchQueue.main.async {
                    self.reminderCount = items.count
                    self.reminders = items.prefix(3).map {
                        Reminder(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder",
                                 due: $0.dueDateComponents?.date, color: $0.calendar?.color ?? .systemOrange)
                    }
                }
            }
        }
    }
}

// MARK: - Moon phase (computed locally)

enum Moon {
    /// 0 = new, 0.5 = full
    static func phase(_ date: Date = Date()) -> Double {
        let ref = Date(timeIntervalSince1970: 947_182_440)   // new moon, 2000-01-06 18:14 UTC
        let synodic = 29.530588853 * 86400
        let p = date.timeIntervalSince(ref).truncatingRemainder(dividingBy: synodic) / synodic
        return p < 0 ? p + 1 : p
    }
    static func info(_ date: Date = Date()) -> (name: String, symbol: String, illumination: Int) {
        let p = phase(date)
        let illum = Int(((1 - cos(2 * .pi * p)) / 2 * 100).rounded())
        let list: [(String, String)] = [("New Moon", "moonphase.new.moon"), ("Waxing Crescent", "moonphase.waxing.crescent"),
                                        ("First Quarter", "moonphase.first.quarter"), ("Waxing Gibbous", "moonphase.waxing.gibbous"),
                                        ("Full Moon", "moonphase.full.moon"), ("Waning Gibbous", "moonphase.waning.gibbous"),
                                        ("Last Quarter", "moonphase.last.quarter"), ("Waning Crescent", "moonphase.waning.crescent")]
        let i = Int((p * 8).rounded()) % 8
        return (list[i].0, list[i].1, illum)
    }
}

// MARK: - Desktop picture for previews

enum DesktopPicture {
    private static var cache: (URL, NSImage)?
    /// The screen saver can't ask the system for the desktop picture, so the app passes its path along.
    static var overridePath: String?
    static func purge() { cache = nil }
    static func url() -> URL? {
        if let p = overridePath { return URL(fileURLWithPath: p) }
        if !GL.isSaver, let chosen = WallpaperChoice.current() {
            switch chosen {
            case .file(let url): return url
            case .photo(let id): if let url = PhotoWallpaper.cachedURL(id) { return url }; PhotoWallpaper.export(id)
            }
        }
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }
    static func image() -> NSImage? {
        guard let url = url() else { return nil }
        if let c = cache, c.0 == url { return c.1 }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let img = NSImage(contentsOf: url) else { return nil }
        cache = (url, img)
        return img
    }
}

// MARK: - The wallpaper macOS is actually showing

/// Since macOS 14, a wallpaper picked from Photos isn't a file, and `desktopImageURL` reports Apple's default picture
/// instead. The real choice is in the wallpaper store, which this reads (never writes).
enum WallpaperChoice {
    case file(URL)
    case photo(String)

    static func current() -> WallpaperChoice? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var candidates: [[String: Any]] = []
        if let displays = root["Displays"] as? [String: Any] {
            if let id = mainDisplayUUID(), let d = displays[id] as? [String: Any] { candidates.append(d) }
            candidates += displays.values.compactMap { $0 as? [String: Any] }
        }
        if let all = root["AllSpacesAndDisplays"] as? [String: Any] { candidates.append(all) }
        for c in candidates {
            guard let choice = (((c["Desktop"] as? [String: Any])?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first,
                  let config = choice["Configuration"] as? Data,
                  let dict = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any] else { continue }
            if let rel = (dict["url"] as? [String: Any])?["relative"] as? String, let url = URL(string: rel), url.isFileURL {
                return .file(url)
            }
            if dict["type"] as? String == "asset", let id = dict["identifier"] as? String { return .photo(id) }
            return nil
        }
        return nil
    }

    private static func mainDisplayUUID() -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

/// Copies a Photos wallpaper to a file the lock screen can show. Asks for Photos access once.
enum PhotoWallpaper {
    private static var exporting = Set<String>()
    private static var folder: URL { Snapshot.folder }
    private static func file(_ id: String) -> URL { folder.appendingPathComponent("wallpaper-\(id.prefix(36)).jpg") }

    static func cachedURL(_ id: String) -> URL? {
        let f = file(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    static func export(_ id: String) {
        guard !exporting.contains(id) else { return }
        exporting.insert(id)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let ids = id.contains("/") ? [id] : [id, id + "/L0/001"]
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).firstObject else { return }
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            let px = (NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3024)
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: px, height: px), contentMode: .aspectFit, options: opts) { image, _ in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let old = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                    for f in old where f.hasPrefix("wallpaper-") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
                }
                try? jpg.write(to: file(id), options: .atomic)
                DispatchQueue.main.async { DesktopPicture.purge(); SnapshotWriter.shared.write() }
            }
        }
    }
}
