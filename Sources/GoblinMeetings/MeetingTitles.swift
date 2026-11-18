import CryptoKit
import Foundation

/// Which title a meeting shows. A name the person typed always wins; then a real name from the call app; then the
/// notes' title from what was said, when the call app's name says nothing (a Meet code, "Zoom Meeting"); then the
/// recorded name. The folder keeps the recorded name either way.
public enum MeetingTitles {
    /// `generated` is only read when it could win, so a list doesn't open notes.json for meetings with real names.
    public static func display(typed: String?, recorded: String, generated: @autoclosure () -> String?) -> String {
        if let typed, !typed.isEmpty { return typed }
        if isGeneric(recorded), let generated = generated(), !generated.isEmpty { return generated }
        return recorded
    }

    /// The title a meeting folder shows now, from meeting.json, session.json and notes.json.
    public static func display(directory: URL, session: MeetingSessionInfo?) -> String {
        let recorded = session?.title ?? MeetingStorage.title(fromFolderName: directory.lastPathComponent)
        return display(typed: MeetingMetadata.read(directory).title, recorded: recorded,
                       generated: MeetingNotesFile.read(directory)?.title)
    }

    /// The title for a meeting whose notes title is `generated` (a draft not saved yet).
    public static func display(directory: URL, generated: String?) -> String {
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        return display(typed: MeetingMetadata.read(directory).title,
                       recorded: session?.title ?? MeetingStorage.title(fromFolderName: directory.lastPathComponent), generated: generated)
    }

    /// A title that names the app or a meeting code, not what the meeting was about.
    public static func isGeneric(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        // "Meet – abc-defg-hij", with or without a profile name after it.
        if lower.range(of: "^(google )?meet\\s*[-–—:]?\\s*[a-z]{3}-[a-z]{4}-[a-z]{3}\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil { return true }
        let generic: Set<String> = ["meet", "google meet", "zoom", "zoom meeting", "zoom webinar", "zoom workplace", "microsoft teams",
                                    "teams", "teams meeting", "meeting", "huddle", "slack", "slack huddle", "facetime", "webex",
                                    "discord", "call", "conversation", "simulation", "untitled", "new meeting"]
        if generic.contains(lower) { return true }
        // The app's words plus a person or a number, and nothing about the topic: "Zoom Meeting 2", "Huddle with Sam",
        // "FaceTime – Sam Okafor", "Call with Sam". "Zoom meeting integration review" is a topic.
        let forms = [#"^zoom meeting \d+$"#, #"^(slack )?huddle (with|in) [^,:;–—-]{1,40}$"#, #"^facetime\s*[-–—:]\s*[^,:;]{1,40}$"#,
                     #"^(call|meeting|chat) with \S+( \S+){0,2}$"#]
        return forms.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// The model's title cleaned up, or nil when there's nothing usable: quotes, Markdown and "Title:" go, and it
    /// must be 1 to 10 words that aren't "Call with …".
    public static func sanitize(_ title: String) -> String? {
        var text = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "^(#+\\s*|title\\s*:\\s*)", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*_ ."))
        let words = text.split(separator: " ")
        guard !text.isEmpty, text.uppercased() != "<EMPTY>", text.count <= 80, (1...10).contains(words.count),
              !isGeneric(text) else { return nil }
        return text
    }
}

extension MeetingNotes {
    /// The notes with their active fixes applied to every text.
    public var corrected: MeetingNotes { MeetingNotesFixer.apply(fixes, to: self) }
}

/// Applies a meeting's spelling fixes to its transcript.
public enum MeetingNotesFixer {
    /// `heard` as a whole word or phrase, any case; the space between words may be any run of spaces.
    static func pattern(for heard: String) -> NSRegularExpression {
        let words = heard.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = words.joined(separator: "\\s+")
        // A fixed pattern from escaped words compiles.
        // Marks count as part of a word, so "Jose" doesn't match the start of a decomposed "José".
        return (try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}\\p{M}])\(body)(?![\\p{L}\\p{N}\\p{M}])", options: [.caseInsensitive]))
            ?? NSRegularExpression()
    }

    /// One active fix, ready to apply: what it looks for, and the spellings that already count as fixed.
    struct Compiled {
        var fix: MeetingNotes.SpellingFix
        var regex: NSRegularExpression
        /// The replacement as written, and every form the other fixes turn it into ("Alex Kym" for "Alex" → "Alex
        /// Kim" beside "Kim" → "Kym"), so applying the fixes again changes nothing.
        var kept: [NSRegularExpression]
        /// One word for one word, so word timings can take it too.
        var oneWord: Bool
    }

    /// The active fixes, longer phrases first so "Googel Meat" → "Google Meet" isn't pre-empted by "Googel" →
    /// "Google".
    static func compile(_ fixes: [MeetingNotes.SpellingFix]) -> [Compiled] {
        let active = fixes.filter(\.isActive).sorted { $0.heard.count > $1.heard.count }
        let plain = active.map { (fix: $0, regex: pattern(for: $0.heard)) }
        return plain.map { entry in
            // Every form the replacement takes as the other fixes act on it, until they stop changing it:
            // "Alex Kim", "Alex Kimberly", "Alex Kimberley" for a chain Kim → Kimberly → Kimberley.
            var forms = [entry.fix.meant]
            for _ in 0..<plain.count {
                let next = plain.reduce(forms[forms.count - 1]) { text, other in
                    other.fix == entry.fix ? text
                        : other.regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                               withTemplate: NSRegularExpression.escapedTemplate(for: other.fix.meant))
                }
                // Fixes that feed each other ("Bora" → "Bora Bora") would grow a form without end; past a few
                // times the replacement's own length it's no longer a spelling anyone wrote.
                if forms.contains(next) || next.count > max(200, entry.fix.meant.count * 4) { break }
                forms.append(next)
            }
            let kept = forms.sorted { $0.count > $1.count }.map(pattern(for:))
            return Compiled(fix: entry.fix, regex: entry.regex, kept: kept,
                            oneWord: !entry.fix.heard.contains(where: \.isWhitespace) && !entry.fix.meant.contains(where: \.isWhitespace))
        }
    }

