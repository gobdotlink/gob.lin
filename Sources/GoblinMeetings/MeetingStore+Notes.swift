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

    public func deleteNotes(_ id: String) throws {
        let directory = try directory(for: id)
        try MeetingNotesFile.delete(in: directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path) {
            try MeetingPostProcessor.render(directory: directory)
        }
    }
}
