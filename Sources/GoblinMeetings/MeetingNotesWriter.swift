import Foundation

/// What to write notes with: the tool, model, thinking level, template and style.
public struct NotesSettings: Codable, Sendable, Equatable {
    public var tool: NotesTool
    /// Nil: the tool's default model.
    public var model: String?
    /// Nil: the model's default thinking level.
    public var effort: String?
    public var template: NotesTemplate
    public var style: NotesStyle
    /// A one-off instruction for this write only ("Make it shorter"), followed on top of the template.
    public var ask: String? = nil

    public init(tool: NotesTool, model: String? = nil, effort: String? = nil, template: NotesTemplate = .auto, style: NotesStyle = .concise,
                ask: String? = nil) {
        self.tool = tool
        self.model = model
        self.effort = effort
        self.template = template
        self.style = style
        self.ask = ask
    }
}

/// The models gob.lin picks first for notes, best first. Public grounding benchmarks (FACTS Grounding v2, Vectara's
/// hallucination leaderboard) put the GPT-6 family ahead of Claude 5.5 at sticking to a source. Blind cross-judging
/// (GPT-6.2-Astra and Claude Opus) of ten setups on three real calls put GPT-6.2-Sol at medium first: the most
/// faithful, owners right, few omissions. GPT-6.1 Terra was nearly as faithful at a third of the time. Among Claude
/// models, Fable at low thinking was the most faithful and covered the most, ahead of Opus; one request per call uses
/// little of a plan. The first one installed, signed in and offered wins.
public enum NotesModelRanking {
    public struct Choice: Sendable, Equatable {
        public var tool: NotesTool
        public var model: String
        public var effort: String
    }

    public static let preferred: [Choice] = [
        Choice(tool: .codex, model: "gpt-6.2-sol", effort: "medium"),
        Choice(tool: .codex, model: "gpt-6.1-terra", effort: "high"),
        Choice(tool: .codex, model: "gpt-6.1-sol", effort: "medium"),
        Choice(tool: .codex, model: "gpt-6-sol", effort: "medium"),
        Choice(tool: .claudeCode, model: "fable", effort: "low"),
        Choice(tool: .claudeCode, model: "opus", effort: "medium"),
        Choice(tool: .claudeCode, model: "sonnet", effort: "high"),
        Choice(tool: .codex, model: "gpt-6.2-astra", effort: "low"),
        Choice(tool: .codex, model: "gpt-6-luna", effort: "medium"),
        Choice(tool: .claudeCode, model: "haiku", effort: "medium"),
    ]

    /// The best choice among the models each signed-in tool offers; for a tool whose models aren't in the ranking
    /// (a newer Codex), its own default model at its default thinking level.
    public static func best(available: [NotesTool: [NotesModelOption]]) -> NotesSettings? {
        for choice in preferred {
            guard let models = available[choice.tool], let model = models.first(where: { $0.id == choice.model }) else { continue }
            let effort = model.efforts.isEmpty || model.efforts.contains(choice.effort) ? choice.effort : model.defaultEffort
            return NotesSettings(tool: choice.tool, model: model.id, effort: effort)
        }
        for tool in NotesTool.allCases {
            guard let models = available[tool], let model = models.first(where: \.isDefault) ?? models.first else { continue }
            return NotesSettings(tool: tool, model: model.id, effort: model.defaultEffort)
        }
        return nil
    }
}

/// Writes a meeting's notes: builds the input from its transcript, asks the model, checks the answer, keeps the
/// fixes the person already settled, and writes notes.json and notes.md. Then the transcript is rendered again so the
/// fixes and the new title show.
public enum MeetingNotesWriter {
    /// `vocabulary` is the dictionary's spellings, all of them: a call can be about anything.
    @discardableResult
    public static func write(directory: URL, settings: NotesSettings, vocabulary: [String], runner: NotesModelRunner,
                             proceed: @escaping @Sendable () async -> Bool = { true },
                             log: @Sendable (String) -> Void = { _ in }) async throws -> MeetingNotes {
        let notes = try await draft(directory: directory, settings: settings, vocabulary: vocabulary, runner: runner,
                                    proceed: proceed, log: log)
        return try commit(notes, directory: directory)
    }