    /// `text` with every fix applied, pass after pass until nothing changes, so a chain of fixes lands on its last
    /// spelling at once and applying them again is a no-op. Bounded by the number of fixes.
    static func settle(_ text: String, _ compiled: [Compiled]) -> String {
        var current = text
        for _ in 0...compiled.count {
            let next = compiled.reduce(current) { replace($0, $1) }
            if next == current { break }
            current = next
        }
        return current
    }

    /// `text` with one fix applied. Where the right spelling is already there ("Alex Kim" for the fix "Alex" → "Alex
    /// Kim", or "Alex Kym" once "Kim" → "Kym" has run too), it's left alone rather than spelled out again.
    static func replace(_ text: String, _ compiled: Compiled) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        let heard = compiled.regex.matches(in: text, range: whole).map(\.range)
        // What to leave alone: the right spelling where it already stands, longest first and not overlapping. A
        // match that lies inside something to fix ("Notion" in "Notion AI" for "Notion AI" → "Notion") is part of
        // that, not a spelling already right.
        var chosen: [NSRange] = []
        for kept in compiled.kept {
            for match in kept.matches(in: text, range: whole) {
                let range = match.range
                let insideHeard = heard.contains { $0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0) && $0 != range }
                guard !insideHeard, !chosen.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                chosen.append(range)
            }
        }
        var protected: [String] = []
        var masked = text
        for range in chosen.sorted(by: { $0.location > $1.location }) {
            guard let bounds = Range(range, in: masked) else { continue }
            protected.append(String(masked[bounds]))
            masked.replaceSubrange(bounds, with: "\u{E000}\(protected.count - 1)\u{E001}")
        }
        var fixed = compiled.regex.stringByReplacingMatches(in: masked, range: NSRange(masked.startIndex..., in: masked),
                                                            withTemplate: NSRegularExpression.escapedTemplate(for: compiled.fix.meant))
        for (index, original) in protected.enumerated().reversed() {
            fixed = fixed.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: original)
        }
        return fixed
    }

    /// Every text in the notes with the active fixes applied, so they spell names the way the transcript now does.
    public static func apply(_ fixes: [MeetingNotes.SpellingFix], to notes: MeetingNotes) -> MeetingNotes {
        let compiled = compile(fixes)
        guard !compiled.isEmpty else { return notes }
        func fix(_ text: String) -> String { settle(text, compiled) }
        var notes = notes
        notes.title = notes.title.map(fix)
        notes.summary = fix(notes.summary)
        for index in notes.decisions.indices { notes.decisions[index].text = fix(notes.decisions[index].text) }
        for index in notes.actionItems.indices {
            notes.actionItems[index].task = fix(notes.actionItems[index].task)
            notes.actionItems[index].owner = notes.actionItems[index].owner.map(fix)
            notes.actionItems[index].due = notes.actionItems[index].due.map(fix)
        }
        for section in notes.sections.indices {
            notes.sections[section].heading = fix(notes.sections[section].heading)
            for item in notes.sections[section].items.indices { notes.sections[section].items[item].text = fix(notes.sections[section].items[item].text) }
        }
        for index in notes.marks.indices { notes.marks[index].note = fix(notes.marks[index].note) }
        return notes
    }

    /// The turns with every active fix applied to their text, and to the words of one-word fixes.
    public static func apply(_ fixes: [MeetingNotes.SpellingFix], to turns: [TranscriptTurn]) -> [TranscriptTurn] {
        let compiled = compile(fixes)
        guard !compiled.isEmpty else { return turns }
        return turns.map { turn in
            var turn = turn
            turn.text = settle(turn.text, compiled)
            // Word timings change only for one word swapped for one word; "Alex" → "Alex Kim" would put two words in
            // one timed slot (or double a "Kim" already timed beside it), so longer fixes stay in the text.
            let wordFixes = compiled.filter(\.oneWord)
            if !wordFixes.isEmpty {
                for index in turn.words.indices { turn.words[index].text = settle(turn.words[index].text, wordFixes) }
            }
            return turn
        }
    }
}

