@preconcurrency import CoreML
import Foundation
import GoblinEngines

/// CAM++ (FunASR, 3D-Speaker) turns a few seconds of one voice into 192 numbers; two stretches of the same voice point
/// the same way. Its files are pinned in GoblinEngines' speech-model-assets.json (FluidInference/campplus-coreml at an
/// exact commit, the v2 conversion) and kept in `gob.lin/models/campplus-v2`, downloaded the first time Remember voices
/// needs them. 29 MB.
public enum VoiceprintModel {
    public static let folder = "campplus-v2"
    public static let manifestID = "campplus-v2"
    public static var files: PinnedModelFiles { PinnedModelFiles(manifestID: manifestID, folder: folder) }
    static let preprocessor = "CamPlusPreprocessor_v2"
    static let model = "CamPlusPlus_v2"
    public static let dimensions = 192
}

/// 16 kHz mono samples in, a unit-length voiceprint out.
public typealias VoiceprintEmbed = @Sendable (_ samples: [Float]) async throws -> [Float]

public enum VoiceprintError: Error, LocalizedError {
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedOutput(let detail): "The voice model gave something unexpected: \(detail)"
        }
    }
}

/// Loads the pinned CAM++ once and embeds stretches of audio with it. The pipeline is the model card's: Kaldi fbank
/// from the preprocessor, each mel band's mean over the stretch taken off on the host, CAM++, then L2-normalised.
public actor VoiceprintEmbedder {
    private let preprocessor: MLModel
    private let model: MLModel
    /// Kaldi works on 16-bit sample values.
    private static let waveformScale: Float = 32_768
    /// The preprocessor takes at most 60 s; longer stretches are cut to that.
    static let longestSamples = 960_000
    /// And at least this many samples (25 ms).
    static let shortestSamples = 400

    init(directory: URL) throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        preprocessor = try MLModel(contentsOf: directory.appendingPathComponent("\(VoiceprintModel.preprocessor).mlmodelc"), configuration: cpu)
        model = try MLModel(contentsOf: directory.appendingPathComponent("\(VoiceprintModel.model).mlmodelc"), configuration: gpu)
    }

    /// Downloads and checks the pinned files when they're missing, then loads them.
    public static func load(download: (@Sendable (Double?) -> Void)? = nil) async throws -> VoiceprintEmbedder {
        let files = VoiceprintModel.files
        if !files.isDownloaded {
            download?(0)
            defer { download?(nil) }
            _ = try await files.ensureAvailable { update in
                if update.phase == .downloading, let fraction = update.fractionCompleted { download?(fraction) }
            }
        } else {
            _ = try await files.ensureAvailable()
        }
        return try VoiceprintEmbedder(directory: files.directory)
    }

    /// An embed function that loads the model on first use and keeps it for the rest of this processing run.
    public static func lazy(download: (@Sendable (Double?) -> Void)? = nil) -> VoiceprintEmbed {
        let loaded = LazyEmbedder(download: download)
        return { samples in try await loaded.embed(samples) }
    }

    public func embed(_ samples: [Float]) throws -> [Float] {
        let samples = samples.count > Self.longestSamples ? Array(samples.prefix(Self.longestSamples)) : samples
        guard samples.count >= Self.shortestSamples else { throw VoiceprintError.unexpectedOutput("\(samples.count) samples is too short") }
        let wave = try MLMultiArray(shape: [1, samples.count as NSNumber], dataType: .float32)
        let pointer = wave.dataPointer.assumingMemoryBound(to: Float32.self)
        for index in samples.indices { pointer[index] = samples[index] * Self.waveformScale }
        let features = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wave)]))
        guard let fbank = features.featureValue(for: "features")?.multiArrayValue else { throw VoiceprintError.unexpectedOutput("no features") }
        try Self.subtractBandMeans(fbank)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: fbank)]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { throw VoiceprintError.unexpectedOutput("no embedding") }
        var vector = [Float](repeating: 0, count: embedding.count)
        for index in vector.indices { vector[index] = embedding[index].floatValue }
        return Voiceprint.normalized(vector)
    }

    /// CAM++ was trained on fbank with each band's mean over the utterance removed, and neither model does it.
    static func subtractBandMeans(_ fbank: MLMultiArray) throws {
        guard fbank.dataType == .float32, fbank.shape.count == 3 else {
            throw VoiceprintError.unexpectedOutput("features \(fbank.dataType.rawValue) \(fbank.shape)")
        }
        let frames = fbank.shape[1].intValue, bands = fbank.shape[2].intValue
        guard frames > 0 else { return }
        fbank.withUnsafeMutableBytes { raw, strides in
            guard let base = raw.bindMemory(to: Float32.self).baseAddress else { return }
            for band in 0..<bands {
                let column = base + band * strides[2]
                var sum = 0.0
                for frame in 0..<frames { sum += Double(column[frame * strides[1]]) }
                let mean = Float32(sum / Double(frames))
                for frame in 0..<frames { column[frame * strides[1]] -= mean }
            }
        }
    }
}

