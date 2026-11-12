import SwiftUI
import AppKit

// MARK: - Lock screen faces (like iPhone: several lock screens, each fully customized)

enum ClockFont: String, Codable, CaseIterable, Identifiable {
    case classic, rounded, serif, mono, rail, condensed, didot, futura
    var id: String { rawValue }
    var name: String {
        switch self {
        case .classic: "Classic"; case .rounded: "Rounded"; case .serif: "New York"; case .mono: "Mono"
        case .rail: "Rail"; case .condensed: "Condensed"; case .didot: "Didot"; case .futura: "Futura"
        }
    }
    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .classic: .system(size: size, weight: weight)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .serif: .system(size: size, weight: weight, design: .serif)
        case .mono: .system(size: size, weight: weight, design: .monospaced)
        case .rail: .system(size: size, weight: weight).width(.compressed)
        case .condensed: .custom("Avenir Next Condensed", size: size).weight(weight)
        case .didot: .custom("Didot", size: size).weight(weight)
        case .futura: .custom("Futura", size: size).weight(weight)
        }
    }
}

enum FaceAlignment: String, Codable, CaseIterable { case center, leading
    var horizontal: HorizontalAlignment { self == .center ? .center : .leading }
    var frame: Alignment { self == .center ? .center : .leading }
    var text: TextAlignment { self == .center ? .center : .leading }
}

enum WidgetsPlacement: String, Codable, CaseIterable { case belowClock, bottom }

enum InlineWidget: String, Codable, CaseIterable, Identifiable {
    case date, dateWeather, nextEvent, battery, sunrise, moon, claude, none
    var id: String { rawValue }
    var name: String {
        switch self {
        case .date: "Date"; case .dateWeather: "Date and Weather"; case .nextEvent: "Next Event"; case .battery: "Battery"
        case .sunrise: "Sunrise and Sunset"; case .moon: "Moon Phase"; case .claude: "Claude Code"; case .none: "Nothing"
        }
    }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case weather, calendar, reminders, battery, worldClock, sunrise, moon, claude
    var id: String { rawValue }
    var name: String {
        switch self {
        case .weather: "Weather"; case .calendar: "Calendar"; case .reminders: "Reminders"; case .battery: "Batteries"
        case .worldClock: "World Clock"; case .sunrise: "Sunrise"; case .moon: "Moon"; case .claude: "Claude Code"
        }
    }
    var symbol: String {
        switch self {
        case .weather: "cloud.sun.fill"; case .calendar: "calendar"; case .reminders: "checklist"; case .battery: "battery.75"
        case .worldClock: "globe"; case .sunrise: "sunrise.fill"; case .moon: "moonphase.waxing.gibbous"; case .claude: "terminal.fill"
        }
    }
}

enum WidgetSize: String, Codable { case small, wide
    var slots: Int { self == .small ? 1 : 2 }
}

struct WidgetItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize
    var timeZone: String? = nil   // World Clock
    /// Placed anywhere on the screen: the widget's center as a fraction of the screen (0...1).
    /// nil keeps it in the row under the clock.
    var x: Double? = nil
    var y: Double? = nil

    var isFree: Bool { x != nil && y != nil }
}

enum LockSection: String, Codable, CaseIterable, Identifiable {
    case nowPlaying, activities, claude, notifications
    var id: String { rawValue }
    var name: String {
        switch self { case .nowPlaying: "Now Playing"; case .activities: "Timers and Stopwatches"; case .claude: "Claude Code"; case .notifications: "Notifications" }
    }
    var symbol: String {
        switch self { case .nowPlaying: "play.circle.fill"; case .activities: "timer"; case .claude: "terminal.fill"; case .notifications: "bell.badge.fill" }
    }
}

struct SectionSetting: Codable, Identifiable, Equatable, Hashable {
    var section: LockSection
    var enabled = true
    var id: LockSection { section }
}

struct Wallpaper: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case desktop, color, gradient, photo
        var name: String { switch self { case .desktop: "Desktop"; case .color: "Color"; case .gradient: "Gradient"; case .photo: "Photo" } }
    }
    var kind: Kind = .desktop
    var color1 = "#1B2A4E"
    var color2 = "#7B3FA8"
    var photoPath: String? = nil
    var blur: Double = 0
    var dim: Double = 0.15
}