/// notes.json and notes.md in a meeting folder.
public enum MeetingNotesFile {
    public static let notesFile = "notes.json"
    public static let markdownFile = "notes.md"

    /// The notes as shown: the model's text with the active fixes applied.
    public static func read(_ directory: URL) -> MeetingNotes? {
        stored(directory)?.corrected
    }

    /// notes.json as kept: the model's text as written, plus the fixes. Fixes are applied whenever the notes are read,
    /// as they are to the transcript when it's rendered, so changing one never re-corrects corrected text.
    static func stored(_ directory: URL) -> MeetingNotes? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(notesFile)) else { return nil }
        return try? JSONDecoder.meeting.decode(MeetingNotes.self, from: data)
    }

    /// Writes notes.json, then notes.md with the voices' current names.
    /// `notes` is the model's text as written; the fixes are applied for notes.md and whenever it's read.
    public static func write(_ notes: MeetingNotes, to directory: URL) throws {
        try JSONEncoder.pretty.encode(notes).write(to: directory.appendingPathComponent(notesFile), options: .atomic)
        try writeMarkdown(notes, directory: directory)
    }

    /// SHA-256 of attributed.json: the transcript as processing left it, before names and fixes.
    public static func sourceHash(_ directory: URL) -> String {
        let data = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
            ?? (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile))) ?? Data()
        return hash(data)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The names to read the notes' speakers by: the current ones, or, once the meeting was processed again and its
    /// voices may be numbered differently, the names they had when the notes were written.
    public static func names(for notes: MeetingNotes, directory: URL) -> [String: String] {
        isStale(notes, directory: directory) ? (notes.written.names ?? [:]) : MeetingPostProcessor.speakerNames(directory)
    }

    /// Whether the meeting was processed again since its notes were written.
    public static func isStale(_ notes: MeetingNotes, directory: URL) -> Bool {
        notes.written.transcriptHash != sourceHash(directory)
    }

    public static func delete(in directory: URL) throws {
        for name in [notesFile, markdownFile] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Called when the transcript is rendered: the notes' fixes go into the turns, and notes.md picks up renamed
    /// voices. Without notes, the turns come back as they were.
    public static func rendered(_ turns: [TranscriptTurn], directory: URL) -> [TranscriptTurn] {
        guard let notes = stored(directory) else { return turns }
        try? writeMarkdown(notes, directory: directory)
        return MeetingNotesFixer.apply(notes.fixes, to: turns)
    }

    static func writeMarkdown(_ stored: MeetingNotes, directory: URL) throws {
        let notes = stored.corrected
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        let title = MeetingTitles.display(typed: MeetingMetadata.read(directory).title,
                                          recorded: session?.title ?? MeetingStorage.title(fromFolderName: directory.lastPathComponent),
                                          generated: notes.title)
        try markdown(notes, title: title, names: names(for: notes, directory: directory))
            .write(to: directory.appendingPathComponent(markdownFile), atomically: true, encoding: .utf8)
    }

    /// The notes as Markdown: summary, decisions, action items as checkboxes, the template's sections, then marks.
    /// Times are `[hh:mm:ss]`, as in transcript.md.
    public static func markdown(_ notes: MeetingNotes, title: String?, names: [String: String]) -> String {
        func time(_ at: Double?) -> String { at.map { " [\(WordAssembly.timestamp($0))]" } ?? "" }
        func say(_ text: String) -> String { notes.resolve(text, names: names) }
        var lines: [String] = []
        if let title { lines += ["# \(title)", ""] }
        if !notes.summary.isEmpty { lines += [say(notes.summary), ""] }
        if !notes.decisions.isEmpty {
            lines.append("## Decisions")
            for decision in notes.decisions {
                let status = decision.status == .decided ? "" : " (\(decision.status == .open ? "open" : "disagreed"))"
                lines.append("- \(say(decision.text))\(status)\(time(decision.at))")
            }
            lines.append("")
        }
        if !notes.actionItems.isEmpty {
            lines.append("## Action items")
            for item in notes.actionItems {
                let owner = notes.ownerName(item, names: names).map { "**\($0)**: " } ?? ""
                let due = item.due.map { " (\(say($0)))" } ?? ""
                lines.append("- [ ] \(owner)\(say(item.task))\(due)\(time(item.at))")
            }
            lines.append("")
        }
        for section in notes.sections {
            lines.append("## \(say(section.heading))")
            lines += section.items.map { "- \(say($0.text))\(time($0.at))" }
            lines.append("")
        }
        if !notes.marks.isEmpty {
            lines.append("## Marks")
            lines += notes.marks.map { mark in
                "- [\(WordAssembly.timestamp(mark.t))] " + (mark.label.map { "\($0): " } ?? "") + say(mark.note)
            }
            lines.append("")
        }
        let model = [notes.written.tool.title, notes.written.model, notes.written.effort].compactMap { $0 }.joined(separator: " · ")
        lines.append("_Notes by \(model), \(notes.written.template.name) template._")
        return lines.joined(separator: "\n") + "\n"
    }
}
