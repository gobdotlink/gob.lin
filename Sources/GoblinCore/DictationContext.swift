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
    /// gob.lin's own latest insertion, when it went to the app this field is in; see `following(_:in:)`.
    public private(set) var previousTake: PreviousTake?
    /// `textBefore` starts at the start of the field rather than at `beforeLimit`.
    private let textBeforeIsWhole: Bool

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
            textBefore = ""; selectedText = ""; textAfter = ""; textBeforeIsWhole = true
            return
        }
        // Whole characters only: a UTF-16 cut can split an emoji or accented letter.
        func slice(_ start: Int, _ end: Int) -> String {
            guard end > start else { return "" }
            return text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start)))
        }
        textBefore = slice(max(0, selection.location - Self.beforeLimit), selection.location)
        textBeforeIsWhole = (textBefore as NSString).length == selection.location
        selectedText = slice(selection.location, min(NSMaxRange(selection), selection.location + Self.selectionLimit))
        textAfter = slice(NSMaxRange(selection), min(text.length, NSMaxRange(selection) + Self.afterLimit))
    }

    /// The cursor follows unfinished text on its line, so the dictation carries on a sentence.
    public var continuesSentence: Bool {
        // A take whose full stop the tone removed looks unfinished, but it ended a sentence.
        guard !followsFinishedTake else { return false }
        // Any line break: Windows "\r\n", old Mac "\r" and paragraph separators as well as "\n".
        let line = textBefore.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        guard let last = line.last(where: { !$0.isWhitespace && !#""')]}”’»"#.contains($0) }) else { return false }
        // A list item ends without a full stop, but what follows the end of one isn't more of the item.
        let endOfLine = selectedText.isEmpty && textAfter.prefix { !$0.isNewline }.allSatisfy(\.isWhitespace)
        guard !endOfLine || line.range(of: #"^\s*(?:[-*•]|\d+[.)])[ \t]+\S"#, options: .regularExpression) == nil else { return false }
        return !".!?…".contains(last)
    }

    /// This context after `take`, when `take` went to `application`, the process this field is in.
    public func following(_ take: PreviousTake?, in application: Int32?) -> DictationContext {
        var context = self
        context.previousTake = take.flatMap { application != nil && $0.application == application ? $0 : nil }
        return context
    }

    /// The text before the cursor still ends with gob.lin's previous take, give or take spaces on its line, and that take
    /// was a finished sentence whose full stop the tone removed, so this dictation starts the next sentence. Anything typed
    /// after it, a line break, another field's text, a selection or more text after the cursor on its line leaves the
    /// dictation to fit that text instead.
    public var followsFinishedTake: Bool {
        guard let previousTake, previousTake.removedFullStop else { return false }
        func trimmed(_ text: String) -> Substring {
            var text = Substring(text)
            while let last = text.last, last.isWhitespace, !last.isNewline { text.removeLast() }
            return text
        }
        // With a selection, or text after the cursor on its line, the dictation goes into the middle of something:
        // it fits that text as it always has, and no full stop is typed in front of it.
        let restOfLine = textAfter.prefix { !$0.isNewline }
        guard selectedText.isEmpty, restOfLine.allSatisfy(\.isWhitespace) else { return false }
        let before = trimmed(textBefore), take = trimmed(previousTake.text)
        guard !before.isEmpty, !take.isEmpty else { return false }
        // Only the end of a take longer than `beforeLimit` is in view.
        return before.hasSuffix(take) || (!textBeforeIsWhole && take.hasSuffix(before))
    }

    /// Nothing follows that take, not even its trailing space, so its full stop can be typed back before this dictation
    /// without changing text already in the field. After a space, the dictation only starts with a capital.
    public var restoresFullStop: Bool {
        // A list's last item never had one.
        followsFinishedTake && textBefore.last?.isWhitespace == false && !ToneFormatter.endsInListItem(previousTake?.text ?? "")
    }

    /// Words that open a take carrying on the one before it. The recogniser ends nearly every take with a full stop,
    /// finished or not, so "check the logs" then "and the meetings too" is still one sentence said in two takes.
    static let joiningWords: Set<String> = ["and", "but", "or", "because", "which"]

    /// Whether `text`, about to be typed here, joins the sentence before it rather than starting one after gob.lin's
    /// previous take: that take looked finished, but `text` opens with a joining word.
    public func joinsPreviousTake(_ text: String) -> Bool {
        guard followsFinishedTake, let first = text.split(whereSeparator: \.isWhitespace).first else { return false }
        return Self.joiningWords.contains(first.lowercased().filter(\.isLetter))
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

/// What gob.lin last typed into a field, without any full stop restored before it.
public struct PreviousTake: Equatable, Sendable {
    /// The process it was typed into.
    public let application: Int32
    public let text: String
    /// Tone formatting removed its final full stop; see `ToneFormatter.formatted`.
    public let removedFullStop: Bool

    public init(application: Int32, text: String, removedFullStop: Bool) {
        self.application = application; self.text = text; self.removedFullStop = removedFullStop
    }
}
