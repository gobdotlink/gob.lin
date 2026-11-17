import FluidAudio
import Foundation
import GoblinCore
import GoblinEngines

public struct DiarizedSpan: Codable, Sendable, Hashable {
    public let speaker: Int
    public let start: Double
    public let end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public struct PostProcessReport: Codable, Sendable {
    public var preset: String
    public var systemSeconds: Double
    public var diarizeSeconds: Double
    public var modelLoadSeconds: Double
    /// Seconds of talk per displayed speaker name.
    public var speakers: [String: Double]
    /// Words removed from microphone lines as echo of the call.
    public var echoSegmentsDropped: Int
    public var dictationSegmentsDropped: Int
    public var mutedSegmentsDropped: Int
    public var turns: Int
    /// Lines heard after the call ended, while the recording counted down to stopping.
    public var afterCallSegmentsDropped: Int? = nil
    /// Names given before this run that no voice could keep: the voices were sorted out again and none of them
    /// mostly matched the named one.
    public var namesCleared: [String]? = nil
}

/// What split the system track into voices: spans plus how long loading and running took.
public struct DiarizationResult: Sendable {
    public var spans: [DiarizedSpan]
    public var modelLoadSeconds: Double
    public var diarizeSeconds: Double

    public init(spans: [DiarizedSpan], modelLoadSeconds: Double = 0, diarizeSeconds: Double = 0) {
        self.spans = spans
        self.modelLoadSeconds = modelLoadSeconds
        self.diarizeSeconds = diarizeSeconds
    }
}

/// Transcribes chunks the live transcript left for after the call, in the meeting's language. Throws when the speech
/// model can't run; the meeting then fails with the reason and Try Again runs it again.
public typealias MeetingLateTranscriber = @Sendable (_ chunks: [SpeechChunk], _ options: RecognitionOptions) async throws -> [TranscriptSegment]

public enum MeetingProcessingError: Error, LocalizedError, Equatable {
    /// Speech the live transcript left for after the call couldn't be transcribed: no speech model here, or it failed.
    case untranscribed(seconds: Double, reason: String?)

    public var errorDescription: String? {
        switch self {
        case .untranscribed(let seconds, let reason?):
            "\(Self.spoken(seconds)) of speech still needs the speech model, which couldn't run: \(reason)"
        case .untranscribed(let seconds, nil):
            "\(Self.spoken(seconds)) of speech still needs transcribing, and there's no speech model here to do it."
        }
    }

    /// "About 4 minutes", "40 seconds".
    static func spoken(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) \(total == 1 ? "second" : "seconds")" }
        let minutes = Int((seconds / 60).rounded())
        return "About \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}

/// 16 kHz mono system-track samples in, speaker spans out.
public typealias MeetingDiarizer = @Sendable (_ samples: [Float], _ log: @Sendable (String) -> Void) async throws -> DiarizationResult

/// The Nemotron 3 speaker model that tells a call's voices apart. Its files are pinned in GoblinEngines'
/// speech-model-assets.json (FluidInference/nemotron-3-diarization-coreml at an exact commit, with sizes and SHA-256)
/// and kept in `gob.lin/models/nemotron-3-diarization`, downloaded the first time a meeting needs them.
public enum MeetingSpeakerModel {
    public static let folder = "nemotron-3-diarization"

    /// One preset's model and the shared silence embedding.
    public static func files(preset: String) -> PinnedModelFiles {
        PinnedModelFiles(manifestID: "nemotron-3-diarization-\(preset)", folder: folder)
    }

    static func config(preset: String) -> Nemotron3Config {
        preset == "fast32" ? .fast32 : (preset == "fast128" ? .fast128 : .offline)
    }

    /// The compiled bundle FluidAudio loads for a preset, which the pinned files must hold.
    static func bundleName(preset: String) -> String { config(preset: preset).modelFileName }
}

public struct MeetingPostProcessOptions: Sendable {
    public static let presets = ["offline", "fast32", "fast128"]

    public var preset: String
    public var diarizer: MeetingDiarizer
    /// gob.lin dictations during the meeting, in meeting seconds. Used only when the folder has no dictations.json.
    public var dictationSpans: @Sendable (MeetingSessionInfo) async -> [ClosedRange<Double>]
    /// Transcribes what the live transcript left in deferred.jsonl. Nil: a meeting with any fails until it's processed
    /// where a speech model can run.
    public var transcribeLater: MeetingLateTranscriber?

