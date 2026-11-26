import Foundation

/// Read-only questions about the meetings on disk, answered as plain text for an AI app: listing, searching, reading a
/// transcript in pages, and reading notes. It never writes, repairs or processes anything, so it's safe beside the
/// running app. A meeting still recording or processing is read from its live lines and labelled provisional.
public actor MeetingQuery {
    public let store: MeetingStore
    private let timeZone: TimeZone
    private var cache: [String: (stamp: [Stamp], content: MeetingContent)] = [:]

    public init(root: URL = MeetingStorage.root, timeZone: TimeZone = .current) {
        store = MeetingStore(root: root)
        self.timeZone = timeZone
    }

    /// One readable line of a meeting: a transcript turn, a line of its notes, or a paragraph the person typed.
    struct Passage: Sendable {
        enum Source: String, Sendable { case transcript, notes, typedNotes = "your notes" }
        var source: Source
        var speaker: String?
        /// The person who recorded the meeting ("You"), whatever name they were later given; what You and Them filter on.
        var isRecorder = false
        /// Nobody is told apart yet (a conversation in the room still recording is all "Room"), so it's neither You nor Them.
        var unattributed = false
        var start: Double?
        var end: Double?
        var text: String {
            didSet { words = SearchScorer.words(text) }
        }
        /// The text's words, worked out once: searching re-reads every meeting each time.
        private(set) var words: [SearchScorer.Word]

        init(source: Source, speaker: String?, start: Double?, end: Double?, text: String, isRecorder: Bool = false) {
            self.source = source
            self.speaker = speaker
            self.isRecorder = isRecorder
            self.start = start
            self.end = end
            self.text = text
            words = SearchScorer.words(text)
        }
    }

    struct MeetingContent: Sendable {
        var turns: [Passage]
        /// The transcript is the live one: names and wording change once the meeting is processed.
        var provisional: Bool
        var notes: [Passage]
    }

    struct Stamp: Equatable, Sendable {
        var modified: Date?
        var size: Int?
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case badArgument(String)
        case noMeeting(String)

        public var errorDescription: String? {
            switch self {
            case .badArgument(let message): message
            case .noMeeting(let message): message
            }
        }
    }

    // MARK: Tools

    public struct ListOptions: Sendable {
        public var since: Date?
        public var until: Date?
        public var query: String?
        public var person: String?
        public var limit = 20
        public var includeInProgress = true
        public init() {}
    }

    public func listMeetings(_ options: ListOptions) async -> String {
        let matching = await meetings(since: options.since, until: options.until, includeInProgress: options.includeInProgress)
            .filter { meeting in
                if let query = options.query, !Self.fold(query).isEmpty {
                    let haystack = ([meeting.title, meeting.source] + meeting.participants + meeting.speakers).map(Self.fold).joined(separator: "\n")
                    guard Self.fold(query).split(separator: " ").allSatisfy({ haystack.contains($0) }) else { return false }
                }
                if let person = options.person, !Self.fold(person).isEmpty {
                    guard (meeting.participants + meeting.speakers).contains(where: { Self.fold($0).contains(Self.fold(person)) }) else { return false }
                }
                return true
            }
        guard !matching.isEmpty else { return "No meetings match." }
        let shown = matching.prefix(options.limit)
        var lines = [matching.count > shown.count
                     ? "\(matching.count) meetings match; " + (shown.count == 1 ? "the newest is" : "the newest \(shown.count) are")
                       + " below. Narrow with since/until or raise limit."
                     : (matching.count == 1 ? "1 meeting:" : "\(matching.count) meetings, newest first:"), ""]
        for meeting in shown { lines += describe(meeting) + [""] }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public struct SearchOptions: Sendable {
        public var query: String
        public var since: Date?
        public var until: Date?
        public var meetingID: String?
        public var speaker: String?
        public var limit = 10
        public var fuzzy = true
        public var includeInProgress = true
        public init(query: String) { self.query = query }
    }

    public func search(_ options: SearchOptions) async throws -> String {
        let parsed = SearchQuery(options.query)
        guard !parsed.isEmpty else { throw Failure.badArgument("The query has no words to look for.") }
        var candidates = await meetings(since: options.since, until: options.until, includeInProgress: options.includeInProgress)
        if let id = options.meetingID {
            // One meeting, still within the other filters.
            let meeting = try await resolve(id)
            candidates = Self.includes(meeting, since: options.since, until: options.until, includeInProgress: options.includeInProgress) ? [meeting] : []
            if candidates.isEmpty { return "That meeting is outside since/until, or still in progress with include_in_progress off." }
        }
        var documents: [(meeting: MeetingSummary, content: MeetingContent, index: Int, inTranscript: Bool)] = []
        var contents: [String: MeetingContent] = [:]
        for meeting in candidates {
            let content = content(meeting)
            contents[meeting.id] = content
            for index in content.turns.indices where Self.speakerMatches(content.turns[index], options.speaker) {
                documents.append((meeting, content, index, true))
            }
            if options.speaker == nil { for index in content.notes.indices { documents.append((meeting, content, index, false)) } }
        }
        let scorer = SearchScorer(query: parsed, fuzzy: options.fuzzy)
        let scored = scorer.rank(documents.map { $0.inTranscript ? $0.content.turns[$0.index].words : $0.content.notes[$0.index].words })
        guard !scored.isEmpty else {
            let scope = options.meetingID != nil ? "that meeting" : (candidates.count == 1 ? "1 meeting" : "\(candidates.count) meetings")
            return "Nothing in \(scope) matches \(Self.quoted(options.query)). Try other words, or fewer of them."
        }
        let shown = scored.prefix(options.limit)
        var perMeeting: [String: Int] = [:]
        for hit in scored { perMeeting[documents[hit.document].meeting.id, default: 0] += 1 }
        var lines = ["\(scored.count) \(scored.count == 1 ? "passage" : "passages") in \(perMeeting.count) \(perMeeting.count == 1 ? "meeting" : "meetings") match \(Self.quoted(options.query))"
                     + (scored.count > shown.count ? "; the best \(shown.count) are below." : "."), ""]
        for (rank, hit) in shown.enumerated() {
            let document = documents[hit.document]
            let meeting = document.meeting
            lines.append("\(rank + 1). \(meeting.title) · \(dateText(meeting.startedAt))")
            lines.append("   meeting_id: \(meeting.id)")
            if document.inTranscript {
                let turns = document.content.turns
                if document.content.provisional { lines.append("   (live transcript, still provisional)") }
                if document.index > 0 { lines.append("   before: " + line(turns[document.index - 1], limit: 160)) }
                lines.append("   ▸ " + line(turns[document.index], highlight: hit, limit: 600))
                if document.index + 1 < turns.count { lines.append("   after: " + line(turns[document.index + 1], limit: 160)) }
            } else {
                let passage = document.content.notes[document.index]
                // Notes lines carry their own time ("… [00:24:51]"), unless the excerpt cut it off; a marked moment's is added.
                let snippet = Self.snippet(passage.text, hit: hit, limit: 600)
                let time = passage.start.map { "[\(Self.clock($0))]" }.flatMap { snippet.contains($0) ? nil : " " + $0 } ?? ""
                lines.append("   ▸ from the \(passage.source.rawValue): " + snippet + time)
            }
            lines.append("")
        }
        if perMeeting.count > 1 {
            let counts = perMeeting.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10).map { id, count in
                "\(candidates.first { $0.id == id }?.title ?? id) (\(count))"
            }
            lines.append("Matches by meeting: " + counts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public struct TranscriptOptions: Sendable {
        public var meetingID: String
        public var from: Double?
        public var to: Double?
        public var speaker: String?
        public var maxCharacters = 20_000
        public var cursor: Int?
        public init(meetingID: String) { self.meetingID = meetingID }
    }

    public func transcript(_ options: TranscriptOptions) async throws -> String {
        let meeting = try await resolve(options.meetingID)
        let content = content(meeting)
        return (header(meeting, provisional: content.provisional) + transcriptLines(meeting, content, options)).joined(separator: "\n")
    }

    private func transcriptLines(_ meeting: MeetingSummary, _ content: MeetingContent, _ options: TranscriptOptions) -> [String] {
        guard !content.turns.isEmpty else {
            return [meeting.state == .ready ? "This meeting has no transcript lines." : "There's no transcript yet: the meeting is \(meeting.state.rawValue)."]
        }
        let selected = content.turns.filter { turn in
            if let from = options.from, (turn.end ?? turn.start ?? 0) < from { return false }
            if let to = options.to, (turn.start ?? 0) > to { return false }
            return Self.speakerMatches(turn, options.speaker)
        }
        guard !selected.isEmpty else { return ["No lines match that time range or speaker."] }
        let start = min(max(0, options.cursor ?? 0), selected.count)
        var lines: [String] = []
        var used = 0
        var index = start
        while index < selected.count {
            let text = line(selected[index], limit: nil)
            // Always at least one line, so a single very long turn still comes back.
            if index > start, used + text.count + 1 > options.maxCharacters { break }
            lines.append(text)
            used += text.count + 1
            index += 1
        }
        if index < selected.count {
            lines += ["", "[\(selected.count - index) more lines. Call get_transcript again with cursor \(index) and the same filters.]"]
        }
        return lines
    }

    public func notes(_ id: String) async throws -> String {
        notes(try await resolve(id))
    }

    private func notes(_ meeting: MeetingSummary) -> String {
        let directory = meeting.directory
        var lines = header(meeting, provisional: false)
        var found = false
        if let markdown = Self.notesMarkdown(directory), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found = true
            if let notes = MeetingNotesFile.read(directory), MeetingNotesFile.isStale(notes, directory: directory) {
                lines.append("(The transcript changed after these notes were written, so they may be out of date.)")
                lines.append("")
            }
            lines.append(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let typed = MeetingTypedNotes.read(from: directory) {
            found = true
            lines += ["", "## Typed during the meeting", "", typed.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let marks = MeetingMark.read(directory)
        if !marks.isEmpty {
            found = true
            lines += ["", "## Moments marked during the meeting", ""]
            lines += marks.map { "- [\(Self.clock($0.t))]" + ($0.label.map { " \($0)" } ?? "") }
        }
        if !found {
            lines.append("No notes are stored for this meeting. Notes are written in gob.lin; this tool never writes them. Read the transcript with get_transcript instead.")
        }
        return lines.joined(separator: "\n")
    }

    /// Everything about one meeting as Markdown, for the meeting's resource: the notes, then the whole transcript.
    public func document(_ id: String) async throws -> String {
        let meeting = try await resolve(id, exactly: true)
        let content = content(meeting)
        var options = TranscriptOptions(meetingID: meeting.id)
        options.maxCharacters = .max
        var lines = [notes(meeting), "", "## Transcript", ""]
        if content.provisional { lines += [header(meeting, provisional: true).dropLast().last ?? "", ""] }
        return (lines + transcriptLines(meeting, content, options)).joined(separator: "\n")
    }

    public func meetingList() async -> [MeetingSummary] { await allMeetings() }

    /// Reads every meeting once, so the first search doesn't wait for it.
    public func warm() async {
        for meeting in await allMeetings() {
            if Task.isCancelled { return }
            _ = content(meeting)
        }
    }

    /// Every meeting on disk, dropping what's cached for meetings deleted since.
    func allMeetings() async -> [MeetingSummary] {
        let all = await store.list()
        let ids = Set(all.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        return all
    }

    // MARK: Meetings

    func meetings(since: Date?, until: Date?, includeInProgress: Bool) async -> [MeetingSummary] {
        await allMeetings().filter { Self.includes($0, since: since, until: until, includeInProgress: includeInProgress) }
    }

    static func includes(_ meeting: MeetingSummary, since: Date?, until: Date?, includeInProgress: Bool) -> Bool {
        if let since, (meeting.endedAt ?? meeting.startedAt.addingTimeInterval(meeting.duration)) < since { return false }
        if let until, meeting.startedAt >= until { return false }
        // In progress is recording or processing; failed and interrupted meetings are done, if not finished.
        if !includeInProgress, meeting.state == .recording || meeting.state == .processing { return false }
        return true
    }

    /// A meeting by its ID, or by a title or ID that names exactly one: models often pass the title they were shown.
    func resolve(_ id: String, exactly: Bool = false) async throws -> MeetingSummary {
        let all = await allMeetings()
        // A resource names its meeting exactly, as listed (an ID can end in a space): one that's gone isn't swapped for
        // a lookalike.
        if exactly {
            guard let exact = all.first(where: { $0.id == id }) else {
                throw Failure.noMeeting("No meeting has the id \(Self.quoted(id)); it may have been deleted.")
            }
            return exact
        }
        // As given first: an ID can end in a space.
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all.first(where: { $0.id == trimmed }) { return exact }
        let folded = Self.fold(trimmed)
        guard !folded.isEmpty else { throw Failure.badArgument("meeting_id is empty. Use an id from list_meetings or search_meetings.") }
        let named = all.filter { Self.fold($0.id) == folded || Self.fold($0.title) == folded }
        let candidates = named.isEmpty ? all.filter { Self.fold($0.title).contains(folded) || Self.fold($0.id).contains(folded) } : named
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty { throw Failure.noMeeting("No meeting has the id \(Self.quoted(trimmed)). Use an id from list_meetings or search_meetings.") }
        let options = candidates.prefix(5).map { "\($0.id)" }.joined(separator: "; ")
        throw Failure.noMeeting("\(candidates.count) meetings match \(Self.quoted(trimmed)): \(options). Pass one of these ids.")
    }

    // MARK: Content

    func content(_ meeting: MeetingSummary) -> MeetingContent {
        let directory = meeting.directory
        let files = [MeetingStorage.transcriptFile, MeetingStorage.segmentsFile, MeetingNotesFile.markdownFile, MeetingStorage.typedNotesFile,
                     MeetingStorage.marksFile, MeetingStorage.muteFile, MeetingStorage.dictationsFile, MeetingStorage.liveDictationsFile,
                     MeetingStorage.sessionFile]
        let stamp = files.map { name -> Stamp in
            let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
        } + [Stamp(modified: nil, size: meeting.state == .recording ? 1 : 0)] // what `load` picks the transcript by
        if let cached = cache[meeting.id], cached.stamp == stamp { return cached.content }
        let content = Self.load(meeting)
        cache[meeting.id] = (stamp, content)
        return content
    }

    static func load(_ meeting: MeetingSummary) -> MeetingContent {
        let directory = meeting.directory
        var turns: [Passage] = []
        var provisional = false
        // The finished transcript whenever there is one, even while the meeting is processed again; the live lines only
        // while it records or before its first transcript.
        if let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)),
           let decoded = try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: data) {
            // The post-processor labels the recorder's voice You; a rename keeps the label.
            turns = decoded.map {
                Passage(source: .transcript, speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text,
                        isRecorder: $0.label == MeetingPostProcessor.microphoneLabel || $0.speaker == MeetingPostProcessor.microphoneLabel)
            }
        } else if let segments = try? MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile)),
                  !segments.isEmpty {
            provisional = true
            // As the live captions and the finished transcript do: what the mic heard while the call was muted, and
            // dictations, were never said to the meeting.
            let muted = MeetingPostProcessor.mutedSpans(directory.appendingPathComponent(MeetingStorage.muteFile), end: .greatestFiniteMagnitude)
            let dictations = MeetingPostProcessor.readDictations(directory) ?? []
            // Nor what the mic heard after the call ended, before recording stopped.
            let callEnd = MeetingStore.session(directory)?.callEndedAt
            let said = segments.compactMap { segment -> TranscriptSegment? in
                guard let segment = callEnd.map({ MeetingPostProcessor.before($0, segment) }) ?? segment else { return nil }
                guard segment.track == .microphone else { return segment }
                guard let audible = MeetingPostProcessor.removeMuted(segment, spans: muted).0 else { return nil }
                return MeetingPostProcessor.removeDictation(audible, spans: dictations).0
            }
            turns = liveTurns(said, inPerson: meeting.kind == .inPerson)
        }
        var notes: [Passage] = []
        if let markdown = notesMarkdown(directory) {
            for raw in markdown.components(separatedBy: "\n") {
                var text = raw.trimmingCharacters(in: .whitespaces)
                // Headings, and the writer's "_Notes by Codex · …_" byline, which says nothing about the meeting.
                if text.hasPrefix("#") || (text.hasPrefix("_Notes by ") && text.hasSuffix("_")) { continue }
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")).trimmingCharacters(in: .whitespaces)
                for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text.removeFirst(box.count) }
                guard !text.isEmpty else { continue }
                notes.append(Passage(source: .notes, speaker: nil, start: notesTime(text), end: nil, text: text))
            }
        }
        if let typed = MeetingTypedNotes.read(from: directory) {
            for paragraph in typed.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                notes.append(Passage(source: .typedNotes, speaker: nil, start: nil, end: nil, text: paragraph.trimmingCharacters(in: .whitespaces)))
            }
        }
        for mark in MeetingMark.read(directory) {
            if let label = mark.label, !label.isEmpty {
                notes.append(Passage(source: .notes, speaker: nil, start: mark.t, end: nil, text: "Marked moment: \(label)"))
            }
        }
        return MeetingContent(turns: turns, provisional: provisional, notes: notes)
    }

    /// Live lines joined into turns: your microphone is You, the call's sound is Them; in the room every voice is on the
    /// microphone, so there are no names until the meeting is processed.
    static func liveTurns(_ segments: [TranscriptSegment], inPerson: Bool) -> [Passage] {
        var turns: [Passage] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = inPerson ? "Room" : (segment.track == .microphone ? MeetingPostProcessor.microphoneLabel : "Them")
            if var last = turns.last, last.speaker == speaker, segment.start - (last.end ?? 0) < 2, (last.end ?? 0) - (last.start ?? 0) < 60 {
                last.text += " " + text
                last.end = segment.end
                turns[turns.count - 1] = last
            } else {
                var turn = Passage(source: .transcript, speaker: speaker, start: segment.start, end: segment.end, text: text,
                                   isRecorder: speaker == MeetingPostProcessor.microphoneLabel)
                turn.unattributed = inPerson
                turns.append(turn)
            }
        }
        return turns
    }

    /// notes.md, without the copy of the typed notes it was written with (`MeetingNotesFile.markdown` puts them as
    /// "## Your notes", the text, a blank line, just before its footer): they're read once, from typed-notes.md. Only that
    /// exact block goes, so a section of the notes' own with that heading, and the footer, stay.
    static func notesMarkdown(_ directory: URL) -> String? {
        guard var markdown = try? String(contentsOf: directory.appendingPathComponent(MeetingNotesFile.markdownFile), encoding: .utf8) else { return nil }
        guard let typed = MeetingTypedNotes.read(from: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return markdown }
        if let copy = markdown.range(of: "## Your notes\n\(typed)\n\n", options: .backwards) { markdown.removeSubrange(copy) }
        return markdown
    }

    /// A notes line's time, as notes.md writes it: "[00:24:51]", the last one in the line.
    static func notesTime(_ text: String) -> Double? {
        guard let match = text.matches(of: /\[(\d{2}:\d{2}:\d{2})\]/).last else { return nil }
        return parseOffset(String(match.output.1))
    }

    // MARK: Text

    private func describe(_ meeting: MeetingSummary) -> [String] {
        let end = meeting.endedAt ?? meeting.startedAt.addingTimeInterval(meeting.duration)
        var facts = ["\(dateText(meeting.startedAt))–\(timeText(end)) (\(Self.length(meeting.duration)))"]
        facts.append(meeting.kind == .inPerson ? "in the room" : (meeting.source.isEmpty ? "call" : "\(meeting.source) call"))
        if meeting.state != .ready { facts.append(meeting.state == .recording ? "recording now" : meeting.state.rawValue) }
        var lines = ["- \(meeting.title)", "  meeting_id: \(meeting.id)", "  " + facts.joined(separator: " · ")]
        if !meeting.speakers.isEmpty { lines.append("  speakers: " + meeting.speakers.joined(separator: ", ")) }
        let unheard = meeting.participants.filter { participant in !meeting.speakers.contains { Self.fold($0) == Self.fold(participant) } }
        if !unheard.isEmpty { lines.append("  participants: " + meeting.participants.joined(separator: ", ")) }
        let hasNotes = FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent(MeetingNotesFile.markdownFile).path)
        let hasTyped = MeetingTypedNotes.read(from: meeting.directory) != nil
        lines.append("  notes: " + (hasNotes ? (hasTyped ? "yes, plus notes typed during the meeting" : "yes") : (hasTyped ? "only notes typed during the meeting" : "none")))
        return lines
    }

    private func header(_ meeting: MeetingSummary, provisional: Bool) -> [String] {
        var lines = ["# \(meeting.title)", "meeting_id: \(meeting.id)",
                     "\(dateText(meeting.startedAt)) · \(Self.length(meeting.duration)) · "
                     + (meeting.kind == .inPerson ? "in the room" : (meeting.source.isEmpty ? "call" : "\(meeting.source) call"))]
        if !meeting.speakers.isEmpty { lines.append("speakers: " + meeting.speakers.joined(separator: ", ")) }
        if !meeting.participants.isEmpty { lines.append("participants: " + meeting.participants.joined(separator: ", ")) }
        if provisional {
            let voices = meeting.kind == .inPerson
                ? "Room is everyone in the room; voices are told apart once it's processed."
                : "You is the microphone and Them is the call; names come once it's processed."
            let state = switch meeting.state {
            case .recording: "This meeting is still recording."
            case .processing: "This meeting is still being processed."
            default: "This meeting wasn't processed (\(meeting.state.rawValue))."
            }
            lines.append("\(state) These are its live lines, without what was said muted or dictated. \(voices)")
        }
        lines.append("")
        return lines
    }

    private func line(_ passage: Passage, highlight: SearchScorer.Hit? = nil, limit: Int?) -> String {
        let text = highlight.map { Self.snippet(passage.text, hit: $0, limit: limit ?? .max) } ?? Self.truncate(passage.text, limit)
        return "[\(Self.clock(passage.start ?? 0))] \(passage.speaker ?? "?"): \(text)"
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter
    }

    private func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }

    private func timeText(_ date: Date) -> String {
        let formatter = dateFormatter
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "00:12:34", as the app and notes.md write times.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }

    static func truncate(_ text: String, _ limit: Int?) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let limit, flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The text around the first match, with matched words in **bold**.
    static func snippet(_ text: String, hit: SearchScorer.Hit, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let ranges = hit.ranges(in: flat)
        var lower = flat.startIndex, upper = flat.endIndex
        if flat.count > limit, let anchor = hit.anchor(in: flat) {
            let before = min(limit / 3, flat.distance(from: flat.startIndex, to: anchor))
            lower = flat.index(anchor, offsetBy: -before)
            upper = flat.index(lower, offsetBy: limit, limitedBy: flat.endIndex) ?? flat.endIndex
        }
        var result = lower > flat.startIndex ? "…" : ""
        var cursor = lower
        for range in ranges where range.lowerBound >= lower && range.upperBound <= upper {
            result += flat[cursor..<range.lowerBound] + "**" + flat[range] + "**"
            cursor = range.upperBound
        }
        result += flat[cursor..<upper]
        return result + (upper < flat.endIndex ? "…" : "")
    }

    static func quoted(_ text: String) -> String { "“\(text)”" }

    /// Lowercased, accents dropped, whitespace collapsed: for comparing names and titles.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func speakerMatches(_ passage: Passage, _ wanted: String?) -> Bool {
        guard let wanted, !fold(wanted).isEmpty, fold(wanted) != "all" else { return true }
        switch fold(wanted) {
        case "you": return passage.isRecorder && !passage.unattributed
        case "them": return !passage.isRecorder && !passage.unattributed
        default:
            guard let speaker = passage.speaker else { return false }
            // The whole name, or whole words of it in order: Sam finds Sam Okafor, Ann doesn't find Joanne.
            let name = fold(speaker).split(separator: " "), asked = fold(wanted).split(separator: " ")
            guard asked.count <= name.count else { return false }
            return (0...(name.count - asked.count)).contains { Array(name[$0..<$0 + asked.count]) == asked }
        }
    }

    // MARK: Parsing arguments

    /// A point in time: an ISO date or date-time, `today`, `yesterday`, or an age like `7d`, `36h`, `2w`. A bare date
    /// as `until` means the end of that day.
    public static func parseDate(_ text: String, endOfDay: Bool = false, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ start: Date) -> Date { endOfDay ? calendar.date(byAdding: .day, value: 1, to: start)! : start }
        switch value {
        case "now": return now
        case "today": return day(today)
        case "yesterday": return day(calendar.date(byAdding: .day, value: -1, to: today)!)
        default: break
        }
        if let unit = value.last, let amount = Double(value.dropLast().trimmingCharacters(in: .whitespaces)), amount >= 0 {
            let seconds: Double? = switch unit {
            case "h": 3_600
            case "d": 86_400
            case "w": 7 * 86_400
            default: nil
            }
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = timeZone
        dateOnly.dateFormat = "yyyy-MM-dd"
        if value.count == 10, let date = dateOnly.date(from: value) { return day(date) }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        // A date-time without a zone ("2026-11-20T14:00" or "2026-11-20 14:00") is local.
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            dateOnly.dateFormat = format
            if let date = dateOnly.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    /// Seconds into a meeting: `75`, `75s`, `12:30` or `1:02:03`.
    public static func parseOffset(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}

/// What a search asks for: words, any of which may match, and "quoted phrases" that must appear as written.
struct SearchQuery: Sendable {
    var terms: [String] = []
    var phrases: [[String]] = []
    /// The words as typed, for highlighting fuzzy matches.
    var isEmpty: Bool { terms.isEmpty && phrases.isEmpty }

    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "is", "it", "was", "we", "i",
                                         "you", "they", "he", "she", "that", "this", "with", "about", "did", "do", "what", "when", "who",
                                         "be", "are", "were", "so", "if", "as", "by", "from", "any", "all", "say", "said", "talk", "talked"]

    init(_ text: String) {
        var rest = ""
        var phrase = ""
        var inQuote = false
        for character in text {
            if character == "\"" || character == "“" || character == "”" {
                if inQuote {
                    // Quoted means as written, even one word: no near-misses, and it must appear.
                    let words = SearchScorer.words(phrase).map(\.normalized)
                    if !words.isEmpty { phrases.append(words) }
                    phrase = ""
                }
                inQuote.toggle()
            } else if inQuote {
                phrase.append(character)
            } else {
                rest.append(character)
            }
        }
        rest += " " + phrase
        let words = SearchScorer.words(rest).map(\.normalized)
        let meaningful = words.filter { !Self.stopWords.contains($0) }
        for word in (meaningful.isEmpty ? words : meaningful) where !terms.contains(word) { terms.append(word) }
    }
}

