import Foundation

/// Where a dictation will be typed, read just before cleanup: the app, the window title, the text around the cursor and
/// the text near the field, such as the messages above a message box.
/// It is untrusted screen text. Cleanup uses it to spell names and fit the surrounding text, never as instructions.
public struct DictationContext: Equatable, Sendable {
    /// In UTF-16 units, as Accessibility reports ranges. A few hundred prompt tokens at most.
    public static let beforeLimit = 600, selectionLimit = 600, afterLimit = 200, titleLimit = 150
    /// In characters, the part nearest the field.
    public static let nearbyLimit = 1_500

    public let application: String?
    public let windowTitle: String?
    /// The end of the field's text before the cursor or selection.
    public let textBefore: String
    /// The selection the dictation replaces.
    public let selectedText: String
    /// The start of the field's text after the cursor or selection.
    public let textAfter: String
    /// Text outside the field that comes before it in reading order, nearest kept.
    public let nearbyText: String

    /// `selection` is the field's selected range in `fieldText`; without both, only the app and window are kept.
    public init(application: String?, windowTitle: String?, fieldText: String? = nil, selection: NSRange? = nil, nearbyText: String? = nil) {
        func trimmed(_ text: String?, limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return String(text.prefix(limit))
        }
        self.application = trimmed(application, limit: Self.titleLimit)
        self.windowTitle = trimmed(windowTitle, limit: Self.titleLimit)
        self.nearbyText = String((nearbyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(Self.nearbyLimit))
        let text = (fieldText ?? "") as NSString
        guard let selection, selection.location != NSNotFound, NSMaxRange(selection) <= text.length else {
            textBefore = ""; selectedText = ""; textAfter = ""
            return
        }
        // Whole characters only: a UTF-16 cut can split an emoji or accented letter.
        func slice(_ start: Int, _ end: Int) -> String {
            guard end > start else { return "" }
            return text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start)))
        }
        textBefore = slice(max(0, selection.location - Self.beforeLimit), selection.location)
        selectedText = slice(selection.location, min(NSMaxRange(selection), selection.location + Self.selectionLimit))
        textAfter = slice(NSMaxRange(selection), min(text.length, NSMaxRange(selection) + Self.afterLimit))
    }

    /// The cursor follows unfinished text on its line, so the dictation carries on a sentence.
    public var continuesSentence: Bool {
        // Any line break: Windows "\r\n", old Mac "\r" and paragraph separators as well as "\n".
        let line = textBefore.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        guard let last = line.last(where: { !$0.isWhitespace && !#""')]}”’»"#.contains($0) }) else { return false }
        return !".!?…".contains(last)
    }

    /// The payload's `screen_context` object. Empty parts are left out.
    var promptFields: [String: String] {
        var fields: [String: String] = [:]
        fields["app"] = application
        fields["window_title"] = windowTitle
        for (key, value) in [("text_before_cursor", textBefore), ("selected_text", selectedText), ("text_after_cursor", textAfter),
                             ("nearby_text", nearbyText)]
        where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields[key] = value }
        return fields
    }

    /// The text before `field` in reading order, nearest first kept: the messages above a message box, the email a reply
    /// answers. Walks outward through the field's ancestors and the children before it, never into the field itself or
    /// past it, within `nodeLimit` elements and `deadline`. `text` gives an element's own text, or nil to look inside it;
    /// `parent` returns nil at the window.
    public static func textBefore<Node>(_ field: Node, parent: (Node) -> Node?, children: (Node) -> [Node], text: (Node) -> String?,
                                         isSame: (Node, Node) -> Bool, nodeLimit: Int = 2_000,
                                         deadline: ContinuousClock.Instant) -> (text: String, visited: Int) {
        var pieces: [String] = [], length = 0, visited = 0
        var node = field
        walk: while length < nearbyLimit, let up = parent(node) {
            let siblings = children(up)
            guard let index = siblings.firstIndex(where: { isSame($0, node) }) else { break }
            // Popping takes the nearest earlier element first, and the last part of each one before its start.
            var stack = Array(siblings[..<index])
            while let next = stack.popLast() {
                guard visited < nodeLimit, ContinuousClock.now < deadline else { break walk }
                visited += 1
                guard let piece = text(next) else { stack += children(next); continue }
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pieces.append(trimmed)
                length += trimmed.count + 1
                if length >= nearbyLimit { break walk }
            }
            node = up
        }
        return (pieces.reversed().joined(separator: "\n"), visited)
    }
}
