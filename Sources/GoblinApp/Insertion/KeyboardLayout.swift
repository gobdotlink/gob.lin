import AppKit
@preconcurrency import Carbon

enum KeyboardLayout {
    /// Resolve the key that produces V with Command held, including Dvorak-QWERTY Command layouts.
    static func pasteKeyCode() -> CGKeyCode? { keyCode(producing: "v", modifiers: UInt32(cmdKey >> 8)) }

    /// The key that types `character` in the current layout with `modifiers` (Carbon modifier bits shifted right 8).
    static func keyCode(producing character: String, modifiers: UInt32 = 0) -> CGKeyCode? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) > 0 else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code: UInt16 in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
                                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                        characters.count, &length, &characters)
            if result == noErr, length > 0,
               String(utf16CodeUnits: characters, count: length).lowercased() == character { return code }
        }
        return nil
    }
}
