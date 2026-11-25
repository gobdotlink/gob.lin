import Foundation

public enum MeetingState: String, Codable, Sendable {
    /// Capture is running (this process said so, or the folder's audio was written in the last few seconds).
    case recording
    /// Capture stopped without finishing (a crash or force quit); `repairUnfinished` recovers it.
    case interrupted
    /// Finished recording, transcript not written yet, or a processing run was cut short (a quit or crash) and
    /// `repairUnfinished` runs it again.
    case processing
    case ready
    /// Post-processing threw, or transcript.json can't be read; `failure` says why and `process` can retry.
    case failed
}

/// One row of the meetings list.
public struct MeetingSummary: Codable, Sendable, Identifiable, Hashable {
    /// The folder name.
    public var id: String
    public var title: String
    /// The call app or audio source the recording was started for ("Zoom", "simulation").
    public var source: String
    /// The system-audio target's description.
    public var target: String
    public var startedAt: Date
    public var endedAt: Date?
    public var duration: TimeInterval
    public var participants: [String]
    /// Displayed speaker names, most talk first.
    public var speakers: [String]
    public var state: MeetingState
    /// The recording was cut short and recovered.
    public var wasInterrupted: Bool
    public var hasAudio: Bool
    public var starred: Bool
    public var failure: String?
    public var directory: URL
    /// Why recording stopped ("stopped", "call ended", "sleep", "lid closed", "quit"), from session.json.
    public var stopReason: String? = nil
    /// A call, or a conversation in the room recorded from the mic alone. Sessions from before in-person
    /// recording existed are calls.
    public var kind: MeetingKind = .call
}

public struct MeetingDetail: Codable, Sendable {
    public var summary: MeetingSummary
    public var turns: [TranscriptTurn]
    public var participants: MeetingParticipants
    public var microphoneAudio: URL?
    public var systemAudio: URL?
    public var report: PostProcessReport?
    /// speakers.json: diarized label → name.
    public var speakerNames: [String: String]
    /// marks.jsonl, oldest first.
    public var marks: [MeetingMark] = []
    /// typed-notes.md: what the person typed in the Sidekick during the call, or nil when nothing.
    public var typedNotes: String? = nil
    /// Shown names that Remember voices filled in from People, rather than a person.
    public var namedFromVoice: Set<String> = []
    /// Shown name of an unnamed voice → who it sounds like, closest first: someone in People, or another voice of this
    /// meeting the diarizer may have split off.
    public var voiceSuggestions: [String: [SpeakerSuggestion]] = [:]
}

public enum MeetingStoreError: Error, LocalizedError, Equatable {
    case notFound(String)
    case busy(String)
    case noTranscript(String)
    case speakerNotFound(String)
    case destinationNotEmpty(String)
    /// Remember voices was turned off, but these voiceprints couldn't be deleted (meeting titles, or "People").
    case voicesNotForgotten([String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "No meeting named \(id)."
        case .busy(let id): "\(id) is still recording or processing."
        case .noTranscript(let id): "\(id) has no transcript yet."
        case .speakerNotFound(let name): "No speaker called \(name) in this meeting."
        case .destinationNotEmpty(let path): "\(path) already exists and is not empty."
        case .voicesNotForgotten(let places): "Some voiceprints couldn't be deleted: \(places.joined(separator: ", "))."
        }
    }
}

/// What a person changed after recording, plus what the store learned. Kept apart from session.json,
/// which the recorder owns and rewrites when it stops.
struct MeetingMetadata: Codable, Sendable, Equatable {
    var title: String?
    var starred = false
    var interrupted = false
    var failure: String?
    var audioDeletedAt: Date?
    /// Set when a processing run starts and cleared when it ends, so a run the app never finished is run again.
    var pending = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        interrupted = try container.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        audioDeletedAt = try container.decodeIfPresent(Date.self, forKey: .audioDeletedAt)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }

    static func read(_ directory: URL) -> MeetingMetadata {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.metadataFile)) else { return MeetingMetadata() }
        return (try? JSONDecoder.meeting.decode(MeetingMetadata.self, from: data)) ?? MeetingMetadata()
    }

    func write(_ directory: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: directory.appendingPathComponent(MeetingStorage.metadataFile), options: .atomic)
    }
}

