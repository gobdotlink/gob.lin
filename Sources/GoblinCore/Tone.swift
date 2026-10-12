import Foundation

public enum DictationTone: String, CaseIterable, Codable, Sendable, Identifiable {
    case formal, casual, veryCasual

    public static let preferenceKey = "dictationTone"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .formal: "Use sentence capitalization and complete sentence punctuation. Preserve names, acronyms, code, URLs, and preferred spellings."
        case .casual: "Use natural sentence capitalization and lighter punctuation. Omit the final period, but retain meaningful question marks and exclamation marks. Preserve names, acronyms, code, URLs, and preferred spellings."
        case .veryCasual: "Lowercase ordinary sentence starts and omit the final period. Preserve names, acronyms, code, URLs, and preferred spellings; retain question marks and exclamation marks."
        }
    }

    public var preview: String {
        ToneFormatter.format("Please send the update to Maya after we check Postgres.", tone: self, protectedTerms: ["Maya", "Postgres"])
    }
}

public enum ToneFormatter {
    public static func format(_ input: String, tone: DictationTone, protectedTerms: [String] = []) -> String {
        guard !input.isEmpty else { return input }
        var text = input
        var protected = protectedRanges(in: text, terms: protectedTerms)
        let regex = try! NSRegularExpression(pattern: #"(?:^\s*|[.!?]\s+)([\p{L}\p{M}][\p{L}\p{M}\p{N}'’]*)"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let nsrange = match.range(at: 1)
            guard !protected.contains(where: { NSIntersectionRange($0, nsrange).length > 0 }),
                  let range = Range(nsrange, in: text) else { continue }
            let word = String(text[range])
            let replacement: String
            switch tone {
            case .formal, .casual:
                replacement = capitalizingFirst(word)
            case .veryCasual:
                // Unknown capitalized words may be names; lower only ordinary sentence starts.
                replacement = sentenceWords.contains(word.lowercased()) ? word.lowercased() : word
            }
            text.replaceSubrange(range, with: replacement)
        }
        protected = protectedRanges(in: text, terms: protectedTerms)
        if tone != .formal {
            // Semicolons carry a formal cadence; code and URLs remain untouched.
            for index in text.indices.reversed() where text[index] == ";" {
                let range = NSRange(index...index, in: text)
                if !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { text.replaceSubrange(index...index, with: ",") }
            }
        }
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return text }
        let lastRange = NSRange(last...last, in: text)
        let protectedEnd = protected.contains { NSIntersectionRange($0, lastRange).length > 0 }
        if tone == .formal {
            if !protectedEnd, !".!?:;".contains(text[last]), text[last].isLetter || text[last].isNumber {
                text.insert(".", at: text.index(after: last))
            }
        } else if text[last] == ".", !protectedEnd {
            let before = last > text.startIndex ? text[text.index(before: last)] : nil
            if before != "." { text.remove(at: last) }
        }
        return text
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func protectedRanges(in text: String, terms: [String]) -> [NSRange] {
        // Keep fenced/inline code, URLs, emails, acronyms, camelCase, and supplied names verbatim.
        let pattern = #"```[\s\S]*?(?:```|$)|`[^`\n]*(?:`|$)|(?:https?://|www\.)[^\s]+|[\w.+-]+@[\w.-]+\.[\p{L}]{2,}|\b[\p{Lu}]{2,}[\p{L}\p{N}]*\b|\b[\p{Ll}]+[\p{Lu}][\p{L}\p{N}]*\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var ranges = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        for term in terms where !term.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let matcher = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])", options: .caseInsensitive)
            ranges += matcher.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        }
        return ranges
    }

    private static let sentenceWords = Set("""
    a an and are as at be because before but by can could do does for from go have hello hey hi how i if in is it just let lets let's look maybe my no now of oh on once one or our please so some sorry thank thanks that the their then there these they this those to today tomorrow try we well what when where which while who why will with would yes you your
    about after again all also always any anyone anything back both call check come did don't each even every everyone everything feel first get give good great happy here hope i'll i'm i've it's keep know last make more most much must need never new next not okay only other put read really right said same say see send should start still stop sure take tell think too use wait want was were work write
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