    /// `modelDownload` hears how far the speaker model's one-time download has got (0...1), then nil once it's done
    /// or failed; it's never called when the model is already on this Mac.
    public init(preset: String = "offline", diarizer: MeetingDiarizer? = nil,
                dictationSpans: (@Sendable (MeetingSessionInfo) async -> [ClosedRange<Double>])? = nil,
                modelDownload: (@Sendable (Double?) -> Void)? = nil, transcribeLater: MeetingLateTranscriber? = nil) {
        self.preset = preset
        self.diarizer = diarizer ?? Self.nemotron(preset: preset, modelDownload: modelDownload)
        self.dictationSpans = dictationSpans ?? { await MeetingPostProcessor.dictationSpans(from: $0) }
        self.transcribeLater = transcribeLater
    }

    /// Nemotron 3 from FluidAudio, loaded from gob.lin's pinned copy; downloads and checks it on first use.
    public static func nemotron(preset: String, modelDownload: (@Sendable (Double?) -> Void)? = nil) -> MeetingDiarizer {
        let files = MeetingSpeakerModel.files(preset: preset)
        return { samples, log in
            let config = MeetingSpeakerModel.config(preset: preset)
            let loadStart = Date()
            if !files.isDownloaded {
                log("downloading the speaker model (\(files.downloadBytes / 1_000_000) MB), once")
                modelDownload?(0)
                do {
                    _ = try await files.ensureAvailable { update in
                        if update.phase == .downloading, let fraction = update.fractionCompleted { modelDownload?(fraction) }
                    }
                    modelDownload?(nil)
                } catch {
                    modelDownload?(nil)
                    throw error
                }
            } else {
                _ = try await files.ensureAvailable()
            }
            log("loading Nemotron 3 (\(preset))")
            let models = try await Nemotron3Models.load(config: config, directory: files.directory)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            let start = Date()
            log("diarizing \(Int(Double(samples.count) / MeetingAudio.sampleRate)) s of system audio")
            let (probabilities, frames) = try diarizer.processComplete(samples)
            let spans = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames)
                .map { DiarizedSpan(speaker: $0.speakerIndex, start: Double($0.startSeconds), end: Double($0.endSeconds)) }
            return DiarizationResult(spans: spans, modelLoadSeconds: loadSeconds, diarizeSeconds: Date().timeIntervalSince(start))
        }
    }
}

/// After Stop: split the system track by speaker, drop microphone words that are the call echoing
/// back, lines said while muted or dictated elsewhere, and write the transcript.
///
/// Files: diarization.json (spans), attributed.json (turns under their diarized label), then
/// `render` applies speakers.json names and writes transcript.json, transcript.md and postprocess.json.
/// Renaming a speaker only re-renders; it never re-runs diarization.
public enum MeetingPostProcessor {
    /// The microphone's label; speakers.json can rename it like any other.
    public static let microphoneLabel = "You"
    /// The system track's label when no voices could be told apart and the call has no single other participant.
    public static let unknownRemoteLabel = "Them"

    public static func run(directory: URL, preset: String = "offline",
                           log: @Sendable (String) -> Void = { _ in }) async throws -> [TranscriptTurn] {
        try await run(directory: directory, options: MeetingPostProcessOptions(preset: preset), log: log)
    }

    public static func run(directory: URL, options: MeetingPostProcessOptions,
                           log: @Sendable (String) -> Void = { _ in }) async throws -> [TranscriptTurn] {
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        try await transcribeDeferred(directory: directory, session: session, options: options, log: log)
        var segments = try loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))

        // Speakers on the system track; for a conversation in the room, on the microphone track.
        let inPerson = session?.kind == .inPerson
        // Audio deleted before a retry leaves nothing to diarize: the lines are kept, under one voice.
        func samples(_ track: MeetingTrack) throws -> [Float] {
            let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
            return FileManager.default.fileExists(atPath: url.path) ? try WAVFile.readSamples(url) : []
        }
        let systemSamples = try samples(.system)
        let diarizedSamples = inPerson ? try samples(.microphone) : systemSamples
        var diarization = DiarizationResult(spans: [])
        if diarizedSamples.count > Int(MeetingAudio.sampleRate) {
            diarization = try await options.diarizer(diarizedSamples, log)
            diarization.spans.sort { $0.start < $1.start }
        }
        let spans = diarization.spans
        try JSONEncoder.pretty.encode(spans).write(to: directory.appendingPathComponent(MeetingStorage.diarizationFile), options: .atomic)

        // Nothing after the call ended belongs to it, including the end of a line that runs past it.
        var afterCallDropped = 0
        if let end = session?.callEndedAt {
            segments = segments.compactMap { segment in
                let kept = before(end, segment)
                if kept != segment { afterCallDropped += 1 }
                return kept
            }
        }

