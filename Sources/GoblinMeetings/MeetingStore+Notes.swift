import Foundation

/// Notes through the store, by meeting ID. Writing waits on the model for up to a few minutes; the store stays free
/// for other meetings meanwhile.
extension MeetingStore {
    public func notes(_ id: String) throws -> MeetingNotes? {
        MeetingNotesFile.read(try directory(for: id))
    }

    /// Whether the meeting was processed again after its notes were written.
    public func notesAreStale(_ id: String) throws -> Bool {
        let directory = try directory(for: id)
        guard let notes = MeetingNotesFile.read(directory) else { return false }
        return MeetingNotesFile.isStale(notes, directory: directory)
    }

    /// The model is awaited off the actor's work; saving happens on it in one go, so a Fix or Undo made meanwhile is
    /// read and kept rather than overwritten. `proceed` is asked right before the transcript is sent.
    @discardableResult
    public func writeNotes(_ id: String, settings: NotesSettings, vocabulary: [String], runner: @escaping NotesModelRunner,
                           proceed: @escaping @Sendable () async -> Bool = { true },
                           log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingNotes {
        let directory = try directory(for: id)
        let draft = try await MeetingNotesWriter.draft(directory: directory, settings: settings, vocabulary: vocabulary, runner: runner,
                                                       proceed: proceed, log: log)
        return try MeetingNotesWriter.commit(draft, directory: directory)
    }

    public func dismissFix(_ id: String, heard: String) throws {
        try MeetingNotesWriter.dismissFix(heard, directory: try directory(for: id))
    }

    public func applyFix(_ id: String, heard: String) throws {
        try MeetingNotesWriter.applyFix(heard, directory: try directory(for: id))
    }

    public func applyFixes(_ id: String, heard: [String]) throws {
        try MeetingNotesWriter.applyFixes(heard, directory: try directory(for: id))
    }

    public func suggestFixes(_ id: String, heard: [String]) throws {
        try MeetingNotesWriter.suggestFixes(heard, directory: try directory(for: id))
    }

    /// Earlier versions of the notes, newest first, each with the id that restores it.
    public func earlierNotes(_ id: String) throws -> [MeetingNotesHistory.Version] {
        MeetingNotesHistory.read(try directory(for: id))
    }

    /// Back to an earlier version of the notes, by its id; the current ones are kept in its place.
    public func restoreNotes(_ id: String, version: String) throws {
        try MeetingNotesWriter.restore(version, directory: try directory(for: id))
    }

    public func setActionItemDone(_ id: String, item index: Int, task: String, done: Bool) throws {
        try MeetingNotesWriter.setDone(done, item: index, task: task, directory: try directory(for: id))
    }

    /// The person's own fix of a misheard word: every place it was heard takes the new spelling, notes included.
    /// Returns the entry it replaced, for Undo.
    @discardableResult
    public func correctSpelling(_ id: String, heard: String, meant: String) throws -> MeetingNotes.SpellingFix? {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        let previous = MeetingCorrections.entry(heard: heard, in: directory)
        try MeetingCorrections.set(heard: heard, meant: meant, in: directory)
        try MeetingPostProcessor.render(directory: directory)
        return previous
    }

    /// Removes the person's correction of `heard` altogether, as if it was never made: Undo of a first correction.
    public func removeCorrection(_ id: String, heard: String) throws {
        try restoreCorrection(id, heard: heard, to: nil)
    }

    /// Puts back what a correction of `heard` replaced (nil: nothing), for Undo.
    public func restoreCorrection(_ id: String, heard: String, to previous: MeetingNotes.SpellingFix?) throws {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        try MeetingCorrections.replace(heard: heard, with: previous, in: directory)
        try MeetingPostProcessor.render(directory: directory)
    }

    /// Put Back: the word reads as heard. The correction stays, turned down, so it still keeps the notes' own fix
    /// and the Dictionary from respelling the word again.
    public func putBackCorrection(_ id: String, heard: String) throws {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        guard var entry = MeetingCorrections.entry(heard: heard, in: directory) else { return }
        entry.dismissed = true
        try MeetingCorrections.replace(heard: heard, with: entry, in: directory)
        try MeetingPostProcessor.render(directory: directory)
    }

    /// The person's corrections, as kept.
    public func corrections(_ id: String) throws -> [MeetingNotes.SpellingFix] {
        MeetingCorrections.read(try directory(for: id))
    }

    public func deleteNotes(_ id: String) throws {
        let directory = try directory(for: id)
        try MeetingNotesFile.delete(in: directory)
        try MeetingNotesHistory.delete(directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path) {
            try MeetingPostProcessor.render(directory: directory)
        }
    }
}
