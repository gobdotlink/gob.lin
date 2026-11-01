import AppKit
import Carbon

/// Any key or combination macOS delivers. A keyed shortcut matches its modifiers on either side;
/// a modifier-only shortcut can name exact physical keys through `sides`.
struct HotkeyShortcut: Hashable, Sendable {
    var keyCode: UInt16?
    /// Device-independent flags that must be held, and nothing more: ⌃ ⌥ ⇧ ⌘ fn.
    var modifiers: UInt64
    /// Device flags naming the exact modifier keys of a modifier-only shortcut. Zero accepts either side.
    var sides: UInt64 = 0
    var keyLabel: String

    struct ModifierKey: Sendable {
        let code: UInt16, flag: UInt64, side: UInt64, symbol: String, word: String, name: String
    }

    static let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
    static let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
    /// The device-dependent bits macOS adds for each physical modifier key.
    static let sideFlags: UInt64 = 0x207F
    static let modifierKeys: [ModifierKey] = [
        ModifierKey(code: 63, flag: fnFlag, side: 0, symbol: "fn", word: "", name: "Fn / Globe"),
        ModifierKey(code: 59, flag: CGEventFlags.maskControl.rawValue, side: 0x1, symbol: "⌃", word: "control", name: "Left Control"),
        ModifierKey(code: 62, flag: CGEventFlags.maskControl.rawValue, side: 0x2000, symbol: "⌃", word: "control", name: "Right Control"),
        ModifierKey(code: 58, flag: CGEventFlags.maskAlternate.rawValue, side: 0x20, symbol: "⌥", word: "option", name: "Left Option"),
        ModifierKey(code: 61, flag: CGEventFlags.maskAlternate.rawValue, side: 0x40, symbol: "⌥", word: "option", name: "Right Option"),
        ModifierKey(code: 56, flag: CGEventFlags.maskShift.rawValue, side: 0x2, symbol: "⇧", word: "shift", name: "Left Shift"),
        ModifierKey(code: 60, flag: CGEventFlags.maskShift.rawValue, side: 0x4, symbol: "⇧", word: "shift", name: "Right Shift"),
        ModifierKey(code: 55, flag: CGEventFlags.maskCommand.rawValue, side: 0x8, symbol: "⌘", word: "command", name: "Left Command"),
        ModifierKey(code: 54, flag: CGEventFlags.maskCommand.rawValue, side: 0x10, symbol: "⌘", word: "command", name: "Right Command"),
    ]
    /// macOS sets the Fn flag itself on these keys (F-keys, Insert/Help, Home, End, Page Up/Down, Forward Delete, arrows).
    // ponytail: so Fn+F5 reads as F5; track the physical Fn key if someone needs the two apart.
    static let fnFlagKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
                                          114, 115, 116, 117, 119, 121, 123, 124, 125, 126]
    static let keyNames: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "Forward Delete", 114: "Insert",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑", 76: "Enter", 71: "Clear",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
        84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
    ]

    static let fn = HotkeyShortcut(modifierKeys: [63])
    static let rightOption = HotkeyShortcut(modifierKeys: [61])
    static let optionSpace = HotkeyShortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, keyLabel: "Space")

    var isValid: Bool {
        guard !keyLabel.isEmpty, modifiers & ~Self.relevantFlags.rawValue == 0, sides & ~Self.sideFlags == 0 else { return false }
        if let keyCode { return sides == 0 && !Self.modifierKeys.contains { $0.code == keyCode } }
        guard modifiers != 0, sides != 0 else { return modifiers != 0 }
        // Every named side belongs to a held modifier, and every held modifier except fn names its side.
        let named = Self.modifierKeys.filter { sides & $0.side != 0 }.reduce(UInt64(0)) { $0 | $1.flag }
        return named | (modifiers & Self.fnFlag) == modifiers
    }

    /// Carbon's Secure Input fallback can register this; it has no Fn and no left/right.
    var worksUnderSecureInput: Bool { keyCode != nil && modifiers & Self.fnFlag == 0 }

    /// Each physical key, modifiers first, as a Mac keyboard prints it: ⌥ with "option", then ].
    var keys: [(symbol: String, word: String)] {
        var result: [(symbol: String, word: String)] = []
        for key in Self.modifierKeys where modifiers & key.flag != 0 {
            if keyCode == nil && sides != 0 && key.side != 0 {
                if sides & key.side != 0 { result.append((key.symbol, key.name.hasPrefix("Right") ? "right" : "left")) }
            } else if !result.contains(where: { $0.symbol == key.symbol }) {
                result.append((key.symbol, key.word))
            }
        }
        return keyCode == nil ? result : result + [(keyLabel, "")]
    }

    var label: String {
        let keys = keys
        if keyCode == nil { return keys.count == 1 ? keyLabel : keys.map(\.symbol).joined() }
        let held = keys.dropLast().map(\.symbol)
        return held.filter { $0 != "fn" }.joined() + (held.contains("fn") ? "fn " : "") + keyLabel
    }

    /// Spelled out for running text: "Option + ]", "Right Control".
    var title: String {
        if keyCode == nil { return keyLabel }
        return keys.map { $0.word.isEmpty ? $0.symbol : $0.word.capitalized }.joined(separator: " + ")
    }

    /// What the person should know about a deliberately chosen shortcut. Never a reason to refuse it.
    var caution: String? {
        guard let keyCode else { return nil }
        if keyCode == 53 { return "Esc is the talk key now, so cancel a take with the × on my overlay." }
        if modifiers & ~CGEventFlags.maskShift.rawValue == 0 && !Self.fnFlagKeys.contains(keyCode) {
            return "That key won't type while it's my talk key."
        }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { return "I'll catch \(label) before other apps see it." }
        if !worksUnderSecureInput { return "Fn combinations pause while another app has Secure Input on." }
        return nil
    }

    var carbonModifiers: UInt32 {
        let flags = CGEventFlags(rawValue: modifiers)
        return (flags.contains(.maskCommand) ? UInt32(cmdKey) : 0)
            | (flags.contains(.maskAlternate) ? UInt32(optionKey) : 0)
            | (flags.contains(.maskControl) ? UInt32(controlKey) : 0)
            | (flags.contains(.maskShift) ? UInt32(shiftKey) : 0)
    }

    static func normalized(_ flags: UInt64, keyCode: UInt16) -> UInt64 {
        let relevant = flags & relevantFlags.rawValue
        return fnFlagKeys.contains(keyCode) ? relevant & ~fnFlag : relevant
    }

    static func keyName(_ code: UInt16, characters: String?) -> String {
        if let name = keyNames[code] { return name }
        let text = characters?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Function-key glyphs live in the private-use range and print as boxes.
        if let scalar = text.unicodeScalars.first, scalar.value >= 0x21, !(0xF700...0xF8FF).contains(scalar.value) { return text.uppercased() }
        return "Key \(code)"
    }

    func matchesKey(_ code: UInt16, flags: UInt64) -> Bool {
        code == keyCode && Self.normalized(flags, keyCode: code) == modifiers
    }

    enum ModifierChange: Equatable { case press, release, chord }

    /// What a modifier-key event means for a modifier-only shortcut: the last of its keys going down presses it,
    /// any of them coming up releases it, and an extra modifier while held is a chord.
    func modifierChange(code: UInt16, flags: UInt64, held: Bool) -> ModifierChange? {
        let generic = flags & Self.relevantFlags.rawValue, device = flags & Self.sideFlags
        // Events without any side bits (some remappers) can only match by the shared flag.
        let sides = device == 0 ? 0 : sides
        let required = generic & modifiers == modifiers && device & sides == sides
        let extra = generic & ~modifiers != 0 || (sides != 0 && device & ~sides != 0)
        if held { return !required ? .release : extra ? .chord : nil }
        let ownKey = Self.modifierKeys.contains { $0.code == code && modifiers & $0.flag != 0 && (sides == 0 || $0.side == 0 || sides & $0.side != 0) }
        return required && !extra && ownKey ? .press : nil
    }
}

