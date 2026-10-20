import AppKit
import Foundation
import GoblinEngines

/// Benchmark-only filters for Parakeet's post-recognition CTC corrections.
/// A correction that only re-spaces a dictionary term ("post hog" -> "PostHog") is always kept; any other
/// replacement must pass the policy, otherwise the recognizer's original words are restored.
enum ParakeetCorrectionGuard {
    enum Policy: Equatable {
        case none
        /// Replace only spans containing a word the system spell checker does not know.
        case spelling
        /// Replace only spans whose least-confident recognized token is below the threshold.
        case confidence(Float)
        /// Either condition suffices.
        case spellingOrConfidence(Float)

        init(_ value: String) throws {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let threshold = parts.count == 2 ? Float(parts[1]) : nil
            switch (parts[0], threshold) {
            case ("none", nil): self = .none
            case ("spelling", nil): self = .spelling
            case ("confidence", let t?) where (0...1).contains(t): self = .confidence(t)
            case ("spelling-or-confidence", let t?) where (0...1).contains(t): self = .spellingOrConfidence(t)
            default: throw CommandError.usage("--guard must be none, spelling, confidence:<0...1> or spelling-or-confidence:<0...1>")
            }
        }

        var description: String {
            switch self {
            case .none: "none"
            case .spelling: "spelling"
            case .confidence(let t): "confidence:\(t)"
            case .spellingOrConfidence(let t): "spelling-or-confidence:\(t)"
            }
        }
    }