    /// Saves a draft: the fixes the person already settled carried over, notes.json and notes.md written, the
    /// transcript rendered. No awaits, so on the store's actor nothing else edits the notes meanwhile. Returns the
    /// notes as shown, fixes applied; notes.json keeps the model's text.
    @discardableResult
    public static func commit(_ draft: MeetingNotes, directory: URL) throws -> MeetingNotes {
        try commit(draft, directory: directory, prune: true)
    }

    /// `prune: false` leaves the history at one over its limit, for a restore that takes its own copy out first.
    static func commit(_ draft: MeetingNotes, directory: URL, prune: Bool) throws -> MeetingNotes {
        let notes = withSavedDecisions(draft, directory: directory)
        try MeetingNotesHistory.keep(directory)
        try MeetingNotesFile.write(notes, to: directory)
        if prune { MeetingNotesHistory.prune(directory) }
        try MeetingPostProcessor.render(directory: directory)
        return MeetingNotesFixer.apply(MeetingNotesFile.allFixes(directory), to: notes)
    }

    /// A draft with the meeting's saved spelling decisions carried in (a word put back stays put back), for showing
    /// or exporting it without saving it.
    public static func withSavedDecisions(_ draft: MeetingNotes, directory: URL) -> MeetingNotes {
        var notes = draft
        notes.fixes = carry(MeetingNotesFile.stored(directory)?.fixes ?? [], into: notes.fixes)
        return notes
    }

    /// The notes without writing them anywhere, for comparing models.
    public static func draft(directory: URL, settings: NotesSettings, vocabulary: [String], runner: NotesModelRunner,
                             proceed: @escaping @Sendable () async -> Bool = { true },
                             log: @Sendable (String) -> Void = { _ in }) async throws -> MeetingNotes {
        var request = try prepare(directory: directory, settings: settings, vocabulary: vocabulary)
        request.model.proceed = proceed
        let started = Date()
        log("writing notes with \(settings.tool.title) \(settings.model ?? "default") \(settings.effort ?? "") (\(request.input.characters) characters)")
        let answer = try await runner(request.model)
        let seconds = Date().timeIntervalSince(started)
        var provenance = MeetingNotes.Provenance(tool: settings.tool, model: settings.model, effort: settings.effort,
                                                 template: settings.template, style: settings.style, createdAt: Date(), seconds: seconds,
                                                 transcriptHash: request.sourceHash, promptVersion: MeetingNotesPrompt.version,
                                                 names: request.names)
        provenance.ask = MeetingNotesPrompt.cleanAsk(settings.ask)
        let notes = try MeetingNotesPrompt.notes(from: answer, input: request.input, known: request.known, provenance: provenance)
        log("notes in \(Int(seconds)) s: \(notes.decisions.count) decisions, \(notes.actionItems.count) action items, "
            + "\(notes.sections.count) sections, \(notes.fixes.filter(\.isActive).count) fixes, \(notes.fixes.filter { $0.kind == .suggested }.count) suggestions")
        return notes
    }

    public struct Prepared: Sendable {
        public var model: NotesModelRequest
        public var input: MeetingNotesPrompt.Input
        public var known: Set<String>
        /// `MeetingNotesFile.sourceHash` of what the input was built from, taken before the model is asked.
        public var sourceHash: String
        /// Each voice's label → its name now.
        public var names: [String: String]
    }

