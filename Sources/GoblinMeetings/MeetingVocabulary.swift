import Foundation
import GoblinCore
import os

/// The words a meeting's transcript is checked against when it's shown: the person's dictionary (its sounds-like
/// spellings, as in dictation) and the names of the people on the call and in People, so "Mirra" reads "Mira" when
/// Mira was there.
///
/// Speech recognition hears a name it doesn't know as the nearest thing it does. A capitalised word in the middle of
/// a sentence, one letter away from exactly one known name or single-word term, is taken to be that name. Lower-case
/// words, sentence starts and ordinary English words are left alone, so "games" never becomes "James" and a
/// capitalised "Well" never becomes "Will". Only the shown text changes;
/// segments.jsonl keeps what was heard.
public struct MeetingVocabulary: Sendable {
    private static let dictionaryProvider = OSAllocatedUnfairLock<@Sendable () -> [DictionaryEntry]>(initialState: { [] })
    private static let peopleProvider = OSAllocatedUnfairLock<@Sendable () -> [String]>(initialState: { [] })

    /// Where the person's dictionary comes from. The app sets it at launch; tests and fixtures leave it empty.
    public static var dictionary: @Sendable () -> [DictionaryEntry] {
        get { dictionaryProvider.withLock { $0 } }
        set { dictionaryProvider.withLock { $0 = newValue } }
    }

    /// Names in People, which apply to every meeting. The app sets it at launch.
    public static var peopleNames: @Sendable () -> [String] {
        get { peopleProvider.withLock { $0 } }
        set { peopleProvider.withLock { $0 = newValue } }
    }

    /// A known word a name or term can be heard as: at least this many letters.
    static let shortestCorrected = 4

    private let entries: [DictionaryEntry]
    /// Lower-cased spelling → spelling, for names and single-word terms a near miss turns into.
    private let targets: [String: String]
    /// Every word of every name and dictionary spelling, multi-word ones included ("Jonah" of "Jonah Hill"): a word
    /// someone wrote down on purpose is never taken for a near miss of something else.
    private let known: Set<String>

    /// A meeting belongs to no app or project, so only entries meant for everywhere rewrite by their sounds-like
    /// spellings: an alias kept to one project ("crust a" for CrustData) mustn't rewrite a meeting about something else.
    /// Scoped terms still lend their exact spelling to the capitalised near-miss check, which can't touch ordinary words.
    /// Phrases left exactly as heard: the notes' spelling fixes decide those, applied, suggested or put back by the
    /// person, so correcting them first would override that decision or leave a fix nothing to match.
    /// Compiled once: a long meeting has hundreds of paragraphs, and compiling every phrase for each took seconds.
    private let protectedPatterns: [NSRegularExpression]

