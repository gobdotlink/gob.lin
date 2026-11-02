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
                                           before: String?, expected: String?, observed: String?, inserted: String,
                                           ownedChangeCount: Int, currentChangeCount: Int) -> Bool {
        guard providerRead, targetPID == focusedPID, ownedChangeCount == currentChangeCount,
              let before, let expected, before != expected, let observed else { return false }
        return observed == expected || pastedRange(before: before, observed: observed, inserted: inserted) != nil
    }

    /// Where `inserted` sits in `observed` (UTF-16) when `observed` is `before` with one stretch replaced by it. Web
    /// editors with inline chips, such as T3 Code's quotes, report the caret in a different text space from their
    /// value, so the value predicted from the caret never arrives even though the paste landed.
    public static func pastedRange(before: String, observed: String, inserted: String) -> NSRange? {
        let old = before as NSString, new = observed as NSString, length = (inserted as NSString).length
        let removed = old.length - new.length + length
        guard length > 0, before != observed, removed >= 0, removed <= old.length else { return nil }
        let shortest = min(old.length, new.length)
        var prefix = 0
        while prefix < shortest, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        // The stretch starts where both values still agree and ends where they agree again.
        let first = max(0, old.length - removed - suffix), last = min(prefix, old.length - removed)
        guard first <= last else { return nil }
        for start in first...last where new.substring(with: NSRange(location: start, length: length)) == inserted {
            return NSRange(location: start, length: length)
        }
        return nil
    }

    /// Where `inserted` sits in a field an app moved the paste to, as T3 Code does with a paste made while its page has
    /// focus. Its previous text is unknown, so the paste must be the only copy of `inserted` there.
    public static func forwardedRange(of inserted: String, in observed: String) -> NSRange? {
        let value = observed as NSString
        let found = value.range(of: inserted, options: .literal)
        guard !inserted.isEmpty, found.location != NSNotFound else { return nil }
        let rest = NSRange(location: found.location + 1, length: value.length - found.location - 1)
        return value.range(of: inserted, options: .literal, range: rest).location == NSNotFound ? found : nil
    }

    /// Whether the app bundle at `url` is built on Electron. Some apps rename Electron's framework (the ChatGPT app,
    /// which includes Codex, ships it as "Codex Framework"), so its archive and its Info.plist marker count too.
    public static func isElectronApp(at url: URL) -> Bool {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let files = FileManager.default
        if files.fileExists(atPath: contents.appendingPathComponent("Frameworks/Electron Framework.framework").path)
            || files.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path) { return true }
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["ElectronAsarIntegrity"] != nil
    }
}
