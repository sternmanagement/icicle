import AppKit
import Carbon.HIToolbox

/// A named snapshot of where every app's windows were.
struct Workspace: Codable, Identifiable {
    struct Window: Codable {
        let bundleID: String
        let appName: String
        let title: String
        let frame: CGRect // Cocoa coordinates
    }

    var id = UUID()
    var name: String
    var windows: [Window]
    var created = Date()
}

final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    /// ⌃⌥1 … ⌃⌥9 restore the first nine workspaces.
    static let numberKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                 kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    @Published private(set) var workspaces: [Workspace] = [] {
        didSet { persist() }
    }

    private let defaultsKey = "workspaces"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = saved
        }
    }

    /// Records every visible standard window. Returns how many were saved.
    @discardableResult
    func saveCurrentLayout(named name: String) -> Int {
        let windows = Self.currentWindows().map { app, window, title in
            Workspace.Window(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "",
                             title: title, frame: window.cocoaFrame ?? .zero)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        workspaces.append(Workspace(name: trimmed.isEmpty ? "Workspace \(workspaces.count + 1)" : trimmed, windows: windows))
        return windows.count
    }

    func delete(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
    }

    /// Moves windows back into place, launching apps that aren't running and placing their windows once they open.
    func restore(_ workspace: Workspace) {
        guard AccessibilityAccess.isTrusted else {
            AccessibilityAccess.request()
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let missing = Set(workspace.windows.map(\.bundleID)).subtracting(running).filter { !$0.isEmpty }
        for bundleID in missing {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        place(workspace.windows)
        if !missing.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.place(workspace.windows.filter { missing.contains($0.bundleID) })
            }
        }
    }

    /// Matches saved windows to open ones by title first, then by order within each app.
    private func place(_ saved: [Workspace.Window]) {
        let open = Self.currentWindows()
        for (bundleID, entries) in Dictionary(grouping: saved, by: \.bundleID) {
            var candidates = open.filter { $0.app.bundleIdentifier == bundleID }
            var unmatched: [Workspace.Window] = []
            for entry in entries {
                if let index = candidates.firstIndex(where: { $0.title == entry.title }) {
                    candidates.remove(at: index).window.setFrame(entry.frame)
                } else {
                    unmatched.append(entry)
                }
            }
            for (entry, candidate) in zip(unmatched, candidates) {
                candidate.window.setFrame(entry.frame)
            }
        }
    }

    private static func currentWindows() -> [(app: NSRunningApplication, window: AXWindow, title: String)] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [(NSRunningApplication, AXWindow, String)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            for element in axApp.elements(kAXWindowsAttribute) {
                guard element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      (element.value(kAXMinimizedAttribute) as? Bool) != true else { continue }
                result.append((app, AXWindow(element: element), element.string(kAXTitleAttribute) ?? ""))
            }
        }
        return result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
