import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyName: String

    static let defaultToggleHidden = KeyCombo(
        keyCode: UInt32(kVK_ANSI_I),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        keyName: "I"
    )
    static let defaultSnapLeft = KeyCombo(
        keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(controlKey | optionKey), keyName: "←"
    )
    static let defaultSnapRight = KeyCombo(
        keyCode: UInt32(kVK_RightArrow), carbonModifiers: UInt32(controlKey | optionKey), keyName: "→"
    )
    static let defaultMaximize = KeyCombo(
        keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(controlKey | optionKey), keyName: "↩"
    )
    static let defaultClipboard = KeyCombo(
        keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey), keyName: "V"
    )
    static let defaultWindowSwitcher = KeyCombo(
        keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey), keyName: "⇥"
    )

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyName = keyName
    }

    /// Returns nil unless the event carries ⌘, ⌥ or ⌃ — a bare key would swallow normal typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }

        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }

        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = mods
        self.keyName = Self.name(for: Int(event.keyCode), event: event)
    }

    private static func name(for keyCode: Int, event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Global hotkeys via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var isPaused = false

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private let signature = OSType(0x4943_4C45) // "ICLE"

    func register(id: UInt32, combo: KeyCombo?, handler: @escaping () -> Void) {
        unregister(id: id)
        guard let combo else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        } else {
            NSLog("Icicle: failed to register hotkey \(combo.displayString) (status \(status))")
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isPaused else { return }
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
