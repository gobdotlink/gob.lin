import AppKit
import Carbon

struct HotkeyShortcut: Codable, Equatable, Sendable {
    enum Modifier: String, Codable, Sendable { case fn, rightOption, option, command, control, shift }
    var keyCode: UInt16?
    var modifiers: UInt64
    var modifier: Modifier?
    var keyLabel: String

    static let fn = HotkeyShortcut(keyCode: nil, modifiers: CGEventFlags.maskSecondaryFn.rawValue, modifier: .fn, keyLabel: "Fn / Globe")
    static let rightOption = HotkeyShortcut(keyCode: nil, modifiers: CGEventFlags.maskAlternate.rawValue, modifier: .rightOption, keyLabel: "Right Option")
    static let optionSpace = HotkeyShortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, modifier: nil, keyLabel: "Space")
    static let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    var isValid: Bool {
        guard !keyLabel.isEmpty, modifiers & ~Self.relevantFlags.rawValue == 0 else { return false }
        if let keyCode { return keyCode < 128 && keyCode != 53 && modifier == nil && modifiers != 0 && modifiers & CGEventFlags.maskSecondaryFn.rawValue == 0 }
        switch modifier {
        case .fn: return modifiers == CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption, .option: return modifiers == CGEventFlags.maskAlternate.rawValue
        case .command: return modifiers == CGEventFlags.maskCommand.rawValue
        case .control: return modifiers == CGEventFlags.maskControl.rawValue
        case .shift: return modifiers == CGEventFlags.maskShift.rawValue
        case nil: return false
        }
    }

    var label: String {
        guard keyCode != nil else { return keyLabel }
        let flags = CGEventFlags(rawValue: modifiers)
        return (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "")
            + (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "") + keyLabel
    }

    var carbonModifiers: UInt32 {
        let flags = CGEventFlags(rawValue: modifiers)
        return (flags.contains(.maskCommand) ? UInt32(cmdKey) : 0)
            | (flags.contains(.maskAlternate) ? UInt32(optionKey) : 0)
            | (flags.contains(.maskControl) ? UInt32(controlKey) : 0)
            | (flags.contains(.maskShift) ? UInt32(shiftKey) : 0)
    }

    func matches(flags: CGEventFlags) -> Bool {
        flags.intersection(Self.relevantFlags).rawValue == modifiers
    }

    func modifierIsDown(flags: CGEventFlags) -> Bool {
        guard matches(flags: flags) else { return false }
        // The device-specific RAlt bit distinguishes right release while left Option stays down.
        if modifier == .rightOption { return flags.rawValue & 0x40 != 0 }
        return true
    }

    func primaryModifierIsDown(flags: CGEventFlags) -> Bool {
        if modifier == .rightOption { return flags.rawValue & 0x40 != 0 }
        return flags.rawValue & modifiers != 0
    }

    func isPrimaryModifierKey(_ code: UInt16) -> Bool {
        switch modifier {
        case .fn: code == 63
        case .rightOption: code == 61
        case .option: code == 58 || code == 61
        case .command: code == 54 || code == 55
        case .control: code == 59 || code == 62
        case .shift: code == 56 || code == 60
        case nil: false
        }
    }
}