private actor LazyEmbedder {
    private let download: (@Sendable (Double?) -> Void)?
    /// One load for every caller: two meetings processing at once share the download and the model.
    private var loading: Task<VoiceprintEmbedder, Error>?

    init(download: (@Sendable (Double?) -> Void)?) { self.download = download }

    func embed(_ samples: [Float]) async throws -> [Float] {
        let task: Task<VoiceprintEmbedder, Error>
        if let loading {
            task = loading
        } else {
            let download = download
            task = Task { try await VoiceprintEmbedder.load(download: download) }
            loading = task
        }
        do {
            let embedder = try await task.value
            // The load is shared; a caller cancelled while waiting for it doesn't start its inference.
            try Task.checkCancellation()
            return try await embedder.embed(samples)
        } catch {
            // A failed load is tried again next time; a failed embed keeps the loaded model.
            if case .failure = await task.result { loading = nil }
            throw error
        }
    }
}

public enum Voiceprint {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = max(sqrt(vector.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return vector.map { $0 / norm }
    }

    /// Cosine similarity of two unit-length voiceprints: about 0.7 and up for the same voice, under 0.4 for others.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The direction several voiceprints of one voice share.
    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == sum.count { for index in sum.indices { sum[index] += vector[index] } }
        return normalized(sum)
    }
}

/// One voice in one meeting as a voiceprint: what the post-processor called it, its track and how much clean speech
/// went into it. Kept in the meeting's voices.json while Remember voices is on, so naming it later needs no audio.
public struct MeetingVoice: Codable, Sendable, Hashable {
    public var label: String
    public var track: MeetingTrack
    /// Seconds of speech the voiceprint was made from.
    public var seconds: Double
    /// The longest clean stretch, for playing the voice back from People while the audio is kept.
    public var clipStart: Double
    public var clipEnd: Double
    public var embedding: [Float]

    public init(label: String, track: MeetingTrack, seconds: Double, clipStart: Double, clipEnd: Double, embedding: [Float]) {
        self.label = label
        self.track = track
        self.seconds = seconds
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.embedding = embedding
    }
}

/// voices.json: the meeting's voiceprints, and what matching them against People decided.
public struct MeetingVoices: Codable, Sendable, Equatable {
    /// A voice that sounds like someone in People.
    public struct Match: Codable, Sendable, Hashable {
        public var personID: UUID
        public var name: String
        public var similarity: Float
        /// Close enough that I named the voice; otherwise it's offered in Who's this?.
        public var named: Bool

        public init(personID: UUID, name: String, similarity: Float, named: Bool) {
            self.personID = personID
            self.name = name
            self.similarity = similarity
            self.named = named
        }
    }

    public var voices: [MeetingVoice] = []
    /// Label → the best match, for voices that sounded like someone.
    public var matches: [String: Match] = [:]

    public init(voices: [MeetingVoice] = [], matches: [String: Match] = [:]) {
        self.voices = voices
        self.matches = matches
    }

    public static func read(_ directory: URL) -> MeetingVoices? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.voicesFile)) else { return nil }
        return try? JSONDecoder.meeting.decode(MeetingVoices.self, from: data)
    }

    public func write(_ directory: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: directory.appendingPathComponent(MeetingStorage.voicesFile), options: .atomic)
    }
}