struct LockFace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Lock Screen"
    var font: ClockFont = .rounded
    var weight: Double = 0.62
    var colorHex: String? = nil      // nil = automatic (vibrant white)
    var tone: Double = 1
    var clockScale: Double = 1
    var alignment: FaceAlignment = .center
    var inline: InlineWidget = .date
    var widgets: [WidgetItem] = [WidgetItem(kind: .weather, size: .small), WidgetItem(kind: .battery, size: .small), WidgetItem(kind: .calendar, size: .wide)]
    var widgetsPlacement: WidgetsPlacement = .belowClock
    var sections: [SectionSetting] = LockSection.allCases.map { SectionSetting(section: $0) }
    var notificationStyle = "stack"
    var wallpaper = Wallpaper()
    var showProfile = true

    /// Only widgets in the row take up its four spaces; widgets placed anywhere don't count.
    var usedSlots: Int { widgets.filter { !$0.isFree }.reduce(0) { $0 + $1.size.slots } }
    var rowWidgets: [WidgetItem] { widgets.filter { !$0.isFree } }
    var freeWidgets: [WidgetItem] { widgets.filter(\.isFree) }
    func enabled(_ s: LockSection) -> Bool { sections.first { $0.section == s }?.enabled ?? false }

    static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
    var fontWeight: Font.Weight { Self.weights[min(8, max(0, Int((weight * 8).rounded())))] }

    var clockColor: Color {
        guard let hex = colorHex, let base = NSColor(hex: hex) else { return .primary }
        // Tone: 0 = pale, 1 = full color
        return Color(nsColor: NSColor.white.blended(withFraction: 0.25 + 0.75 * tone, of: base) ?? base)
    }

    init() {}

    // Decode tolerantly so lock screens survive app updates that add new options.
    enum CodingKeys: String, CodingKey {
        case id, name, font, weight, colorHex, tone, clockScale, alignment, inline, widgets, widgetsPlacement, sections, notificationStyle, wallpaper, showProfile
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LockFace()
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        font = (try? c.decode(ClockFont.self, forKey: .font)) ?? d.font
        weight = (try? c.decode(Double.self, forKey: .weight)) ?? d.weight
        colorHex = try? c.decode(String.self, forKey: .colorHex)
        tone = (try? c.decode(Double.self, forKey: .tone)) ?? d.tone
        clockScale = (try? c.decode(Double.self, forKey: .clockScale)) ?? d.clockScale
        alignment = (try? c.decode(FaceAlignment.self, forKey: .alignment)) ?? d.alignment
        inline = (try? c.decode(InlineWidget.self, forKey: .inline)) ?? d.inline
        widgets = (try? c.decode([WidgetItem].self, forKey: .widgets)) ?? d.widgets
        widgetsPlacement = (try? c.decode(WidgetsPlacement.self, forKey: .widgetsPlacement)) ?? d.widgetsPlacement
        var secs = (try? c.decode([SectionSetting].self, forKey: .sections)) ?? d.sections
        for s in LockSection.allCases where !secs.contains(where: { $0.section == s }) { secs.append(SectionSetting(section: s)) }
        sections = secs
        notificationStyle = (try? c.decode(String.self, forKey: .notificationStyle)) ?? d.notificationStyle
        wallpaper = (try? c.decode(Wallpaper.self, forKey: .wallpaper)) ?? d.wallpaper
        showProfile = (try? c.decode(Bool.self, forKey: .showProfile)) ?? d.showProfile
    }

    static var presets: [LockFace] {
        var glass = LockFace(); glass.name = "Glass"
        var night = LockFace()
        night.name = "Night"; night.font = .serif; night.weight = 0.4; night.colorHex = "#FFB4A2"; night.tone = 0.8
        night.inline = .dateWeather
        night.wallpaper = Wallpaper(kind: .gradient, color1: "#0F1B3D", color2: "#5B2A6E")
        night.widgets = [WidgetItem(kind: .moon, size: .small), WidgetItem(kind: .sunrise, size: .small), WidgetItem(kind: .claude, size: .wide)]
        return [glass, night]
    }
}

final class FaceStore: ObservableObject {
    static let shared = FaceStore()
    @Published var faces: [LockFace] { didSet { save() } }
    @Published var activeId: UUID { didSet { UserDefaults.standard.set(activeId.uuidString, forKey: "activeFace") } }

    init() {
        let saved = UserDefaults.standard.data(forKey: "faces").flatMap { try? JSONDecoder().decode([LockFace].self, from: $0) }
        let list = (saved?.isEmpty == false ? saved! : LockFace.presets)
        faces = list
        let stored = UserDefaults.standard.string(forKey: "activeFace").flatMap(UUID.init(uuidString:))
        activeId = list.contains { $0.id == stored } ? stored! : list[0].id
    }

    var active: LockFace { faces.first { $0.id == activeId } ?? faces[0] }

    func binding(_ id: UUID) -> Binding<LockFace> {
        Binding(get: { self.faces.first { $0.id == id } ?? self.faces[0] },
                set: { new in if let i = self.faces.firstIndex(where: { $0.id == id }) { self.faces[i] = new } })
    }

    @discardableResult func add() -> UUID {
        var f = LockFace(); f.name = "Lock Screen \(faces.count + 1)"
        faces.append(f); return f.id
    }
    @discardableResult func duplicate(_ id: UUID) -> UUID? {
        guard var f = faces.first(where: { $0.id == id }) else { return nil }
        f.id = UUID(); f.name += " Copy"
        faces.append(f); return f.id
    }
    func delete(_ id: UUID) {
        guard faces.count > 1 else { return }
        faces.removeAll { $0.id == id }
        if activeId == id { activeId = faces[0].id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(faces) { UserDefaults.standard.set(data, forKey: "faces") }
    }
}

// MARK: - Color helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Binding that edits a hex string through a SwiftUI ColorPicker.
func hexBinding(_ b: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(hex: b.wrappedValue) }, set: { b.wrappedValue = NSColor($0).hexString })
}
