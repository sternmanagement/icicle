import Foundation

/// macOS features that react to the same window drags as Icicle: Mission Control opens when a
/// window touches the top edge, and the system's own tiling previews halves and full screen.
enum SystemDragSettings {
    private struct Pref {
        let domain: String
        let key: String
    }

    private static let missionControl = Pref(domain: "com.apple.dock", key: "enterMissionControlByTopWindowDrag")
    private static let tiling = [
        Pref(domain: "com.apple.WindowManager", key: "EnableTilingByEdgeDrag"),
        Pref(domain: "com.apple.WindowManager", key: "EnableTopTilingByEdgeDrag"),
    ]

    /// Dragging a window to the top of the screen opens Mission Control.
    static var missionControlOnTopDrag: Bool { isOn(missionControl) }

    /// macOS tiles windows dragged to screen edges or the menu bar.
    static var systemTiling: Bool { tiling.contains(where: isOn) }

    static var icicleHandlesDrags: Bool { !missionControlOnTopDrag && !systemTiling }

    /// Turns the system features off (or back on) and restarts the processes that cache them.
    static func setIcicleHandlesDrags(_ enabled: Bool) {
        let systemValue = !enabled
        if missionControlOnTopDrag != systemValue {
            write(missionControl, systemValue)
            run("/usr/bin/killall", "Dock")
        }
        let changedTiling = tiling.filter { isOn($0) != systemValue }
        if !changedTiling.isEmpty {
            changedTiling.forEach { write($0, systemValue) }
            run("/usr/bin/killall", "WindowManager")
        }
    }

    /// A missing key means the macOS default, which is on for all of these.
    private static func isOn(_ pref: Pref) -> Bool {
        CFPreferencesAppSynchronize(pref.domain as CFString)
        return CFPreferencesCopyAppValue(pref.key as CFString, pref.domain as CFString) as? Bool ?? true
    }

    // `defaults` goes through cfprefsd, so the Dock and WindowManager see the change on relaunch.
    private static func write(_ pref: Pref, _ value: Bool) {
        run("/usr/bin/defaults", "write", pref.domain, pref.key, "-bool", value ? "true" : "false")
    }

    private static func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