/// Picks the stretches of a voice clean enough to make a voiceprint from: its own turns, minus any moment someone else
/// was heard (another voice on the same track, or on a call the other track, whose sound can leak into the mic), longest
/// first up to `budget` seconds.
public enum VoiceStretches {
    /// A voiceprint needs at least this much clean speech to be worth keeping.
    public static let minimumSeconds = 4.0
    /// More than this adds little and costs time.
    public static let budget = 45.0
    /// A piece shorter than this is mostly edges.
    static let shortestPiece = 0.8

    /// `overlaps` are stretches where the diarizer heard more than one voice on this track at once: a transcript gives
    /// each word one speaker, so those would otherwise slip into whoever got the words.
    public static func pieces(of label: String, in turns: [TranscriptTurn], track: MeetingTrack, crossTrack: Bool,
                              overlaps: [ClosedRange<Double>] = []) -> [ClosedRange<Double>] {
        let mine = turns.filter { ($0.label ?? $0.speaker) == label && $0.track == track }
        let others = (turns.filter { other in
            (other.label ?? other.speaker) != label && (other.track == track || crossTrack)
        }.map { $0.start...$0.end } + overlaps).sorted { $0.lowerBound < $1.lowerBound }
        var pieces: [ClosedRange<Double>] = []
        for run in mine.flatMap(spokenRuns) where run.upperBound > run.lowerBound {
            var cursor = run.lowerBound
            for other in others where other.upperBound > cursor && other.lowerBound < run.upperBound {
                if other.lowerBound - cursor >= shortestPiece { pieces.append(cursor...other.lowerBound) }
                cursor = max(cursor, other.upperBound)
            }
            if run.upperBound - cursor >= shortestPiece { pieces.append(cursor...run.upperBound) }
        }
        var chosen: [ClosedRange<Double>] = []
        var total = 0.0
        for piece in pieces.sorted(by: { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }) where total < budget {
            // The last piece is cut to what's left of the budget.
            let length = min(piece.upperBound - piece.lowerBound, budget - total)
            guard length >= shortestPiece || chosen.isEmpty else { break }
            chosen.append(piece.lowerBound...(piece.lowerBound + length))
            total += length
        }
        return chosen.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The pieces' samples end to end.
    static func samples(_ pieces: [ClosedRange<Double>], from track: [Float]) -> [Float] {
        var result: [Float] = []
        for piece in pieces {
            let start = max(0, Int(piece.lowerBound * MeetingAudio.sampleRate))
            let end = min(track.count, Int(piece.upperBound * MeetingAudio.sampleRate))
            if end > start { result.append(contentsOf: track[start..<end]) }
        }
        return result
    }

    /// A voiceprint for every voice in `turns` with enough clean speech. Unnamed and named voices alike: a label is what
    /// the post-processor called the voice, so the name it gets later doesn't change which audio it was.
    /// A gap between kept words longer than this is something taken out of the line (said while muted, dictated), not
    /// a breath, so the audio there isn't this voice speaking to the meeting.
    static let longestPauseInRun = 1.0

    /// The stretches of a turn its kept words cover: a line can keep words either side of a muted or dictated stretch,
    /// and that stretch's audio mustn't go into the voiceprint. A turn without word timings is taken whole.
    static func spokenRuns(_ turn: TranscriptTurn) -> [ClosedRange<Double>] {
        guard let first = turn.words.first else { return turn.end > turn.start ? [turn.start...turn.end] : [] }
        var runs: [ClosedRange<Double>] = []
        var start = first.start, end = first.end
        for word in turn.words.dropFirst() {
            if word.start - end > longestPauseInRun {
                runs.append(start...max(start, end))
                start = word.start
            }
            end = max(end, word.end)
        }
        runs.append(start...max(start, end))
        return runs
    }

    /// Where two or more diarized voices overlap, merged into stretches.
    public static func overlaps(_ spans: [DiarizedSpan]) -> [ClosedRange<Double>] {
        var events: [(time: Double, delta: Int)] = []
        for span in spans where span.end > span.start { events += [(span.start, 1), (span.end, -1)] }
        events.sort { ($0.time, $0.delta) < ($1.time, $1.delta) }
        var active = 0, since: Double?
        var result: [ClosedRange<Double>] = []
        for event in events {
            active += event.delta
            if active >= 2, since == nil { since = event.time }
            if active < 2, let start = since {
                if event.time > start {
                    if let last = result.last, last.upperBound >= start { result[result.count - 1] = last.lowerBound...event.time }
                    else { result.append(start...event.time) }
                }
                since = nil
            }
        }
        return result
    }

    public static func voices(in turns: [TranscriptTurn], audio: [MeetingTrack: [Float]], inPerson: Bool,
                              spans: [DiarizedSpan] = [], microphoneExcluded: [ClosedRange<Double>] = [],
                              embed: VoiceprintEmbed) async throws -> [MeetingVoice] {
        let overlapping = overlaps(spans)
        var seen: [(String, MeetingTrack)] = []
        for turn in turns where !seen.contains(where: { $0.0 == (turn.label ?? turn.speaker) && $0.1 == turn.track }) {
            seen.append((turn.label ?? turn.speaker, turn.track))
        }
        var voices: [MeetingVoice] = []
        for (label, track) in seen {
            // Turned off meanwhile: no more voices are embedded.
            try Task.checkCancellation()
            guard let samples = audio[track], !samples.isEmpty else { continue }
            // The mic hears the call's playback; the call's track never hears the mic.
            // The diarizer listened to the call's track, or in the room to the mic.
            let diarized: MeetingTrack = inPerson ? .microphone : .system
            let pieces = pieces(of: label, in: turns, track: track, crossTrack: !inPerson && track == .microphone,
                                overlaps: (track == diarized ? overlapping : []) + (track == .microphone ? microphoneExcluded : []))
            let seconds = pieces.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            guard seconds >= minimumSeconds, let longest = pieces.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) else {
                continue
            }
            let embedding = try await embed(Self.samples(pieces, from: samples))
            voices.append(MeetingVoice(label: label, track: track, seconds: seconds, clipStart: longest.lowerBound,
                                       clipEnd: min(longest.upperBound, longest.lowerBound + 12), embedding: embedding))
        }
        return voices
    }
}