extension HotkeyShortcut: Codable {
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, sides, keyLabel, modifier }

    init(modifierKeys codes: Set<UInt16>) {
        let keys = Self.modifierKeys.filter { codes.contains($0.code) }
        self.init(keyCode: nil, modifiers: keys.reduce(0) { $0 | $1.flag }, sides: keys.reduce(0) { $0 | $1.side },
                  keyLabel: keys.map(\.name).joined(separator: " + "))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt64.self, forKey: .modifiers)
        keyLabel = try container.decode(String.self, forKey: .keyLabel)
        // Earlier builds named Right Option instead of storing its side.
        let legacy = try container.decodeIfPresent(String.self, forKey: .modifier)
        sides = try container.decodeIfPresent(UInt64.self, forKey: .sides) ?? (legacy == "rightOption" ? 0x40 : 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(sides, forKey: .sides)
        try container.encode(keyLabel, forKey: .keyLabel)
    }
}

/// Builds a shortcut from what the person presses while recording. A key finishes on its release;
/// modifiers alone finish once every one is up.
struct ShortcutCapture {
    private var held: Set<UInt16> = []
    private var peak: Set<UInt16> = []
    private(set) var pending: HotkeyShortcut?
    /// A finished modifier-only shortcut. Any later event clears it, so a firmware macro that taps a modifier
    /// just before its key records as the whole combination.
    private(set) var finished: HotkeyShortcut?

    /// What would be saved right now, for the recorder to show while keys are down.
    var preview: HotkeyShortcut? { pending ?? finished ?? (peak.isEmpty ? nil : HotkeyShortcut(modifierKeys: peak)) }

    mutating func modifierChanged(code: UInt16, flags: UInt64) {
        guard let key = HotkeyShortcut.modifierKeys.first(where: { $0.code == code }) else { return }
        finished = nil
        // Trust the side bit when the event carries any; otherwise fall back to the shared flag.
        let down = flags & key.flag != 0 && (key.side == 0 || flags & HotkeyShortcut.sideFlags == 0 || flags & key.side != 0)
        if down { held.insert(code); peak.insert(code) } else { held.remove(code) }
        guard held.isEmpty, pending == nil, !peak.isEmpty else { return }
        finished = HotkeyShortcut(modifierKeys: peak)
        peak = []
    }

    mutating func keyDown(code: UInt16, flags: UInt64, label: String, isRepeat: Bool) {
        guard !isRepeat else { return }
        finished = nil
        pending = HotkeyShortcut(keyCode: code, modifiers: HotkeyShortcut.normalized(flags, keyCode: code), keyLabel: label)
    }

    mutating func keyUp(code: UInt16) -> HotkeyShortcut? {
        pending?.keyCode == code ? pending : nil
    }
}
