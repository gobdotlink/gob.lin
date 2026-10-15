import Foundation

/// Word-level changes between what was said and what was typed, for the inline diff.
public enum TextDiff {
    public enum Change: Equatable, Sendable {
        case kept(String), removed(String), added(String)
    }

    /// Words and single punctuation marks. Whitespace is dropped and restored by `joined`.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-" {
                word.append(character)
                continue
            }
            if !word.isEmpty { tokens.append(word); word = "" }
            if !character.isWhitespace { tokens.append(String(character)) }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    /// Joins tokens with spaces, except before closing punctuation.
    public static func joined(_ tokens: [String]) -> String {
        var text = ""
        for token in tokens {
            if !text.isEmpty, !(token.count == 1 && ".,!?;:)…".contains(token)) { text += " " }
            text += token
        }
        return text
    }

    /// Runs of kept, removed and added text, in reading order.
    public static func changes(from old: String, to new: String) -> [Change] {
        let a = tokens(old), b = tokens(new)
        // ponytail: O(n·m) LCS table, fine for dictation-sized text; past a million cells it shows a plain replacement.
        guard a.count * b.count <= 1_000_000 else {
            return [a.isEmpty ? nil : .removed(joined(a)), b.isEmpty ? nil : .added(joined(b))].compactMap { $0 }
        }
        var table = Array(repeating: Array(repeating: Int32(0), count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var steps: [(kind: Int, token: String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { steps.append((0, a[i])); i += 1; j += 1 }
            else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] { steps.append((2, b[j])); j += 1 }
            else { steps.append((1, a[i])); i += 1 }
        }
        // Removals before additions inside a changed stretch, so "i" → "I" reads as a swap.
        var changes: [Change] = []
        var index = 0
        while index < steps.count {
            if steps[index].kind == 0 {
                var run: [String] = []
                while index < steps.count, steps[index].kind == 0 { run.append(steps[index].token); index += 1 }
                changes.append(.kept(joined(run)))
            } else {
                var removed: [String] = [], added: [String] = []
                while index < steps.count, steps[index].kind != 0 {
                    if steps[index].kind == 1 { removed.append(steps[index].token) } else { added.append(steps[index].token) }
                    index += 1
                }
                if !removed.isEmpty { changes.append(.removed(joined(removed))) }
                if !added.isEmpty { changes.append(.added(joined(added))) }
            }
        }
        return changes
    }
}