/// The meetings on disk: list, detail, edits, retention, crash repair and fixture export.
/// All file access goes through this actor; recording itself is `MeetingSession`'s.
///
/// The app should call `setRecording(id, true)` when a session starts and `process(id)` after it
/// stops (which clears the flag), and `repairUnfinished()` then `applyRetention()` once at launch.
public actor MeetingStore {
    /// Audio is deleted this long after a meeting ends unless it is starred or `MeetingStorage.keepAudioFlag` is set.
    public static let audioRetention: TimeInterval = 7 * 86_400
    /// A folder without an end time whose files changed this recently is taken to be recording in another process.
    static let liveWriteWindow: TimeInterval = 10

    public nonisolated let root: URL
    private let options: MeetingPostProcessOptions
    private var recording: Set<String> = []
    private var processing: Set<String> = []
    /// Whether each transcript.json decodes, keyed by path and remembered until the file changes.
    private var transcriptChecks: [String: (stamp: TranscriptStamp, readable: Bool)] = [:]

    struct TranscriptStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    /// What a meeting whose transcript.json won't decode says.
    static let unreadableTranscript = "The transcript file is damaged. Try Again rebuilds it."

    public init(root: URL = MeetingStorage.root, options: MeetingPostProcessOptions = MeetingPostProcessOptions()) {
        self.root = root.standardizedFileURL
        self.options = options
    }

    // MARK: Reading

    /// Every meeting folder under the root, newest first.
    public func list() -> [MeetingSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, Self.isMeetingFolder(folder) else { return nil }
            return summary(at: folder)
        }
        .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }

    public func summary(_ id: String) throws -> MeetingSummary {
        summary(at: try directory(for: id))
    }

    public func detail(_ id: String) throws -> MeetingDetail {
        let directory = try directory(for: id)
        let summary = summary(at: directory)
        let turns = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)))
            .flatMap { try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: $0) } ?? []
        let report = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.reportFile)))
            .flatMap { try? JSONDecoder.meeting.decode(PostProcessReport.self, from: $0) }
        func audio(_ track: MeetingTrack) -> URL? {
            let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
            return Self.audioBytes(url) > 44 ? url : nil
        }
        let names = MeetingPostProcessor.speakerNames(directory)
        let voices = MeetingVoices.read(directory)
        let people = options.voices?.people.people() ?? []
        return MeetingDetail(summary: summary, turns: turns, participants: MeetingParticipants.read(directory),
                             microphoneAudio: audio(.microphone), systemAudio: audio(.system), report: report,
                             speakerNames: names, marks: MeetingMark.read(directory), typedNotes: MeetingTypedNotes.read(from: directory),
                             namedFromVoice: voices.map { VoiceSuggestions.namedFromVoice($0, names: names) } ?? [],
                             voiceSuggestions: voices.map { VoiceSuggestions.suggestions($0, names: names, people: people) } ?? [:])
    }

    /// The meeting's folder. IDs are folder names; anything that could leave the root is rejected.
    public func directory(for id: String) throws -> URL {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\") else { throw MeetingStoreError.notFound(id) }
        let url = root.appendingPathComponent(id, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeetingStoreError.notFound(id)
        }
        return url
    }

    /// The meeting as Markdown with YAML front matter, for a notes vault.
    public func markdown(_ id: String) throws -> String {
        MeetingMarkdown.export(try detail(id))
    }

    // MARK: Editing

    /// Marks a meeting as being recorded by this process, so nothing repairs, processes or deletes it.
    public func setRecording(_ id: String, _ isRecording: Bool) {
        if isRecording { recording.insert(id) } else { recording.remove(id) }
    }

    /// Sets the displayed title; an empty title goes back to the recorded one. The folder keeps its name.
    public func rename(_ id: String, title: String) throws {
        let directory = try directory(for: id)
        var metadata = MeetingMetadata.read(directory)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        try metadata.write(directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path) {
            try MeetingPostProcessor.render(directory: directory)
        }
    }

    /// Renames every voice currently shown as `currentName`. Renaming to a name another voice already
    /// has merges them; an empty name restores the diarized labels. Re-renders the transcript without
    /// re-running diarization.
    @discardableResult
    public func renameSpeaker(_ id: String, from currentName: String, to newName: String) throws -> [TranscriptTurn] {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.attributedFile).path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path) else {
            throw MeetingStoreError.noTranscript(id)
        }
        // Writes attributed.json from an older transcript if needed, so labels are known.
        try MeetingPostProcessor.render(directory: directory)
        let base = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                                  from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
        var names = MeetingPostProcessor.speakerNames(directory)
        let labels = Set(base.compactMap(\.label)).filter { (names[$0] ?? $0) == currentName }
        guard !labels.isEmpty else { throw MeetingStoreError.speakerNotFound(currentName) }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in labels { names[label] = name.isEmpty || name == label ? nil : name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(names).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile), options: .atomic)
        Self.forgetClearedNames(directory)
        // People follows the names as soon as they're saved, before anything derived from them can fail.
        return try learnThenRender(directory)
    }

    /// speakers.json as it stands: diarized label → name. Pair with `setSpeakerNames` to undo a rename or merge.
    public func speakerNames(_ id: String) throws -> [String: String] {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        // Names a cut-off run left in relabel.json belong to the attribution there, so they're the current ones.
        try MeetingPostProcessor.finishRelabel(directory)
        return MeetingPostProcessor.speakerNames(directory)
    }

    /// Replaces every speaker name at once and re-renders the transcript; the undo for `renameSpeaker`.
    @discardableResult
    public func setSpeakerNames(_ id: String, _ names: [String: String]) throws -> [TranscriptTurn] {
        let directory = try directory(for: id)
        guard !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        let kept = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && $0.key != $0.value }
        // First, so a pending relabel can't overwrite these names afterwards.
        try MeetingPostProcessor.finishRelabel(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(kept).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile), options: .atomic)
        Self.forgetClearedNames(directory)
        return try learnThenRender(directory)
    }

    // MARK: Voices

    /// People learns the meeting's names as they now stand, from its voiceprints; nothing without Remember voices.
    /// After names are saved: People follows them first, then the transcript. The transcript is written even when People
    /// can't be (a damaged people.json), so names and transcript always agree; People's failure is still reported.
    private func learnThenRender(_ directory: URL) throws -> [TranscriptTurn] {
        var learning: (any Error)?
        do { try relearn(directory) } catch { learning = error }
        let turns = try MeetingPostProcessor.render(directory: directory)
        if let learning { throw learning }
        return turns
    }

    private func relearn(_ directory: URL) throws {
        guard let voices = options.voices, voices.enabled(), let saved = MeetingVoices.read(directory) else { return }
        let session = Self.session(directory)
        let id = directory.lastPathComponent
        try voices.people.learn(meetingID: id, title: MeetingMetadata.read(directory).title ?? session?.title ?? MeetingStorage.title(fromFolderName: id),
                                 startedAt: session?.startedAt ?? Date(), inPerson: session?.kind == .inPerson, voices: saved.voices,
                                 names: MeetingPostProcessor.speakerNames(directory), me: MeetingParticipants.read(directory).me)
    }

    /// Remember voices just turned on: voiceprints for every finished meeting that still has its audio, People learning
    /// from the voices already named, then names and suggestions for the rest. Returns how many voices it named.
    @discardableResult
    public func learnVoices(log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Int {
        guard let voiceOptions = options.voices else { return 0 }
        let meetings = list().filter { $0.state == .ready && !recording.contains($0.id) && !processing.contains($0.id) }
        // Named voices first, oldest meeting first, so every meeting can be matched against all of them.
        var prepared: [(MeetingSummary, MeetingVoices, TranscriptStamp)] = []
        for meeting in meetings.reversed() {
            try Task.checkCancellation()
            let directory = meeting.directory
            // A meeting processed before attributed.json existed is migrated first; without attribution there are no
            // voices to make, and an empty voices.json would stand in for them from then on.
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.attributedFile).path) {
                guard (try? MeetingPostProcessor.render(directory: directory)) != nil,
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.attributedFile).path) else { continue }
            }
            // Voiceprints belong to the attribution they were made from; one that changes meanwhile (the CLI processing
            // the meeting again) makes them stale, and then the meeting is left for its own processing.
            let attribution = Self.attributionStamp(directory)
            var saved = MeetingVoices.read(directory)
            if saved == nil, meeting.hasAudio {
                let voices: [MeetingVoice]
                do {
                    voices = try await VoiceStretches.voices(inMeeting: directory, embed: voiceOptions.embed,
                                                             dictationSpans: options.dictationSpans)
                } catch is DecodingError {
                    // One meeting's damaged attribution only leaves that meeting out; Try Again on it rebuilds it.
                    log("\(meeting.id): its attribution won't read, so its voices were skipped")
                    continue
                }
                // Turned off while that was embedding: keep nothing, and leave the rest to forgetting.
                try Task.checkCancellation()
                guard voiceOptions.enabled() else { return 0 }
                guard isCurrent(meeting.id, attribution) else { continue }
                saved = MeetingVoices(voices: voices)
                try saved?.write(directory)
            }
            guard let saved else { continue }
            prepared.append((meeting, saved, attribution))
            try voiceOptions.people.learn(meetingID: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                                          inPerson: meeting.kind == .inPerson, voices: saved.voices,
                                          names: MeetingPostProcessor.speakerNames(directory), me: MeetingParticipants.read(directory).me)
        }
        var named = 0
        for (meeting, saved, attribution) in prepared {
            try Task.checkCancellation()
            guard voiceOptions.enabled() else { return named }
            guard isCurrent(meeting.id, attribution) else { continue }
            let directory = meeting.directory
            var names = MeetingPostProcessor.speakerNames(directory)
            let people = voiceOptions.people.people().map { person in
                var person = person
                person.samples.removeAll { $0.meetingID == meeting.id }
                return person
            }
            let open = saved.voices.filter { VoiceMatching.waitsForName($0.label, names: names) }
            let matches = VoiceMatching.bestPerLane(VoiceMatching.match(open, people: people, participants: MeetingParticipants.read(directory),
                                                                        inPerson: meeting.kind == .inPerson), names: names)
            var updated = saved
            // Names given from a voice before keep their mark while the meeting still uses them.
            let standing = saved.matches.filter { label, match in match.named && names[label] == match.name }
            updated.matches = standing.merging(matches) { _, new in new }
            try updated.write(directory)
            let newlyNamed = matches.filter(\.value.named)
            guard !newlyNamed.isEmpty else { continue }
            let before = names
            for (label, match) in newlyNamed {
                MeetingPostProcessor.nameVoice(shownAs: label, match.name, names: &names, before: before, labels: saved.voices.map(\.label))
            }
            try MeetingPostProcessor.writeSpeakerNames(names, to: directory)
            _ = try learnThenRender(directory)
            named += newlyNamed.count
        }
        log("learned voices from \(prepared.count) meetings; named \(named) voices")
        return named
    }

    /// attributed.json's size and modification time: which attribution a meeting's voiceprints were made from.
    static func attributionStamp(_ directory: URL) -> TranscriptStamp {
        let values = try? directory.appendingPathComponent(MeetingStorage.attributedFile)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return TranscriptStamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// The meeting isn't being processed and still has the attribution `stamp` was taken from.
    private func isCurrent(_ id: String, _ stamp: TranscriptStamp) -> Bool {
        guard !processing.contains(id), !recording.contains(id), let directory = try? directory(for: id) else { return false }
        return Self.attributionStamp(directory) == stamp
    }

    /// Whether any voiceprint is on disk: People, or a meeting's voices.json.
    public func hasVoiceprints() -> Bool {
        if let people = options.voices?.people, FileManager.default.fileExists(atPath: people.url.path) { return true }
        return list().contains { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent(MeetingStorage.voicesFile).path) }
    }

    /// Remember voices turned off: every voiceprint goes, from People and from each meeting. Names already given stay.
    public func forgetVoices() throws {
        // Every file is tried even when one fails, so a single stuck folder doesn't leave the rest behind.
        var failures: [String] = []
        for meeting in list() {
            let url = meeting.directory.appendingPathComponent(MeetingStorage.voicesFile)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { failures.append(meeting.title) }
        }
        do { try options.voices?.people.removeAll() } catch { failures.append("People") }
        if !failures.isEmpty { throw MeetingStoreError.voicesNotForgotten(failures) }
    }

    /// Bytes of audio kept across every meeting, for the storage line in Settings.
    public func audioBytes() -> Int {
        list().reduce(0) { total, meeting in
            total + MeetingTrack.allCases.reduce(0) { $0 + Self.audioBytes(meeting.directory.appendingPathComponent(MeetingStorage.audioFile($1))) }
        }
    }

    public func setStarred(_ id: String, _ starred: Bool) throws {
        let directory = try directory(for: id)
        var metadata = MeetingMetadata.read(directory)
        metadata.starred = starred
        try metadata.write(directory)
    }

    public func delete(_ id: String) throws {
        let directory = try directory(for: id)
        try ensureIdle(id, directory)
        // What the meeting taught about voices goes first: once the folder is gone nothing points back to it.
        try options.voices?.people.forget(meetingID: id)
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes both tracks' audio, keeping the transcript and everything else.
    public func deleteAudio(_ id: String) throws {
        let directory = try directory(for: id)
        try ensureIdle(id, directory)
        try deleteAudio(at: directory)
    }

    /// Deletes audio of meetings that ended more than `audioRetention` ago, unless starred or
    /// `keepAudio` (the developer flag) is set. Skips anything recording, processing or unrepaired.
    /// Returns the IDs whose audio went.
    @discardableResult
    public func applyRetention(now: Date = Date(), keepAudio: Bool = MeetingStorage.keepAudioFlag) -> [String] {
        guard !keepAudio else { return [] }
        var deleted: [String] = []
        for meeting in list() where meeting.hasAudio && !meeting.starred
            && [.ready, .failed].contains(meeting.state)
            && now.timeIntervalSince(meeting.endedAt ?? meeting.startedAt) > Self.audioRetention {
            if (try? deleteAudio(at: meeting.directory)) != nil { deleted.append(meeting.id) }
        }
        return deleted
    }

    // MARK: Processing and repair

    /// Runs post-processing (diarization, echo and dictation removal, transcript) and records failure.
    /// `preset` swaps in Nemotron with that preset; nil keeps the store's options.
    @discardableResult
    public func process(_ id: String, preset: String? = nil,
                        log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [TranscriptTurn] {
        let directory = try directory(for: id)
        recording.remove(id)
        // Still being written, by this app or another process: processing now would read half a recording.
        if Self.session(directory)?.endedAt == nil, Self.recentlyWritten(directory) { throw MeetingStoreError.busy(id) }
        guard processing.insert(id).inserted else { throw MeetingStoreError.busy(id) }
        defer { processing.remove(id) }
        var started = MeetingMetadata.read(directory)
        started.pending = true
        // A retry is no longer failed: if it's cut off, the meeting stays pending and the next launch runs it again.
        started.failure = nil
        try? started.write(directory)
        var options = self.options
        if let preset, preset != options.preset {
            let previous = options
            options = MeetingPostProcessOptions(preset: preset, dictationSpans: options.dictationSpans)
            options.transcribeLater = previous.transcribeLater
            options.voices = previous.voices
            options.echoCanceller = previous.echoCanceller
            options.cancelsEcho = previous.cancelsEcho
        }
        // What processing did goes in the meeting's events.log too, after the recording's own lines, so one file
        // says how the whole meeting went.
        let logged: @Sendable (String) -> Void = { message in
            MeetingStorage.appendEvent("processing: \(message)", to: directory)
            log(message)
        }
        let began = Date()
        logged("started (\(options.preset))")
        do {
            let turns = try await MeetingPostProcessor.run(directory: directory, options: options, log: logged)
            var metadata = MeetingMetadata.read(directory)
            metadata.failure = nil
            metadata.pending = false
            try metadata.write(directory)
            logged(String(format: "done in %.1f s", Date().timeIntervalSince(began)))
            return turns
        } catch {
            // Stopped on quit: still pending, so the next launch runs it again rather than calling it failed.
            if error is CancellationError || Task.isCancelled { logged("stopped by quit; it runs again at launch"); throw error }
            logged("failed: \(error.localizedDescription)")
            var metadata = MeetingMetadata.read(directory)
            metadata.failure = error.localizedDescription
            metadata.pending = false
            try? metadata.write(directory)
            throw error
        }
    }

    /// At launch: finishes every recording that stopped without Stop (patches WAV header sizes from the
    /// file length, sets the end time from the last timing entry, marks it interrupted) and processes
    /// meetings left without a transcript. Returns the IDs it touched. Recovers what was transcribed
    /// live, plus what a quit left in deferred.jsonl; speech still queued when the app crashed is not
    /// re-transcribed.
    @discardableResult
    public func repairUnfinished(log: @escaping @Sendable (String) -> Void = { _ in }) async -> [String] {
        var touched: [String] = []
        for meeting in list() {
            // Quitting: what's left stays pending for the next launch.
            if Task.isCancelled { break }
            switch meeting.state {
            case .interrupted:
                do {
                    try finishInterrupted(meeting.directory)
                    log("\(meeting.id): repaired an unfinished recording")
                } catch {
                    log("\(meeting.id): repair failed: \(error.localizedDescription)")
                    continue
                }
            case .processing where !processing.contains(meeting.id):
                break
            default:
                continue
            }
            touched.append(meeting.id)
            do { try await process(meeting.id, log: log) } catch { log("\(meeting.id): processing failed: \(error.localizedDescription)") }
        }
        return touched
    }

    func finishInterrupted(_ directory: URL) throws {
        let sessionURL = directory.appendingPathComponent(MeetingStorage.sessionFile)
        let name = directory.lastPathComponent
        var info = (try? JSONDecoder.meeting.decode(MeetingSessionInfo.self, from: Data(contentsOf: sessionURL)))
            ?? MeetingSessionInfo(title: MeetingStorage.title(fromFolderName: name), source: "", target: "",
                                  startedAt: MeetingStorage.date(fromFolderName: name) ?? Self.creationDate(directory))
        var end = 0.0
        for track in MeetingTrack.allCases {
            let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let samples = try WAVFile.repairHeader(url)
            let trackEnd = Self.lastTiming(directory.appendingPathComponent(MeetingStorage.timingFile(track)))
                .map { $0.host + Double(max(0, samples - $0.sample)) / MeetingAudio.sampleRate }
                ?? Double(samples) / MeetingAudio.sampleRate
            end = max(end, trackEnd)
            var stats = (track == .microphone ? info.microphone : info.system) ?? TrackStats()
            stats.samples = samples
            if track == .microphone { info.microphone = stats } else { info.system = stats }
        }
        info.endedAt = info.startedAt.addingTimeInterval(end)
        try JSONEncoder.pretty.encode(info).write(to: sessionURL, options: .atomic)
        var metadata = MeetingMetadata.read(directory)
        metadata.interrupted = true
        try metadata.write(directory)
    }

    // MARK: Fixtures

    /// Copies what a benchmark needs to replay post-processing into `destination` (created; must be
    /// new or empty): both WAVs and timing files, live and echo-cancelled segments, session, transcript and its labels,
    /// speakers.json, participants, mute changes and dictation spans. The raw accessibility log is not
    /// copied, only the participant names parsed from it. Returns the files written.
    @discardableResult
    public func exportFixture(_ id: String, to destination: URL) async throws -> [String] {
        let directory = try directory(for: id)
        guard !recording.contains(id), !processing.contains(id) else { throw MeetingStoreError.busy(id) }
        let manager = FileManager.default
        // A relabel a run left half done is finished first, so the fixture's attribution and names are a pair.
        if manager.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.relabelFile).path) {
            try MeetingPostProcessor.render(directory: directory)
        }
        if manager.fileExists(atPath: destination.path) {
            guard (try manager.contentsOfDirectory(atPath: destination.path)).isEmpty else {
                throw MeetingStoreError.destinationNotEmpty(destination.path)
            }
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var files = MeetingTrack.allCases.flatMap { [MeetingStorage.audioFile($0), MeetingStorage.timingFile($0)] }
        files += [MeetingStorage.segmentsFile, MeetingStorage.echoCancelledSegmentsFile, MeetingStorage.sessionFile,
                  MeetingStorage.transcriptFile, MeetingStorage.attributedFile, MeetingStorage.speakersFile, MeetingStorage.muteFile,
                  MeetingStorage.diarizationFile, MeetingStorage.microphoneDiarizationFile, MeetingStorage.reportFile,
                  MeetingStorage.deferredFile]
        var written: [String] = []
        for file in files where manager.fileExists(atPath: directory.appendingPathComponent(file).path) {
            try manager.copyItem(at: directory.appendingPathComponent(file), to: destination.appendingPathComponent(file))
            written.append(file)
        }
        try JSONEncoder.pretty.encode(MeetingParticipants.read(directory))
            .write(to: destination.appendingPathComponent(MeetingStorage.participantsFile))
        written.append(MeetingStorage.participantsFile)
        var dictations = MeetingPostProcessor.readDictations(directory)
        if dictations == nil, let session = try? JSONDecoder.meeting.decode(
            MeetingSessionInfo.self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile))) {
            dictations = await options.dictationSpans(session)
        }
        try JSONEncoder.pretty.encode((dictations ?? []).map { [$0.lowerBound, $0.upperBound] })
            .write(to: destination.appendingPathComponent(MeetingStorage.dictationsFile))
        written.append(MeetingStorage.dictationsFile)
        return written.sorted()
    }

    // MARK: Internals

    /// Once someone names voices again, the note about names a re-run cleared has been seen to.
    static func forgetClearedNames(_ directory: URL) {
        let url = directory.appendingPathComponent(MeetingStorage.reportFile)
        guard var report = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder.meeting.decode(PostProcessReport.self, from: $0) }),
              report.namesCleared != nil else { return }
        report.namesCleared = nil
        try? JSONEncoder.pretty.encode(report).write(to: url, options: .atomic)
    }

    private func ensureIdle(_ id: String, _ directory: URL) throws {
        if recording.contains(id) || processing.contains(id) { throw MeetingStoreError.busy(id) }
        let session = Self.session(directory)
        if session?.endedAt == nil, Self.recentlyWritten(directory) { throw MeetingStoreError.busy(id) }
    }

    private func deleteAudio(at directory: URL) throws {
        for track in MeetingTrack.allCases {
            let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        var metadata = MeetingMetadata.read(directory)
        metadata.audioDeletedAt = Date()
        try metadata.write(directory)
    }

    private func summary(at directory: URL) -> MeetingSummary {
        let id = directory.lastPathComponent
        let session = Self.session(directory)
        let metadata = MeetingMetadata.read(directory)
        let manager = FileManager.default
        let transcriptURL = directory.appendingPathComponent(MeetingStorage.transcriptFile)
        let hasTranscript = manager.fileExists(atPath: transcriptURL.path)
        let state: MeetingState
        var failure = metadata.failure
        if recording.contains(id) {
            state = .recording
        } else if processing.contains(id) {
            state = .processing
        } else if session?.endedAt == nil {
            state = Self.recentlyWritten(directory) ? .recording : .interrupted
        } else if metadata.failure != nil {
            state = .failed
        } else if metadata.pending || !hasTranscript {
            state = .processing
        } else if !transcriptReadable(transcriptURL) {
            state = .failed
            failure = Self.unreadableTranscript
        } else {
            state = .ready
        }
        let audioSeconds = MeetingTrack.allCases.map {
            Double(max(0, Self.audioBytes(directory.appendingPathComponent(MeetingStorage.audioFile($0))) - 44)) / 2 / MeetingAudio.sampleRate
        }.max() ?? 0
        let startedAt = session?.startedAt ?? MeetingStorage.date(fromFolderName: id) ?? Self.creationDate(directory)
        let duration = session?.endedAt.map { $0.timeIntervalSince(startedAt) } ?? audioSeconds
        let participants = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.participantsFile)))
            .flatMap { try? JSONDecoder().decode(MeetingParticipants.self, from: $0) }?.all ?? []
        var speakers: [String] = []
        if let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.reportFile)),
           let report = try? JSONDecoder.meeting.decode(PostProcessReport.self, from: data) {
            speakers = report.speakers.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        } else if hasTranscript, let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)),
                  let turns = try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: data) {
            for turn in turns where !speakers.contains(turn.speaker) { speakers.append(turn.speaker) }
        }
        let title = MeetingTitles.display(typed: metadata.title, recorded: session?.title ?? MeetingStorage.title(fromFolderName: id),
                                          generated: MeetingNotesFile.read(directory)?.title)
        return MeetingSummary(id: id, title: title,
                              source: session?.source ?? "", target: session?.target ?? "", startedAt: startedAt,
                              endedAt: session?.endedAt, duration: max(0, duration), participants: participants, speakers: speakers,
                              state: state, wasInterrupted: metadata.interrupted,
                              hasAudio: MeetingTrack.allCases.contains {
                                  Self.audioBytes(directory.appendingPathComponent(MeetingStorage.audioFile($0))) > 44
                              },
                              starred: metadata.starred, failure: failure, directory: directory,
                              stopReason: session?.stopReason, kind: session?.kind ?? .call)
    }

    /// Decodes transcript.json once per version of the file; a list refresh only checks its date and size.
    private func transcriptReadable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = TranscriptStamp(modified: values?.contentModificationDate, size: values?.fileSize)
        if let known = transcriptChecks[url.path], known.stamp == stamp { return known.readable }
        let readable = (try? Data(contentsOf: url)).map { (try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: $0)) != nil } ?? false
        transcriptChecks[url.path] = (stamp, readable)
        return readable
    }

    static func isMeetingFolder(_ directory: URL) -> Bool {
        [MeetingStorage.sessionFile, MeetingStorage.segmentsFile, MeetingStorage.audioFile(.system), MeetingStorage.audioFile(.microphone)]
            .contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func session(_ directory: URL) -> MeetingSessionInfo? {
        (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
            .flatMap { try? JSONDecoder.meeting.decode(MeetingSessionInfo.self, from: $0) }
    }

    static func audioBytes(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func recentlyWritten(_ directory: URL, now: Date = Date()) -> Bool {
        let files = [MeetingStorage.audioFile(.system), MeetingStorage.audioFile(.microphone), MeetingStorage.segmentsFile,
                     MeetingStorage.sessionFile, MeetingStorage.eventsFile]
        return files.contains { file in
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path))?[.modificationDate]
                    as? Date else { return false }
            return now.timeIntervalSince(modified) < liveWriteWindow
        }
    }

    static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    /// The last `{"sample": n, "host": seconds}` line of a timing file that parses.
    static func lastTiming(_ url: URL) -> (sample: Int, host: Double)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        struct Entry: Decodable { let sample: Int; let host: Double }
        for line in text.split(separator: "\n").reversed() {
            if let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)) { return (entry.sample, entry.host) }
        }
        return nil
    }
}

extension WAVFile {
    /// Rewrites the header sizes of a WAV whose writer never finished, from the file's length, and
    /// drops a trailing half sample. Returns the sample count.
    @discardableResult
    static func repairHeader(_ url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard length >= 44 else {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: header(dataBytes: 0))
            return 0
        }
        let dataBytes = (length - 44) / 2 * 2
        if dataBytes + 44 != length { try handle.truncate(atOffset: UInt64(dataBytes + 44)) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes))
        try handle.synchronize()
        return dataBytes / 2
    }
}
