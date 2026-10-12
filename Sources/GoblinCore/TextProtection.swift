import Foundation

/// Conservative spans shared by text transforms; this deliberately does not parse source languages.
enum DictationTextProtection {
    private static let code = try! NSRegularExpression(pattern: #"`{3,}[\s\S]*?(?:`{3,}|$)|(`{1,2})[\s\S]*?(?:\1|$)|~{3,}[\s\S]*?(?:~{3,}|$)"#)
    private static let identifier = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][.:-][\p{L}\p{N}]|\p{Ll}\p{Lu}"#)

    static func ranges(in text: String) -> [NSRange] {
        var ranges = code.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor].isWhitespace { cursor = text.index(after: cursor); continue }
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let range = start..<cursor
            let chunk = String(text[range])
            if chunk.contains(where: { "/\\@_`".contains($0) }) || identifier.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)) != nil {
                ranges.append(NSRange(range, in: text))
            }
        }
        return ranges
    }

    static func contains(_ range: Range<String.Index>, in text: String, ranges: [NSRange]) -> Bool {
        let range = NSRange(range, in: text)
        return ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