/// Ranks passages for a query with BM25, counting near-misses: speech recognition writes "Kestral" for "Kestrel", so a
/// word one or two letters off still matches, worth less than the word itself.
struct SearchScorer: Sendable {
    let query: SearchQuery
    let fuzzy: Bool

    struct Word: Sendable {
        var normalized: String
        var stem: String
        var range: Range<String.Index>
    }

    struct Hit: Sendable {
        var document: Int
        var score: Double
        /// Normalized words that matched, for highlighting.
        var matched: Set<String>
        /// The quoted phrases, which the excerpt is centred on.
        var phrases: [[String]] = []

        func ranges(in text: String) -> [Range<String.Index>] {
            SearchScorer.words(text).filter { matched.contains($0.normalized) }.map(\.range)
        }

        /// Where the excerpt should start from: the first quoted phrase as it appears, else the first matched word.
        func anchor(in text: String) -> String.Index? {
            let words = SearchScorer.words(text)
            let normalized = words.map(\.normalized)
            let starts = phrases.compactMap { phrase -> Int? in
                guard !phrase.isEmpty, normalized.count >= phrase.count else { return nil }
                return (0...(normalized.count - phrase.count)).first { Array(normalized[$0..<$0 + phrase.count]) == phrase }
            }
            if let first = starts.min() { return words[first].range.lowerBound }
            return words.first { matched.contains($0.normalized) }?.range.lowerBound
        }
    }

