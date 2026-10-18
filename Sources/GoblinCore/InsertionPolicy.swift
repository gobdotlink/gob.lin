import Foundation

public enum InsertionPolicy {
    public static func text(_ transcript: String, trailingSpace: Bool) -> String {
        guard trailingSpace, let last = transcript.last, !last.isWhitespace else { return transcript }
        return transcript + " "
    }

    public static func expectedValue(before: String, selectedRange: NSRange, inserted: String,
                                     replacesEmptyLineBreak: Bool = false) -> String? {
        // Some contenteditable editors expose an empty paragraph's placeholder as a newline.
        if replacesEmptyLineBreak, before == "\n", selectedRange == NSRange(location: 0, length: 0) {
            return inserted
        }
        let text = before as NSString
        guard selectedRange.location != NSNotFound, selectedRange.location >= 0, selectedRange.length >= 0,
              selectedRange.location <= text.length, selectedRange.length <= text.length - selectedRange.location else { return nil }
        return text.replacingCharacters(in: selectedRange, with: inserted)
    }

    public static func mayRestoreClipboard(providerRead: Bool, targetPID: Int32, focusedPID: Int32,
                                           before: String?, expected: String?, observed: String?,
                                           ownedChangeCount: Int, currentChangeCount: Int) -> Bool {
        providerRead && targetPID == focusedPID && ownedChangeCount == currentChangeCount
            && before != nil && expected != nil && before != expected && observed == expected
    }
}