    struct Word {
        let surface: String
        let key: String
        /// Least-confident recognizer token in the word, when token timings were available.
        var confidence: Float?
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whitespace-separated words. Punctuation-only tokens ("—") have an empty key and are kept for reconstruction.
    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).map { Word(surface: String($0), key: key(String($0))) }
    }

    /// Joins two or three adjacent words whose letters and digits equal a term's, keeping outer punctuation.
    /// A single word is only recased, and only to a term without punctuation, so "C" never becomes "C++".
    static func textJoin(_ text: String, terms: [String]) -> String {
        let keys = Dictionary(terms.compactMap { term in key(term).isEmpty ? nil : (key(term), term) },
                              uniquingKeysWith: { first, _ in first })
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            var matched = false
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let span = Array(tokens[index..<(index + length)])
                guard let term = keys[key(span.joined())] else { continue }
                if length == 1 {
                    guard term.allSatisfy({ isWordCharacter($0) || $0 == " " }) else { continue }
                } else {
                    // Words joined into a term must touch only through letters or digits: "stop. Hog" is two sentences.
                    guard span.dropLast().allSatisfy({ $0.last.map(isWordCharacter) == true }),
                          span.dropFirst().allSatisfy({ $0.first.map(isWordCharacter) == true }) else { continue }
                }
                var leading = String(span[0].prefix { !isWordCharacter($0) })
                var trailing = String(span[length - 1].reversed().prefix { !isWordCharacter($0) }.reversed())
                // Punctuation that is part of the term ("C++", ".NET") is not repeated around it.
                let termLeading = String(term.prefix { !isWordCharacter($0) })
                let termTrailing = String(term.reversed().prefix { !isWordCharacter($0) }.reversed())
                if leading.hasSuffix(termLeading) { leading.removeLast(termLeading.count) }
                if trailing.hasPrefix(termTrailing) { trailing.removeFirst(termTrailing.count) }
                output.append(leading + term + trailing)
                index += length
                matched = true
                break
            }
            if !matched { output.append(tokens[index]); index += 1 }
        }
        return output.joined(separator: " ")
    }

    /// Recognized words with token confidences, aligned to the whitespace words of the transcript.
    static func recognizedWords(_ recognition: TranscriptionResult) -> [Word] {
        var spoken: [(key: String, confidence: Float)] = []
        var boundary = true
        for token in recognition.tokens {
            // A standalone boundary piece (" " or "▁") starts the next word even though it has no letters.
            if token.text.hasPrefix(" ") || token.text.hasPrefix("\u{2581}") { boundary = true }
            let piece = key(token.text)
            guard !piece.isEmpty else { continue }
            if boundary || spoken.isEmpty { spoken.append((piece, token.confidence)) }
            else { spoken[spoken.count - 1].key += piece; spoken[spoken.count - 1].confidence = min(spoken[spoken.count - 1].confidence, token.confidence) }
            boundary = false
        }
        var result = words(recognition.text)
        var cursor = 0
        for index in result.indices where !result[index].key.isEmpty {
            // Token words and transcript words normally match one-to-one; skip any that drift.
            if cursor < spoken.count, let match = spoken[cursor...].firstIndex(where: { $0.key == result[index].key }), match - cursor <= 2 {
                result[index].confidence = spoken[match].confidence
                cursor = match + 1
            }
        }
        return result
    }

    struct Outcome {
        let text: String
        let accepted: Int
        let rejected: Int
    }

    static func apply(_ policy: Policy, recognition: TranscriptionResult, corrected: String, terms: [String]) -> Outcome {
        guard policy != .none else { return Outcome(text: corrected, accepted: 0, rejected: 0) }
        let original = recognizedWords(recognition)
        let changed = words(corrected)
        let termKeys = Set(terms.map(key)).subtracting([""])
        var output: [String] = []
        var accepted = 0, rejected = 0
        for block in align(original.map(\.key), changed.map(\.key)) {
            if block.equal { output += changed[block.corrected].map(\.surface); continue }
            // Adjacent replacements are judged separately: an unknown "Kalican" must not license "lunch" -> "Luna".
            for (from, to) in replacements(Array(original[block.original]), Array(changed[block.corrected]), termKeys: termKeys) {
                let keyed = from.filter { !$0.key.isEmpty }
                let respaced = !keyed.isEmpty && keyed.map(\.key).joined() == to.map(\.key).joined() && termKeys.contains(to.map(\.key).joined())
                let unknown = keyed.contains { !isKnownWord($0.surface) }
                let confidences = keyed.compactMap(\.confidence)
                let uncertain: (Float) -> Bool = { threshold in
                    !keyed.isEmpty && confidences.count == keyed.count && (confidences.min() ?? 1) < threshold
                }
                let keep: Bool
                switch policy {
                case .none: keep = true
                // The guard admits terms; a correction that only deletes words is never kept.
                case _ where to.isEmpty: keep = false
                case .spelling: keep = respaced || unknown
                case .confidence(let t): keep = respaced || uncertain(t)
                case .spellingOrConfidence(let t): keep = respaced || unknown || uncertain(t)
                }
                if keep { output += to.map(\.surface); accepted += 1 } else { output += from.map(\.surface); rejected += 1 }
            }
        }
        return Outcome(text: output.joined(separator: " "), accepted: accepted, rejected: rejected)
    }

    /// Splits a changed block into the smallest replacements, chosen as the cheapest alignment of the whole block:
    /// re-spacings ("post hog" -> "PostHog") are free; one-for-one substitutions, two or three words merged into a
    /// term, one word split into a term, and single insertions or deletions cost one. Each piece is judged on its own,
    /// so an insertion or deletion is never carried along by a neighbouring accepted replacement.
    static func replacements(_ from: [Word], _ to: [Word], termKeys: Set<String>) -> [([Word], [Word])] {
        let n = from.count, m = to.count
        func joined(_ words: ArraySlice<Word>) -> String { words.map(\.key).joined() }
        // Compound moves use real words only, so punctuation ("—") is always judged on its own.
        func words(_ side: [Word], _ range: Range<Int>) -> Bool { side[range].allSatisfy { !$0.key.isEmpty } }
        // Moves from (i, j): (from words, to words, cost).
        func moves(_ i: Int, _ j: Int) -> [(Int, Int, Int)] {
            var result: [(Int, Int, Int)] = []
            for a in 1...3 where i + a <= n {
                for b in 1...3 where j + b <= m && (a > 1 || b > 1) && words(from, i..<(i + a)) && words(to, j..<(j + b)) {
                    let key = joined(from[i..<(i + a)])
                    if !key.isEmpty, key == joined(to[j..<(j + b)]) { result.append((a, b, 0)) }
                }
            }
            // Punctuation pairs only with punctuation, so a dash never stands in for a word.
            if i < n, j < m, from[i].key.isEmpty == to[j].key.isEmpty { result.append((1, 1, 1)) }
            for a in 2...3 where i + a <= n && j < m && words(from, i..<(i + a)) && !to[j].key.isEmpty && termKeys.contains(to[j].key) {
                result.append((a, 1, 1))
            }
            for b in 2...3 where i < n && j + b <= m && !from[i].key.isEmpty && words(to, j..<(j + b))
                && termKeys.contains(joined(to[j..<(j + b)])) { result.append((1, b, 1)) }
            if i < n { result.append((1, 0, 1)) }
            if j < m { result.append((0, 1, 1)) }
            return result
        }
        var cost = Array(repeating: Array(repeating: Int.max, count: m + 1), count: n + 1)
        var step = Array(repeating: Array(repeating: (0, 0), count: m + 1), count: n + 1)
        cost[n][m] = 0
        for i in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) where i < n || j < m {
                for (a, b, c) in moves(i, j) where cost[i + a][j + b] != Int.max && c + cost[i + a][j + b] < cost[i][j] {
                    cost[i][j] = c + cost[i + a][j + b]
                    step[i][j] = (a, b)
                }
            }
        }
        var pieces: [([Word], [Word])] = []
        var i = 0, j = 0
        while i < n || j < m {
            let (a, b) = step[i][j]
            pieces.append((Array(from[i..<(i + a)]), Array(to[j..<(j + b)])))
            i += a; j += b
        }
        return pieces
    }

    // NSSpellChecker knows inflections ("manages", "windows") that plain word lists lack.
    // Proper nouns are accepted in their capitalized form ("Monday").
    private static func isKnownWord(_ surface: String) -> Bool {
        let word = surface.trimmingCharacters(in: .punctuationCharacters)
        guard word.contains(where: \.isLetter) else { return true }
        let checker = NSSpellChecker.shared
        func known(_ value: String) -> Bool {
            checker.checkSpelling(of: value, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
        let lower = word.lowercased()
        return known(lower) || known(lower.prefix(1).uppercased() + lower.dropFirst())
    }

    struct Block {
        let equal: Bool
        let original: Range<Int>
        let corrected: Range<Int>
    }

    /// Minimum-edit alignment of word keys, grouped into equal and changed blocks.
    static func align(_ a: [String], _ b: [String]) -> [Block] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var blocks: [Block] = []
        var i = 0, j = 0, changeStart = (0, 0), inChange = false
        func closeChange() {
            if inChange { blocks.append(Block(equal: false, original: changeStart.0..<i, corrected: changeStart.1..<j)); inChange = false }
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                closeChange()
                blocks.append(Block(equal: true, original: i..<(i + 1), corrected: j..<(j + 1)))
                i += 1; j += 1
            } else {
                if !inChange { changeStart = (i, j); inChange = true }
                if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        closeChange()
        return blocks
    }
}