    /// The request without sending it, for `goblin meetings notes --print-prompt` and tests.
    public static func prepare(directory: URL, settings: NotesSettings, vocabulary: [String]) throws -> Prepared {
        // attributed.json keeps each voice's label on every turn; transcript.json loses it where two voices given the
        // same name were joined, and the notes' speaker tokens need it to follow later renames. The hash is of the
        // same bytes, so notes are stale exactly when processing changed what they were written from.
        try? MeetingPostProcessor.finishRelabel(directory)
        // A meeting processed before attributed.json existed gets one now, so the hash below is of the file later
        // checks read.
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.attributedFile).path),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path) {
            try? MeetingPostProcessor.render(directory: directory)
        }
        guard let data = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
                ?? (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile))),
              let attributed = try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: data), !attributed.isEmpty else {
            throw MeetingNotesError.noTranscript
        }
        let sourceHash = MeetingNotesFile.hash(data)
        let names = MeetingPostProcessor.speakerNames(directory)
        let named = attributed.map { turn in
            var turn = turn
            let label = turn.label ?? turn.speaker
            turn.label = label
            turn.speaker = names[label] ?? label
            return turn
        }
        // The current fixes, as the transcript shows them; turns join only within one voice.
        // Joined first, then fixed, as the transcript is rendered: a corrected phrase can span two lines.
        let turns = MeetingNotesFixer.apply(MeetingNotesFile.allFixes(directory),
                                            to: MeetingPostProcessor.merge(named, by: { $0.label ?? $0.speaker }))
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        let participants = MeetingParticipants.read(directory)
        let recorded = session?.title ?? MeetingStorage.title(fromFolderName: directory.lastPathComponent)
        let typed = MeetingMetadata.read(directory).title
        let title = typed ?? recorded
        let input = MeetingNotesPrompt.input(turns: turns, recordedTitle: title, titleIsGeneric: typed == nil && MeetingTitles.isGeneric(recorded),
                                             session: session, participants: participants, marks: MeetingMark.read(directory),
                                             typedNotes: MeetingTypedNotes.read(from: directory), vocabulary: vocabulary)
        guard input.characters >= MeetingNotesPrompt.minimumCharacters else { throw MeetingNotesError.tooShort }
        let known = MeetingNotesPrompt.knownNames(vocabulary: vocabulary, participants: participants,
                                                  speakers: turns.map(\.speaker).filter { !MeetingTimeline.isUnnamed($0) }, title: title)
        let instructions = MeetingNotesPrompt.instructions(template: settings.template, style: settings.style,
                                                           transcriptCharacters: input.characters, ask: settings.ask)
        return Prepared(model: NotesModelRequest(instructions: instructions, input: input.text, model: settings.model, effort: settings.effort),
                        input: input, known: known, sourceHash: sourceHash,
                        names: Dictionary(named.map { ($0.label ?? $0.speaker, $0.speaker) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The new answer's fixes plus the ones from before it: an applied fix has already changed the transcript the
    /// model read, so it can't find the heard word again, yet dropping it would put the mistake back. What the person
    /// decided (put a word back, accepted or turned down a suggestion) stays decided.
    static func carry(_ previous: [MeetingNotes.SpellingFix], into fresh: [MeetingNotes.SpellingFix]) -> [MeetingNotes.SpellingFix] {
        var result = fresh
        for old in previous {
            if let index = result.firstIndex(where: { $0.heard.caseInsensitiveCompare(old.heard) == .orderedSame }) {
                if old.dismissed || old.kind == .applied { result[index].kind = old.kind; result[index].dismissed = old.dismissed; result[index].meant = old.meant }
            } else if old.isActive || old.dismissed {
                result.append(old)
            }
        }
        return result
    }

    // MARK: Person's changes

    /// Swaps the notes for an earlier version, by its id: the current notes take its place in the history, so going
    /// back can itself be undone. Every spelling decision stands as it is now, a word asked about again included.
    @discardableResult
    public static func restore(_ id: String, directory: URL) throws -> MeetingNotes {
        guard let url = MeetingNotesHistory.url(of: id, in: directory) else { throw MeetingStoreError.noEarlierNotes }
        var earlier = try JSONDecoder.meeting.decode(MeetingNotes.self, from: Data(contentsOf: url))
        let current = MeetingNotesFile.stored(directory)?.fixes ?? []
        for index in earlier.fixes.indices {
            guard let now = current.first(where: { $0.heard.caseInsensitiveCompare(earlier.fixes[index].heard) == .orderedSame }) else { continue }
            earlier.fixes[index].kind = now.kind
            earlier.fixes[index].dismissed = now.dismissed
            earlier.fixes[index].meant = now.meant
        }
        let restored = try commit(earlier, directory: directory, prune: false)
        // Only once the restored notes are saved does their copy in the history go, and only then is the history
        // trimmed, so a full history loses nothing but that copy.
        try? FileManager.default.removeItem(at: url)
        MeetingNotesHistory.prune(directory)
        return restored
    }

    /// Ticks an action item off, or back on. `shown` is the item as the page shows it: when the notes changed
    /// meanwhile, the one item with the same task, owner and time is ticked, and none when there isn't exactly one.
    public static func setDone(_ done: Bool, item index: Int, shown item: MeetingNotes.ActionItem, directory: URL) throws {
        guard var notes = MeetingNotesFile.stored(directory) else { return }
        let shown = MeetingNotesFixer.apply(MeetingNotesFile.allFixes(directory), to: notes).actionItems
        func same(_ other: MeetingNotes.ActionItem) -> Bool { other.task == item.task && other.owner == item.owner && other.at == item.at }
        let matches = shown.indices.filter { same(shown[$0]) }
        let match = shown.indices.contains(index) && same(shown[index]) ? index : matches.count == 1 ? matches[0] : nil
        guard let match else { return }
        notes.actionItems[match].done = done ? true : nil
        try MeetingNotesFile.write(notes, to: directory)
    }

    /// Puts a fix's heard word back, or turns a suggestion down.
    public static func dismissFix(_ heard: String, directory: URL) throws {
        try updateFix(heard, directory: directory) { $0.dismissed = true }
    }

    /// Applies a suggestion, or puts a dismissed fix back in.
    public static func applyFix(_ heard: String, directory: URL) throws {
        try updateFix(heard, directory: directory) { fix in
            fix.kind = .applied
            fix.dismissed = false
        }
    }

    /// Applies several suggestions at once (Fix All), respelling the transcript once. Only words still waiting as
    /// suggestions change: one turned down or fixed meanwhile keeps that decision.
    public static func applyFixes(_ heard: [String], directory: URL) throws {
        try updateFixes(Set(heard), directory: directory, where: { $0.kind == .suggested && !$0.dismissed }) { fix in
            fix.kind = .applied
            fix.dismissed = false
        }
    }

    /// Turns applied fixes back into suggestions waiting for the person: Undo after Fix All. Only fixes still applied
    /// change: a word put back meanwhile stays put back.
    public static func suggestFixes(_ heard: [String], directory: URL) throws {
        try updateFixes(Set(heard), directory: directory, where: \.isActive) { fix in
            fix.kind = .suggested
            fix.dismissed = false
        }
    }

    static func updateFix(_ heard: String, directory: URL, _ change: (inout MeetingNotes.SpellingFix) -> Void) throws {
        try updateFixes([heard], directory: directory, change)
    }

    static func updateFixes(_ heard: Set<String>, directory: URL, where eligible: (MeetingNotes.SpellingFix) -> Bool = { _ in true },
                            _ change: (inout MeetingNotes.SpellingFix) -> Void) throws {
        // Only the fixes change; the notes' text is respelled from the model's own each time it's read.
        guard var notes = MeetingNotesFile.stored(directory) else { return }
        let indices = notes.fixes.indices.filter { heard.contains(notes.fixes[$0].heard) && eligible(notes.fixes[$0]) }
        guard !indices.isEmpty else { return }
        for index in indices { change(&notes.fixes[index]) }
        try MeetingNotesFile.write(notes, to: directory)
        try MeetingPostProcessor.render(directory: directory)
    }
}