        // Microphone lines to drop.
        let system = segments.filter { $0.track == .system }
        let dictations: [ClosedRange<Double>]
        if let saved = readDictations(directory) {
            dictations = saved
        } else if let session {
            dictations = await options.dictationSpans(session)
        } else {
            dictations = []
        }
        let audioEnd = max(Double(systemSamples.count) / MeetingAudio.sampleRate, segments.map(\.end).max() ?? 0)
        let muted = mutedSpans(directory.appendingPathComponent(MeetingStorage.muteFile), end: audioEnd)
        var echoDropped = 0, dictationDropped = 0, mutedDropped = 0
        let systemWords = system.flatMap(\.words).sorted { $0.start < $1.start }
        var microphone: [TranscriptSegment] = []
        for segment in segments where segment.track == .microphone {
            // While the call is muted, what the mic hears was never said to the meeting.
            if muted.contains(where: { $0.contains((segment.start + segment.end) / 2) }) { mutedDropped += 1; continue }
            let (undictated, trimmed) = removeDictation(segment, spans: dictations)
            if trimmed { dictationDropped += 1 }
            guard let segment = undictated else { continue }
            let (kept, removed) = removeEcho(segment, systemWords: systemWords)
            echoDropped += removed
            if let kept { microphone.append(kept) }
        }

        // Turns under their labels.
        let participants = MeetingParticipants.read(directory)
        var turns: [TranscriptTurn]
        if inPerson {
            // Everyone is on the mic, so voices are split there; nobody is "You" until named.
            turns = systemTurns(microphone, spans: spans, remote: [], track: .microphone)
        } else {
            turns = microphone.map {
                TranscriptTurn(speaker: microphoneLabel, label: microphoneLabel, track: .microphone, start: $0.start, end: $0.end,
                               text: $0.text, words: $0.words)
            }
            turns += systemTurns(system, spans: spans, remote: participants.others)
        }
        turns.sort { $0.start < $1.start }
        turns = merge(turns, by: { $0.label ?? $0.speaker })