    static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { substring, range, _, _ in
            guard let substring else { return }
            let normalized = normalize(substring)
            guard !normalized.isEmpty else { return }
            words.append(Word(normalized: normalized, stem: stem(normalized), range: range))
        }
        return words
    }

    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// A light English stemmer: enough that "deploys", "deployed" and "deploying" meet.
    static func stem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy(\.isLetter) else { return word }
        for (suffix, replacement, minimum) in [("ies", "y", 5), ("ing", "", 6), ("ed", "", 5), ("es", "", 5), ("s", "", 4)] {
            if word.hasSuffix(suffix), word.count >= minimum, !(suffix == "s" && word.hasSuffix("ss")) {
                return String(word.dropLast(suffix.count)) + replacement
            }
        }
        return word
    }

    /// How well a passage word matches a query word: 1 for the word or its stem, less for a near-miss.
    func weight(_ term: String, _ word: Word) -> Double {
        let termStem = Self.stem(term)
        if word.normalized == term || word.stem == termStem { return 1 }
        guard fuzzy, term.count >= 4, !term.contains(where: \.isNumber) else { return 0 }
        let allowed = term.count >= 8 ? 2 : 1
        guard abs(word.normalized.count - term.count) <= allowed else { return 0 }
        // "plans" for "plan", never "planetary".
        if word.normalized.count > term.count, word.normalized.hasPrefix(term) { return 0.8 }
        return Self.distance(word.stem, termStem, limit: allowed) <= allowed ? 0.6 : 0
    }

    func rank(_ texts: [String]) -> [Hit] { rank(texts.map(Self.words)) }

    func rank(_ documents: [[Word]]) -> [Hit] {
        guard !documents.isEmpty else { return [] }
        let averageLength = max(1, Double(documents.reduce(0) { $0 + $1.count }) / Double(documents.count))
        // Word → weight per term, worked out once per distinct word.
        var weights: [String: [Double]] = [:]
        func termWeights(_ word: Word) -> [Double] {
            if let known = weights[word.normalized] { return known }
            let found = query.terms.map { weight($0, word) }
            weights[word.normalized] = found
            return found
        }
        var frequencies: [[Double]] = []
        var documentFrequency = [Double](repeating: 0, count: query.terms.count)
        for words in documents {
            var counts = [Double](repeating: 0, count: query.terms.count)
            for word in words {
                for (index, value) in termWeights(word).enumerated() where value > 0 { counts[index] += value }
            }
            for index in counts.indices where counts[index] > 0 { documentFrequency[index] += 1 }
            frequencies.append(counts)
        }
        let total = Double(documents.count)
        var hits: [Hit] = []
        for (index, words) in documents.enumerated() {
            var score = 0.0
            var matchedTerms = 0
            for term in query.terms.indices where frequencies[index][term] > 0 {
                let tf = frequencies[index][term]
                let idf = log(1 + (total - documentFrequency[term] + 0.5) / (documentFrequency[term] + 0.5))
                score += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(words.count) / averageLength))
                matchedTerms += 1
            }
            var phraseCount = 0
            for phrase in query.phrases where Self.contains(words.map(\.normalized), phrase) {
                phraseCount += 1
                score += 3 * Double(phrase.count)
            }
            let parts = query.terms.count + query.phrases.count
            let found = matchedTerms + phraseCount
            // Every quoted phrase must appear.
            guard found > 0, phraseCount == query.phrases.count else { continue }
            score *= pow(Double(found) / Double(parts), 2)
            var matched = Set<String>()
            for word in words where termWeights(word).contains(where: { $0 > 0 }) { matched.insert(word.normalized) }
            for phrase in query.phrases { matched.formUnion(phrase) }
            hits.append(Hit(document: index, score: score, matched: matched, phrases: query.phrases))
        }
        return hits.sorted { ($0.score, -$0.document) > ($1.score, -$1.document) }
    }

    static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase { return true }
        return false
    }

    /// Edit distance with transpositions, giving up past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var best = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = min(current[j], previous2[j - 2] + 1) }
                best = min(best, current[j])
            }
            if best > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