extension VoiceStretches {
    /// The voiceprints of a processed meeting's voices, from its attributed.json and whatever audio is still kept.
    /// `dictationSpans` recovers a meeting's dictations from History when it has no saved list of them, as processing
    /// does; by default from this Mac's History.
    public static func voices(inMeeting directory: URL, embed: VoiceprintEmbed,
                              dictationSpans: (@Sendable (MeetingSessionInfo) async -> [ClosedRange<Double>])? = nil)
        async throws -> [MeetingVoice] {
        let url = directory.appendingPathComponent(MeetingStorage.attributedFile)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let turns = try JSONDecoder.meeting.decode([TranscriptTurn].self, from: data)
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        var audio: [MeetingTrack: [Float]] = [:]
        for track in MeetingTrack.allCases {
            let file = directory.appendingPathComponent(MeetingStorage.audioFile(track))
            if FileManager.default.fileExists(atPath: file.path) { audio[track] = try WAVFile.readSamples(file) }
        }
        let spans = (try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.diarizationFile)))
            .flatMap { try? JSONDecoder().decode([DiarizedSpan].self, from: $0) } ?? []
        // What the mic heard while muted or dictating never went to the meeting, so it's not this voice talking to it.
        let end = Double(audio.values.map(\.count).max() ?? 0) / MeetingAudio.sampleRate
        var dictations = MeetingPostProcessor.readDictations(directory)
        if dictations == nil, let session {
            dictations = await (dictationSpans ?? { await MeetingPostProcessor.dictationSpans(from: $0) })(session)
        }
        let excluded = MeetingPostProcessor.mutedSpans(directory.appendingPathComponent(MeetingStorage.muteFile), end: end)
            + (dictations ?? [])
        return try await voices(in: turns, audio: audio, inPerson: session?.kind == .inPerson, spans: spans,
                                microphoneExcluded: excluded, embed: embed)
    }
}