        // Run again (Try Again, or the CLI): the voices may be numbered differently now, so names follow the voice
        // they were given to, by when it talked, rather than its old number.
        // The names and the attribution they're for are a pair: both go into relabel.json in one write, then replace
        // the old pair, so a run cut off in between never leaves names on another voice.
        try finishRelabel(directory)
        let attributedURL = directory.appendingPathComponent(MeetingStorage.attributedFile)
        var namesCleared: [String] = []
        let names = speakerNames(directory)
        if !names.isEmpty, let data = try? Data(contentsOf: attributedURL),
           let previous = try? JSONDecoder.meeting.decode([TranscriptTurn].self, from: data) {
            let carried = carryNames(names, from: previous, to: turns)
            namesCleared = carried.cleared
            try JSONEncoder.pretty.encode(Relabel(turns: turns, names: carried.names))
                .write(to: directory.appendingPathComponent(MeetingStorage.relabelFile), options: .atomic)
            try finishRelabel(directory)
            if !namesCleared.isEmpty { log("\(namesCleared.count) names no longer match a voice and were cleared") }
        } else {
            try JSONEncoder.pretty.encode(turns).write(to: attributedURL, options: .atomic)
        }
        try JSONEncoder.pretty.encode(participants).write(to: directory.appendingPathComponent(MeetingStorage.participantsFile), options: .atomic)
        let report = PostProcessReport(preset: options.preset, systemSeconds: Double(systemSamples.count) / MeetingAudio.sampleRate,
                                       diarizeSeconds: diarization.diarizeSeconds, modelLoadSeconds: diarization.modelLoadSeconds,
                                       speakers: [:], echoSegmentsDropped: echoDropped, dictationSegmentsDropped: dictationDropped,
                                       mutedSegmentsDropped: mutedDropped, turns: 0,
                                       afterCallSegmentsDropped: afterCallDropped, namesCleared: namesCleared.isEmpty ? nil : namesCleared)
        try JSONEncoder.pretty.encode(report).write(to: directory.appendingPathComponent(MeetingStorage.reportFile), options: .atomic)
        let rendered = try render(directory: directory)
        log("wrote \(rendered.count) turns; \(Set(rendered.map(\.speaker)).count) speakers; dropped \(echoDropped) echo words, "
            + "\(dictationDropped) dictation and \(mutedDropped) muted lines")
        return rendered
    }

    /// Applies speakers.json to attributed.json and rewrites transcript.json, transcript.md and the
    /// report's talk times. Cheap: no audio is read.
    @discardableResult
    public static func render(directory: URL) throws -> [TranscriptTurn] {
        try finishRelabel(directory)
        let attributedURL = directory.appendingPathComponent(MeetingStorage.attributedFile)
        let transcriptURL = directory.appendingPathComponent(MeetingStorage.transcriptFile)
        var base: [TranscriptTurn]
        if let data = try? Data(contentsOf: attributedURL) {
            base = try JSONDecoder.meeting.decode([TranscriptTurn].self, from: data)
        } else {
            // A folder processed before attributed.json existed: its transcript's names are the labels.
            base = try JSONDecoder.meeting.decode([TranscriptTurn].self, from: Data(contentsOf: transcriptURL))
            for index in base.indices where base[index].label == nil { base[index].label = base[index].speaker }
            try JSONEncoder.pretty.encode(base).write(to: attributedURL, options: .atomic)
        }
        let names = speakerNames(directory)
        let turns = merge(base.map { turn in
            var turn = turn
            let label = turn.label ?? turn.speaker
            turn.speaker = names[label] ?? label
            return turn
        }, by: \.speaker)
        try JSONEncoder.pretty.encode(turns).write(to: transcriptURL, options: .atomic)

        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        let metadata = MeetingMetadata.read(directory)
        try markdown(turns, title: metadata.title ?? session?.title, session: session,
                     participants: MeetingParticipants.read(directory))
            .write(to: directory.appendingPathComponent(MeetingStorage.transcriptMarkdownFile), atomically: true, encoding: .utf8)

        let reportURL = directory.appendingPathComponent(MeetingStorage.reportFile)
        if var report = try? JSONDecoder.meeting.decode(PostProcessReport.self, from: Data(contentsOf: reportURL)) {
            var talk: [String: Double] = [:]
            for turn in turns { talk[turn.speaker, default: 0] += turn.end - turn.start }
            report.speakers = talk
            report.turns = turns.count
            try JSONEncoder.pretty.encode(report).write(to: reportURL, options: .atomic)
        }
        return turns
    }

    /// relabel.json: a rerun's attribution and the names carried onto it.
    struct Relabel: Codable {
        var turns: [TranscriptTurn]
        var names: [String: String]
    }

    /// Writes a relabel.json left by a run into attributed.json and speakers.json, then removes it.
    static func finishRelabel(_ directory: URL) throws {
        let url = directory.appendingPathComponent(MeetingStorage.relabelFile)
        guard let data = try? Data(contentsOf: url) else { return }
        // Written atomically, so one that won't decode isn't a pair half written; the old pair stays.
        guard let relabel = try? JSONDecoder.meeting.decode(Relabel.self, from: data) else {
            try FileManager.default.removeItem(at: url)
            return
        }
        try JSONEncoder.pretty.encode(relabel.turns).write(to: directory.appendingPathComponent(MeetingStorage.attributedFile), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(relabel.names).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile), options: .atomic)
        try FileManager.default.removeItem(at: url)
    }

    /// speakers.json: diarized label → name. Labels are only stable for one diarization run; a re-run
    /// with another preset may number voices differently.
    public static func speakerNames(_ directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.speakersFile)),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Chunks in deferred.jsonl, each once, in track and time order.
    static func deferredChunks(_ directory: URL) -> [DeferredChunk] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(MeetingStorage.deferredFile), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let chunks = Set(text.split(separator: "\n").compactMap { try? decoder.decode(DeferredChunk.self, from: Data($0.utf8)) })
        return chunks.sorted { ($0.track.rawValue, $0.startSample) < ($1.track.rawValue, $1.startSample) }
    }

    /// Transcribes what the live transcript left for after the call from the tracks' audio, adds it to segments.jsonl
    /// and removes deferred.jsonl. Throws `MeetingProcessingError.untranscribed` when it can't, leaving both as they
    /// were so Try Again can. A chunk whose audio is gone (deleted after an earlier run) can't be transcribed again,
    /// so whatever that run recovered from it stays.
    static func transcribeDeferred(directory: URL, session: MeetingSessionInfo?, options: MeetingPostProcessOptions,
                                   log: @Sendable (String) -> Void) async throws {
        let deferredURL = directory.appendingPathComponent(MeetingStorage.deferredFile)
        guard FileManager.default.fileExists(atPath: deferredURL.path) else { return }
        let deferred = deferredChunks(directory)
        var audio: [MeetingTrack: [Float]] = [:]
        var chunks: [SpeechChunk] = []
        for chunk in deferred {
            if audio[chunk.track] == nil {
                let url = directory.appendingPathComponent(MeetingStorage.audioFile(chunk.track))
                audio[chunk.track] = FileManager.default.fileExists(atPath: url.path) ? try WAVFile.readSamples(url) : []
            }
            let samples = audio[chunk.track] ?? []
            let start = min(max(0, chunk.startSample), samples.count), end = min(start + max(0, chunk.sampleCount), samples.count)
            guard end > start else { continue }
            chunks.append(SpeechChunk(track: chunk.track, startSample: start, samples: Array(samples[start..<end])))
        }
        if chunks.count < deferred.count { log("\(deferred.count - chunks.count) chunks left for after the call have no audio") }
        guard !chunks.isEmpty else { try FileManager.default.removeItem(at: deferredURL); return }
        // Only lines from the audio transcribed now are replaced.
        let replayed = chunks.map(DeferredChunk.init)
        let seconds = replayed.reduce(0) { $0 + $1.seconds }
        guard let transcribe = options.transcribeLater else { throw MeetingProcessingError.untranscribed(seconds: seconds, reason: nil) }
        log("transcribing \(chunks.count) chunks (\(Int(seconds)) s) the live transcript left for after the call")
        let segments: [TranscriptSegment]
        do {
            segments = try await transcribe(chunks, RecognitionOptions(language: session?.language))
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            throw MeetingProcessingError.untranscribed(seconds: seconds, reason: error.localizedDescription)
        }
        // segments.jsonl is rewritten whole with the deferred chunks' lines replaced, so a run cut off before
        // deferred.jsonl goes (or a chunk that finished live as a quit gave up on it) never adds the same speech twice.
        let segmentsURL = directory.appendingPathComponent(MeetingStorage.segmentsFile)
        let existing = (try? String(contentsOf: segmentsURL, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()
        var lines = existing.split(separator: "\n").map(String.init).filter { line in
            guard let segment = try? decoder.decode(TranscriptSegment.self, from: Data(line.utf8)) else { return true }
            return !replayed.contains { $0.covers(segment) }
        }
        let encoder = JSONEncoder()
        for segment in segments { if let line = try? encoder.encode(segment) { lines.append(String(decoding: line, as: UTF8.self)) } }
        try lines.map { $0 + "\n" }.joined().write(to: segmentsURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: deferredURL)
    }

    /// Moves speakers.json's names from the voices of an earlier run (`previous`, under their labels then) to this
    /// run's: each new voice takes the name of the earlier voice it shares the most talking time with on the same
    /// track, when that's at least half of its own. Names no new voice takes come back as `cleared`.
    static func carryNames(_ names: [String: String], from previous: [TranscriptTurn],
                           to turns: [TranscriptTurn]) -> (names: [String: String], cleared: [String]) {
        func label(_ turn: TranscriptTurn) -> String { turn.label ?? turn.speaker }
        // The earlier voices as they were shown: a merge gave several labels one name.
        let shown = Dictionary(grouping: previous) { "\($0.track.rawValue)\u{1F}\(names[label($0)] ?? label($0))" }
        var carried: [String: String] = [:]
        for (newLabel, group) in Dictionary(grouping: turns, by: label) {
            let talk = group.reduce(0) { $0 + max(0, $1.end - $1.start) }
            guard talk > 0 else { continue }
            var best: (name: String, overlap: Double)?
            for (key, old) in shown {
                let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                guard parts.count == 2, group.contains(where: { $0.track.rawValue == parts[0] }) else { continue }
                var overlap = 0.0
                for turn in group {
                    for earlier in old where earlier.track == turn.track && earlier.start < turn.end && earlier.end > turn.start {
                        overlap += min(earlier.end, turn.end) - max(earlier.start, turn.start)
                    }
                }
                if overlap > (best?.overlap ?? 0) { best = (parts[1], overlap) }
            }
            guard let best, best.overlap >= talk / 2, names.values.contains(best.name), best.name != newLabel else { continue }
            carried[newLabel] = best.name
        }
        let cleared = Set(names.values).subtracting(carried.values).sorted()
        return (carried, cleared)
    }

    static func loadSegments(_ url: URL) throws -> [TranscriptSegment] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(TranscriptSegment.self, from: Data($0.utf8)) }
            .sorted { $0.start < $1.start }
    }

    /// A fixture's `dictations.json` (`[[start, end]]`), else the app's live `dictations.jsonl`
    /// (`{"start": s, "end": e}` per take); nil when neither exists.
    static func readDictations(_ directory: URL) -> [ClosedRange<Double>]? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.dictationsFile)),
           let pairs = try? JSONDecoder().decode([[Double]].self, from: data) {
            return pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        }
        guard let text = try? String(contentsOf: directory.appendingPathComponent(MeetingStorage.liveDictationsFile),
                                     encoding: .utf8) else { return nil }
        struct Take: Decodable { let start: Double; let end: Double }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Take.self, from: Data($0.utf8)) }
            .compactMap { $0.start <= $0.end ? $0.start...$0.end : nil }
    }

    static func mutedSpans(_ url: URL, end: Double) -> [ClosedRange<Double>] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return mutedSpans(text, end: end)
    }

    /// mute.jsonl holds `{"t": seconds, "muted": Bool}` changes; a mute still on at the end lasts to `end`.
    static func mutedSpans(_ text: String, end: Double) -> [ClosedRange<Double>] {
        MuteTimeline(jsonl: text).spans(end: end)
    }

    // MARK: Echo

    enum Echo {
        /// System words this far either side of a mic line are its echo candidates.
        static let searchWindow = 1.5
        /// A mic word is echo when the system track has the same word starting within this many
        /// seconds: speaker-to-mic delay is tens of ms, Parakeet's word timings drift by a few hundred.
        static let sameWordWindow = 1.0
        /// A matched word this short ("the", "and", "I") is common enough to coincide with the other
        /// side by chance, so alone it is not echo: it needs a matched neighbour, or a line of at most
        /// `shortLineWords` words (a lone "Bye." echoing back).
        static let commonWordLetters = 3
        static let shortLineWords = 2
        /// Padding when asking whether the other side was talking during a mic word.
        static let talkingPadding = 0.3
        /// An unmatched word next to echo while the other side talks is echo too (a mishearing like
        /// "Bob" for "bye"). Each pass reaches one word further, so two passes catch two-word mishearings
        /// without eating a sentence the person said over the other side.
        static let spreadPasses = 2
    }

    /// Removes the words the microphone heard from the call's own playback, keeping the rest of the
    /// line. Returns the kept segment (nil if nothing is left) and how many words were removed.
    static func removeEcho(_ segment: TranscriptSegment, systemWords: [TranscriptWord]) -> (TranscriptSegment?, Int) {
        guard !segment.words.isEmpty else { return (segment, 0) }
        let nearby = systemWords.filter { $0.end >= segment.start - Echo.searchWindow && $0.start <= segment.end + Echo.searchWindow }
        guard !nearby.isEmpty else { return (segment, 0) }
        let words = segment.words
        let keys = words.map { normalizedKey($0.text) }
        let nearbyKeys = nearby.map { normalizedKey($0.text) }
        let matched = words.indices.map { index in
            !keys[index].isEmpty && nearby.indices.contains { other in
                nearbyKeys[other] == keys[index] && abs(nearby[other].start - words[index].start) <= Echo.sameWordWindow
            }
        }
        var echo = words.indices.map { index in
            matched[index] && (keys[index].count > Echo.commonWordLetters || words.count <= Echo.shortLineWords
                               || (index > 0 && matched[index - 1]) || (index + 1 < words.count && matched[index + 1]))
        }
        let otherSideTalking = words.map { word in
            nearby.contains { $0.start <= word.end + Echo.talkingPadding && $0.end >= word.start - Echo.talkingPadding }
        }
        for _ in 0..<Echo.spreadPasses {
            let previousPass = echo
            for index in words.indices where !previousPass[index] && otherSideTalking[index] {
                if (index > 0 && previousPass[index - 1]) || (index + 1 < words.count && previousPass[index + 1]) { echo[index] = true }
            }
        }
        let kept = words.indices.filter { !echo[$0] }.map { words[$0] }
        let removed = words.count - kept.count
        guard removed > 0 else { return (segment, 0) }
        guard let first = kept.first, let last = kept.last, kept.contains(where: { !normalizedKey($0.text).isEmpty }) else {
            return (nil, removed)
        }
        var trimmed = segment
        trimmed.words = kept
        trimmed.text = kept.map(\.text).joined(separator: " ")
        trimmed.start = first.start
        trimmed.end = last.end
        return (trimmed, removed)
    }

    static func normalizedKey(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }

    // MARK: Dictation

    /// The part of a segment said before `end`: its words whose middle is before it. A segment that runs past `end`
    /// without word times can't be cut, so it goes.
    static func before(_ end: Double, _ segment: TranscriptSegment) -> TranscriptSegment? {
        guard segment.end > end else { return segment }
        guard segment.start < end, !segment.words.isEmpty else { return nil }
        let kept = segment.words.filter { ($0.start + $0.end) / 2 < end }
        guard kept.count < segment.words.count else { return segment }
        guard let first = kept.first, let last = kept.last, kept.contains(where: { !normalizedKey($0.text).isEmpty }) else { return nil }
        var trimmed = segment
        trimmed.words = kept
        trimmed.text = kept.map(\.text).joined(separator: " ")
        trimmed.start = first.start
        trimmed.end = last.end
        return trimmed
    }

    /// Leaves out the words said into a gob.lin dictation: those whose middle falls inside a take's span, from key-down
    /// to key-up. The rest of the line stays. A line without word timings goes when its own middle was dictated.
    /// Returns the kept segment (nil if nothing is left) and whether anything was removed.
    public static func removeDictation(_ segment: TranscriptSegment, spans: [ClosedRange<Double>]) -> (TranscriptSegment?, Bool) {
        guard spans.contains(where: { $0.overlaps(segment.start...segment.end) }) else { return (segment, false) }
        func dictated(_ start: Double, _ end: Double) -> Bool { spans.contains { $0.contains((start + end) / 2) } }
        guard !segment.words.isEmpty else { return dictated(segment.start, segment.end) ? (nil, true) : (segment, false) }
        let kept = segment.words.filter { !dictated($0.start, $0.end) }
        guard kept.count < segment.words.count else { return (segment, false) }
        guard let first = kept.first, let last = kept.last, kept.contains(where: { !normalizedKey($0.text).isEmpty }) else {
            return (nil, true)
        }
        var trimmed = segment
        trimmed.words = kept
        trimmed.text = kept.map(\.text).joined(separator: " ")
        trimmed.start = first.start
        trimmed.end = last.end
        return (trimmed, true)
    }

    static func dictationSpans(from session: MeetingSessionInfo) async -> [ClosedRange<Double>] {
        guard let store = try? HistoryStore(), let entries = try? await store.entries(limit: 500) else { return [] }
        let meetingStart = session.startedAt, meetingEnd = session.endedAt ?? Date()
        return entries.compactMap { entry in
            guard entry.completedAt >= meetingStart, entry.createdAt <= meetingEnd else { return nil }
            let start = min(entry.createdAt, entry.completedAt.addingTimeInterval(-entry.audioDuration))
            let lower = start.timeIntervalSince(meetingStart) - 0.5
            // Only the talking: cleanup and insertion after key-up aren't the dictation.
            let spoken = min(entry.completedAt, start.addingTimeInterval(entry.audioDuration))
            let upper = spoken.timeIntervalSince(meetingStart) + 0.5
            return lower < upper ? lower...upper : nil
        }
    }

    // MARK: Attribution

    /// Words that overlap no diarized span take the speaker of a span within this many seconds,
    /// then the previous word's speaker, then the nearest span at any distance.
    static let nearbySpanSeconds = 2.0

    /// System-track turns labelled "Speaker N" by order of first word, or named from the participant
    /// list when the call had exactly one other person and one voice. With 2+ other participants the
    /// voices stay "Speaker N" (nothing ties a voice to a name yet); the transcript lists the participants.
    static func systemTurns(_ system: [TranscriptSegment], spans: [DiarizedSpan], remote: [String],
                            track: MeetingTrack = .system) -> [TranscriptTurn] {
        // The last word's speaker carries across lines, so overlapped speech stays with whoever was already talking.
        var previous: Int?
        let attributed = system.map { segment in
            let speakers = speakers(for: segment, spans: spans, previous: previous)
            previous = speakers.last ?? previous
            return (segment, speakers)
        }
        var order: [Int: Int] = [:]
        for (_, speakers) in attributed {
            for case let speaker? in speakers where order[speaker] == nil { order[speaker] = order.count + 1 }
        }
        var names: [Int: String] = order.mapValues { "Speaker \($0)" }
        // A 1:1 call needs no machine learning to name the other side.
        if order.count == 1, remote.count == 1 { names = names.mapValues { _ in remote[0] } }
        let fallback = remote.count == 1 ? remote[0] : (track == .microphone ? "Speaker 1" : unknownRemoteLabel)

        var turns: [TranscriptTurn] = []
        for (segment, speakers) in attributed {
            guard !segment.words.isEmpty else {
                let label = speakers.first.flatMap { $0 }.flatMap { names[$0] } ?? fallback
                turns.append(TranscriptTurn(speaker: label, label: label, track: track, start: segment.start, end: segment.end,
                                            text: segment.text, words: []))
                continue
            }
            var segmentTurns: [TranscriptTurn] = []
            for (word, speaker) in zip(segment.words, speakers) {
                let label = speaker.flatMap { names[$0] } ?? fallback
                if let last = segmentTurns.last, last.label == label {
                    segmentTurns[segmentTurns.count - 1].words.append(word)
                    segmentTurns[segmentTurns.count - 1].end = word.end
                    segmentTurns[segmentTurns.count - 1].text += " " + word.text
                } else {
                    segmentTurns.append(TranscriptTurn(speaker: label, label: label, track: track, start: word.start, end: word.end,
                                                       text: word.text, words: [word]))
                }
            }
            turns += segmentTurns
        }
        return turns
    }

    /// One speaker per word (one for the whole segment when it has no words); nil only without spans. `previous` is
    /// the speaker of the word before this segment.
    static func speakers(for segment: TranscriptSegment, spans: [DiarizedSpan], previous: Int? = nil) -> [Int?] {
        guard !spans.isEmpty else { return segment.words.isEmpty ? [nil] : segment.words.map { _ in nil } }
        guard !segment.words.isEmpty else {
            return [dominant(spans, segment.start, segment.end, previous: previous)
                ?? nearest(spans, (segment.start + segment.end) / 2, within: .infinity)]
        }
        var result: [Int?] = []
        // The word before decides ties; only a word in this segment stands in for a word far from every span.
        var inSegment: Int?
        for word in segment.words {
            let middle = (word.start + word.end) / 2
            let speaker = dominant(spans, word.start, word.end, previous: inSegment ?? previous)
                ?? nearest(spans, middle, within: nearbySpanSeconds) ?? inSegment ?? nearest(spans, middle, within: .infinity)
            result.append(speaker)
            inSegment = speaker
        }
        return result
    }

    /// A voice whose overlap with a word is at least this share of the largest one counts as a tie.
    static let overlapTieShare = 0.8
    /// A pause in a voice this short, with the voice going on after it, is still that voice's turn.
    static let pauseInTurnSeconds = 0.6

    /// The voice that overlaps `start…end` most. The diarizer marks voices talking over each other, so two voices can
    /// cover a word about equally; then the word stays with `previous`, whoever was already talking, including across
    /// a short pause in their voice, rather than going to the lower-numbered voice. Without that, a voice heard under
    /// someone's monologue once took the second half of it.
    static func dominant(_ spans: [DiarizedSpan], _ start: Double, _ end: Double, previous: Int? = nil) -> Int? {
        var overlap: [Int: Double] = [:]
        for span in spans where span.start < end && span.end > start {
            overlap[span.speaker, default: 0] += min(span.end, end) - max(span.start, start)
        }
        guard let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        guard let previous else { return best.key }
        var held = overlap[previous] ?? 0
        if held < best.value * overlapTieShare, pausesWithin(spans, of: previous, start, end) { held = end - start }
        return held >= best.value * overlapTieShare ? previous : best.key
    }

    /// Whether `start…end` falls in a pause of `speaker`'s voice no longer than `pauseInTurnSeconds`: a span of
    /// theirs that began before the word stopped, and a later one starts again and runs past the word. A voice that
    /// stopped and doesn't resume, or only blips inside the word, has ended its turn.
    static func pausesWithin(_ spans: [DiarizedSpan], of speaker: Int, _ start: Double, _ end: Double) -> Bool {
        let theirs = spans.filter { $0.speaker == speaker }
        guard let stopped = theirs.filter({ $0.start < start && $0.end <= end }).map(\.end).max(),
              let resumed = theirs.filter({ $0.start >= stopped && $0.start >= start && $0.end > end }).map(\.start).min()
        else { return false }
        return resumed - stopped <= pauseInTurnSeconds
    }

    static func nearest(_ spans: [DiarizedSpan], _ time: Double, within limit: Double) -> Int? {
        spans.map { span in (span.speaker, time < span.start ? span.start - time : max(0, time - span.end)) }
            .filter { $0.1 <= limit }.min { $0.1 < $1.1 }?.0
    }

    /// Joins consecutive turns with the same key on the same track less than 1.5 s apart. A name given to both the mic
    /// and a remote voice keeps a turn per track, as each plays from its own track's file.
    static func merge(_ turns: [TranscriptTurn], by key: (TranscriptTurn) -> String) -> [TranscriptTurn] {
        var merged: [TranscriptTurn] = []
        for turn in turns {
            if let last = merged.last, key(last) == key(turn), last.track == turn.track, turn.start - last.end < 1.5 {
                merged[merged.count - 1].end = max(last.end, turn.end)
                merged[merged.count - 1].text += " " + turn.text
                merged[merged.count - 1].words += turn.words
                if merged[merged.count - 1].label != turn.label { merged[merged.count - 1].label = nil }
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    static func markdown(_ turns: [TranscriptTurn], title: String?, session: MeetingSessionInfo?,
                         participants: MeetingParticipants) -> String {
        var lines: [String] = []
        if let session {
            lines.append("# \(title ?? session.title)")
            lines.append("")
            lines.append("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · "
                + "\(WordAssembly.timestamp((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))) · \(session.source)")
            if !participants.all.isEmpty { lines.append("Participants: " + participants.all.joined(separator: ", ")) }
            lines.append("")
        }
        lines += MeetingMarkdown.turnLines(turns)
        return lines.joined(separator: "\n")
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
