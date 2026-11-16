import Foundation

/// ⌃⌥M, the Mark This shortcut, as a key event: Control and Option held, no Command or Shift, and the key that types
/// M in the current layout. Caps Lock, fn and the numeric-pad flag don't matter.
public enum MeetingMarkShortcut {
    // NSEvent.ModifierFlags raw values, kept here so the rule is testable without AppKit events.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    /// ANSI M, for a layout that can't be read.
    public static let ansiKeyCode: UInt16 = 46

    /// `mKeyCode` is the key that types M in the current layout; `characters` is the event's characters with no
    /// modifiers applied, which also catches M on a layout whose key code differs.
    public static func matches(keyCode: UInt16, charactersIgnoringModifiers characters: String?, modifierFlags: UInt,
                               mKeyCode: UInt16 = ansiKeyCode) -> Bool {
        let held = modifierFlags & (shift | control | option | command)
        guard held == control | option else { return false }
        return keyCode == mKeyCode || characters?.lowercased() == "m"
    }
}