    public init(dictionary: [DictionaryEntry], names: [String], protecting phrases: [String] = []) {
        protectedPatterns = phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { MeetingNotesFixer.pattern(for: $0) }
        entries = dictionary.filter { $0.apps.isEmpty && $0.projects.isEmpty }
        var targets: [String: String] = [:]
        let nameWords = names.flatMap { $0.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init) }
        let termWords = dictionary.map(\.spelling).filter { !$0.contains(" ") }
        for word in nameWords + termWords where word.count >= Self.shortestCorrected && word.allSatisfy(\.isLetter) {
            targets[word.lowercased()] = targets[word.lowercased()] ?? word
        }
        self.targets = targets
        // Split into letter runs, as the near-miss pass reads a transcript: "O'Neill" makes both "o" and "neill" known.
        let letterRuns = (dictionary.map(\.spelling) + names).flatMap { $0.split(whereSeparator: { !$0.isLetter }) }
        known = Set(letterRuns.map { $0.lowercased() })
    }

    public var isEmpty: Bool { entries.isEmpty && targets.isEmpty }

    /// Where the protected phrases are in `text`: whole words, any case, overlaps joined.
    private func protectedRanges(in text: String) -> [Range<String.Index>] {
        // The notes' own matcher, so protection finds exactly what the notes will (any run of spaces, whole words).
        var ranges: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..., in: text)
        for pattern in protectedPatterns {
            for match in pattern.matches(in: text, range: whole) {
                if let found = Range(match.range, in: text) { ranges.append(found) }
            }
        }
        // A notes phrase inside a code span or address takes the whole span with it, so no fragment is left without its
        // delimiters for the near-miss pass to read as prose.
        if !ranges.isEmpty {
            ranges += DictionaryCorrector.protectedRanges(in: text).compactMap { Range($0, in: text) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var joined: [Range<String.Index>] = []
        for range in ranges {
            if let last = joined.last, range.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { joined.append(range) }
        }
        return joined
    }

    /// The turn with its text corrected. Its words take the corrected spellings when the count of words didn't change.
    public func correct(_ turn: TranscriptTurn) -> TranscriptTurn {
        guard !isEmpty else { return turn }
        let text = correct(turn.text)
        guard text != turn.text else { return turn }
        var corrected = turn
        corrected.text = text
        let spoken = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if spoken.count == turn.words.count {
            for index in corrected.words.indices { corrected.words[index].text = spoken[index] }
        }
        return corrected
    }

    public func correct(_ text: String) -> String {
        let kept = protectedRanges(in: text)
        guard !kept.isEmpty else { return correctOpen(text) }
        // The text around each protected phrase is corrected on its own; the phrase stays as heard.
        var result = ""
        var cursor = text.startIndex
        for range in kept {
            result += correctOpen(String(text[cursor..<range.lowerBound]))
            result += text[range]
            cursor = range.upperBound
        }
        return result + correctOpen(String(text[cursor...]))
    }

    private func correctOpen(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let aliased = entries.isEmpty ? text : DictionaryCorrector.correct(text, entries: entries).text
        return nearMisses(aliased)
    }

    /// Replaces capitalised mid-sentence words one letter away from exactly one target.
    func nearMisses(_ text: String) -> String {
        guard !targets.isEmpty else { return text }
        // Addresses, code and identifiers ("https://Mirra.dev") stay as written, as in dictation.
        let protected = DictionaryCorrector.protectedRanges(in: text)
        var output = ""
        var sentenceStart = true
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter else {
                let character = text[index]
                if ".?!…\n".contains(character) { sentenceStart = true }
                output.append(character)
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
            let word = String(text[index..<end])
            let isProtected = DictionaryCorrector.isProtected(index..<end, in: text, ranges: protected)
            output += sentenceStart || isProtected ? word : replacement(for: word) ?? word
            sentenceStart = false
            index = end
        }
        return output
    }

    private func replacement(for word: String) -> String? {
        guard word.count >= Self.shortestCorrected, word.first?.isUppercase == true, !DictionaryCorrector.isCommonWord(word) else { return nil }
        let key = word.lowercased()
        guard targets[key] == nil, !known.contains(key) else { return nil }
        let near = targets.filter { Self.oneEditApart(key, $0.key) }
        guard near.count == 1, let target = near.first?.value else { return nil }
        // An all-capitals word stays all capitals; a spelling with its own capitals inside keeps them ("iPhone",
        // "GrokBot"); otherwise the known spelling, capitalised like the word ("Zepyr" → "Zephyr").
        if word == word.uppercased() { return target.uppercased() }
        if target.dropFirst().contains(where: \.isUppercase) { return target }
        return target.first!.uppercased() + target.dropFirst()
    }

    static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        if a.count == b.count { return zip(a, b).filter { $0 != $1 }.count == 1 }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        var i = 0, j = 0, skipped = false
        while i < long.count, j < short.count {
            if long[i] == short[j] { i += 1; j += 1 } else if skipped { return false } else { skipped = true; i += 1 }
        }
        return true
    }
}
