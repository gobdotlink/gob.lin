import FluidAudio
import Foundation
import GoblinCore
import GoblinEngines
import os

/// 16 kHz mono microphone samples and the call's own sound (the system track, cut or padded to the same length) in;
/// the microphone with the call's sound taken out, the same length and on the same timeline.
public typealias MeetingEchoCanceller = @Sendable (_ microphone: [Float], _ reference: [Float], _ log: @Sendable (String) -> Void) async throws -> [Float]

/// LocalVQE v1.3 (localai-org, Apache-2.0) in FluidInference's Core ML conversion, the 256 ms file: takes a call's
/// sound out of the microphone after the call. Its files are pinned in GoblinEngines' speech-model-assets.json
/// (FluidInference/localvqe-coreml at an exact commit, with sizes and SHA-256) and kept in `gob.lin/models/localvqe`,
/// downloaded the first time a call is processed. 20 MB.
public enum MeetingEchoModel {
    public static let folder = "localvqe"
    public static let manifestID = "localvqe-v1.3-256ms"
    public static var files: PinnedModelFiles { PinnedModelFiles(manifestID: manifestID, folder: folder) }
    static let config = LocalVqeConfig(variant: .v13, chunk: .batch256ms)
    /// The compiled bundle FluidAudio loads for `config`, which the pinned files must hold.
    static var bundleName: String { ModelNames.LocalVQE.modelFile(variant: config.variant, chunk: config.chunk) }
}

extension MeetingPostProcessOptions {
    /// LocalVQE from FluidAudio, loaded from gob.lin's pinned copy; downloads and checks it on first use.
    public static func localVQE(modelDownload: (@Sendable (Double?) -> Void)? = nil) -> MeetingEchoCanceller {
        let files = MeetingEchoModel.files
        return { microphone, reference, log in
            try await acquire(files, named: "the echo canceller", modelDownload: modelDownload, log: log)
            let manager = try LocalVqeManager(config: MeetingEchoModel.config, modelDirectory: files.directory)
            // A few seconds at a time rather than `process(mic:reference:)`, which would hold another copy of both
            // whole tracks. The audio is the same: the stream drops the model's one-hop delay and `flush` drains it, so
            // sample i out is sample i in.
            let stream = try await manager.makeStream()
            let block = MeetingEchoModel.config.chunk.samplesPerCall * 16
            var cleaned: [Float] = []
            cleaned.reserveCapacity(microphone.count)
            var start = 0
            while start < microphone.count {
                let end = min(start + block, microphone.count)
                cleaned += try await stream.enhance(mic: Array(microphone[start..<end]), reference: Array(reference[start..<end]))
                start = end
            }
            cleaned += try await stream.flush()
            return cleaned
        }
    }

    /// Checks a pinned model's files, downloading them first when they aren't all here and telling `modelDownload`.
    static func acquire(_ files: PinnedModelFiles, named name: String, modelDownload: (@Sendable (Double?) -> Void)?,
                        log: @Sendable (String) -> Void) async throws {
        guard !files.isDownloaded else { _ = try await files.ensureAvailable(); return }
        log("downloading \(name) (\(files.downloadBytes / 1_000_000) MB), once")
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
    }
}

/// One progress report for the models a run downloads side by side (the speaker model and the echo canceller): each
/// one's fraction weighted by its size, then nil once every download that started has finished.
final class CombinedDownload: @unchecked Sendable {
    private let report: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var parts: [String: (fraction: Double, bytes: Double)] = [:]
    private var finished: Set<String> = []

    init(_ report: @escaping @Sendable (Double?) -> Void) { self.report = report }

    func part(_ name: String, bytes: Int64) -> @Sendable (Double?) -> Void {
        { [self] fraction in
            let overall: Double? = lock.withLock {
                if let fraction {
                    parts[name] = (fraction, Double(max(1, bytes)))
                    finished.remove(name)
                } else if parts[name] != nil {
                    // Finished or failed: a full share until the others finish, so the total never goes backwards.
                    parts[name]?.fraction = 1
                    finished.insert(name)
                }
                guard finished.count < parts.count else {
                    parts.removeAll()
                    finished.removeAll()
                    return nil
                }
                return parts.values.reduce(0) { $0 + $1.fraction * $1.bytes } / parts.values.reduce(0) { $0 + $1.bytes }
            }
            report(overall)
        }
    }
}

/// Where a call's microphone lines come from.
enum EchoCancelledMicrophone {
    /// The live transcript's: echo cancellation is off, or has no canceller or speech model, or the meeting was in person.
    case notRun
    /// The live transcript's, because echo cancellation failed.
    case failed
    /// Transcribed from the microphone with the call's sound taken out; the times are nil when an earlier run's lines
    /// were used again.
    case transcribed([TranscriptSegment], cancelSeconds: Double?, transcribeSeconds: Double?)
}

struct EchoCancellationError: Error, LocalizedError {
    let samples: Int, expected: Int
    var errorDescription: String? { "the echo canceller returned \(samples) samples for \(expected)" }
}

extension MeetingPostProcessor {
    /// Whether processing this folder would take the call's sound out of the microphone: a call (not a conversation in
    /// the room) with both tracks' audio still here.
    public static func cancelsEcho(in directory: URL) -> Bool {
        let session = try? JSONDecoder.meeting.decode(MeetingSessionInfo.self,
                                                      from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
        return session?.kind != .inPerson && MeetingTrack.allCases.allSatisfy {
            MeetingStore.audioBytes(directory.appendingPathComponent(MeetingStorage.audioFile($0))) > 44
        }
    }

    /// Takes the call's sound (the system track) out of the microphone track and transcribes what's left, cut by the
    /// same chunker as the live transcript, into microphone-echo-cancelled.jsonl. On loudspeakers the live microphone
    /// lines hold the other side too, wherever the recogniser heard it differently from the system track; and where the
    /// person spoke over someone, only cancelling the sound gets their words back.
    ///
    /// Only the live lines are used when it's off, or has no canceller or speech model, or the meeting was in person,
    /// or it fails (which is logged; cancellation still throws). With either track's audio deleted after an earlier run,
    /// the lines that run wrote are used again.
    ///
    /// With `tellingVoicesApart`, the speaker model also listens to the microphone with the call's sound taken out, while
    /// it's transcribed, so the call's own voices coming out of the loudspeakers aren't taken for people in the room.
    /// `voices` is nil when it didn't, or couldn't.
    static func echoCancelledMicrophone(directory: URL, microphone: [Float], system: [Float], session: MeetingSessionInfo?,
                                        options: MeetingPostProcessOptions, tellingVoicesApart: Bool = false,
                                        log: @Sendable (String) -> Void) async throws -> (lines: EchoCancelledMicrophone, voices: [DiarizedSpan]?) {
        var voices: [DiarizedSpan]?
        let lines = try await echoCancelledMicrophone(directory: directory, microphone: microphone, system: system, session: session,
                                                      options: options, tellingVoicesApart: tellingVoicesApart, voices: &voices, log: log)
        return (lines, voices)
    }

    /// The speaker model's spans on a call's microphone; nil when it can't run, which only leaves the microphone one
    /// voice, as it always was.
    static func microphoneVoices(_ samples: [Float], options: MeetingPostProcessOptions,
                                 log: @Sendable (String) -> Void) async throws -> [DiarizedSpan]? {
        guard samples.count > Int(MeetingAudio.sampleRate) else { return nil }
        do {
            return try await options.diarizer(samples, log).spans.sorted { $0.start < $1.start }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            log("microphone voices: \(error.localizedDescription)")
            return nil
        }
    }

    private static func echoCancelledMicrophone(directory: URL, microphone: [Float], system: [Float], session: MeetingSessionInfo?,
                                                options: MeetingPostProcessOptions, tellingVoicesApart: Bool,
                                                voices: inout [DiarizedSpan]?,
                                                log: @Sendable (String) -> Void) async throws -> EchoCancelledMicrophone {
        let url = directory.appendingPathComponent(MeetingStorage.echoCancelledSegmentsFile)
        guard options.cancelsEcho, session?.kind != .inPerson else { return .notRun }
        guard !microphone.isEmpty, !system.isEmpty else {
            guard FileManager.default.fileExists(atPath: url.path) else { return .notRun }
            return .transcribed(try loadSegments(url), cancelSeconds: nil, transcribeSeconds: nil)
        }
        guard let cancel = options.echoCanceller, let transcribe = options.transcribeLater else { return .notRun }
        // Both tracks are on the session's timeline from its start; the system track may end a little earlier or later.
        var reference = system
        if reference.count < microphone.count {
            reference += [Float](repeating: 0, count: microphone.count - reference.count)
        } else if reference.count > microphone.count {
            reference.removeLast(reference.count - microphone.count)
        }
        do {
            log("cancelling echo in \(Int(Double(microphone.count) / MeetingAudio.sampleRate)) s of microphone audio")
            let started = Date()
            var cleaned = try await cancel(microphone, reference, log)
            guard cleaned.count == microphone.count else { throw EchoCancellationError(samples: cleaned.count, expected: microphone.count) }
            let cancelSeconds = Date().timeIntervalSince(started)
            // Clamped as the recorder clamps what it writes: the speech model rejects samples past ±1. In place, since
            // a copy of the track is a quarter of a gigabyte per recorded hour.
            for index in cleaned.indices where !(cleaned[index] >= -1 && cleaned[index] <= 1) {
                cleaned[index] = cleaned[index].isFinite ? max(-1, min(1, cleaned[index])) : 0
            }
            let chunks = SpeechChunker.chunks(of: cleaned, track: .microphone)
            let transcribing = Date()
            let audio = cleaned
            async let heard = tellingVoicesApart ? microphoneVoices(audio, options: options, log: log) : nil
            let segments = try await transcribe(chunks, RecognitionOptions(language: session?.language)).sorted { $0.start < $1.start }
            voices = try await heard
            let transcribeSeconds = Date().timeIntervalSince(transcribing)
            let encoder = JSONEncoder()
            try segments.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
                .write(to: url, atomically: true, encoding: .utf8)
            return .transcribed(segments, cancelSeconds: cancelSeconds, transcribeSeconds: transcribeSeconds)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            log("echo cancellation failed, so the live microphone lines stand: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Words on these lines; a line without word timings counts its text's.
    static func wordCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + ($1.words.isEmpty ? $1.text.split(whereSeparator: \.isWhitespace).count : $1.words.count) }
    }
}

/// An echo canceller that takes audio as it comes: equal lengths of microphone and the call's sound in, the cleaned
/// microphone out, sample i out for sample i in once `flush` has drained what it holds.
struct LiveEchoStream: Sendable {
    let enhance: @Sendable (_ microphone: [Float], _ reference: [Float]) async throws -> [Float]
    let flush: @Sendable () async throws -> [Float]
}

/// Takes the call's sound out of the microphone while a call records, so the live transcript doesn't give the person
/// the other side's words when the call plays on loudspeakers. It pairs each microphone sample with the call's sound
/// at the same moment (both tracks are on the session's timeline), runs the pair through the echo canceller, and cuts
/// the cleaned microphone into chunks for the live transcript. The microphone's WAV stays as it was heard, for the
/// pass after the call.
///
/// The microphone waits for the call's sound, but only while the call's track keeps arriving: once nothing has come from
/// it for `stallSeconds` and none of it is still queued (the tap stopped, or the call app went quiet) the microphone
/// goes on against silence. Arrival is timed as the track hands its audio over, and queued audio counts as arrived, so
/// neither a burst (the audio heard before a recording was accepted, a replay) nor a worker running behind pairs the
/// microphone with silence while the call's sound for it is still to be read. Without the model (not downloaded yet, or it fails), the microphone goes to the live
/// transcript as heard, without waiting.
final class LiveEchoCanceller: @unchecked Sendable {
    private enum Input: Sendable { case microphone([Float]), system([Float]) }
    static let stallSeconds = 0.5
    private let inputs: AsyncStream<Input>.Continuation
    private let worker: Task<Void, Never>
    /// When the call's track last handed over audio, and how many of its pieces the worker hasn't read yet.
    private let system = OSAllocatedUnfairLock(initialState: (arrived: ContinuousClock.now, queued: 0))

    /// `onSamples` hears the microphone as the live transcript gets it, in order from the session's first sample: with
    /// the call's sound taken out, or as heard when it can't be.
    init(load: @escaping @Sendable () async throws -> LiveEchoStream?, log: @escaping @Sendable (String) -> Void,
         onSamples: (@Sendable ([Float]) -> Void)? = nil, onChunk: @escaping @Sendable (SpeechChunk) -> Void) {
        let (stream, inputs) = AsyncStream.makeStream(of: Input.self)
        self.inputs = inputs
        let system = system
        worker = Task {
            var work = Work(log: log, onChunk: onChunk, onSamples: onSamples)
            do {
                work.stream = try await load()
                log(work.stream == nil ? "live echo cancellation off: the echo canceller isn't downloaded yet" : "live echo cancellation on")
            } catch {
                log("live echo cancellation off: \(error.localizedDescription)")
            }
            for await input in stream {
                switch input {
                case .microphone(let samples): work.pairing.addMicrophone(samples)
                case .system(let samples):
                    work.pairing.addReference(samples)
                    system.withLock { $0.queued -= 1 }
                }
                let (arrived, queued) = system.withLock { ($0.arrived, $0.queued) }
                let stalled = queued == 0 && ContinuousClock.now - arrived > .seconds(Self.stallSeconds)
                if let pair = work.pairing.take(all: stalled || work.stream == nil) { await work.cancel(pair.microphone, pair.reference) }
            }
            await work.finish()
        }
    }

    deinit { inputs.finish() }

    /// The microphone's samples, in order, on the session's timeline.
    func microphone(_ samples: [Float]) { inputs.yield(.microphone(samples)) }

    /// The call's sound, in order, on the same timeline.
    func system(_ samples: [Float]) {
        system.withLock { $0 = (.now, $0.queued + 1) }
        inputs.yield(.system(samples))
    }

    /// After both tracks have finished: cleans what's left and hands over the last chunks.
    func finish() async {
        inputs.finish()
        await worker.value
    }

    /// The worker's state, only ever touched by the worker.
    private struct Work {
        let log: @Sendable (String) -> Void
        let onChunk: @Sendable (SpeechChunk) -> Void
        let onSamples: (@Sendable ([Float]) -> Void)?
        var stream: LiveEchoStream?
        var pairing = EchoPairing()
        var chunker = SpeechChunker(track: .microphone)
        /// Microphone samples given to the canceller and not back yet: what goes on as heard if it fails.
        var held: [Float] = []

        mutating func cancel(_ microphone: [Float], _ reference: [Float]) async {
            guard let stream else { return emit(microphone) }
            held += microphone
            do {
                let cleaned = try await stream.enhance(microphone, reference)
                held.removeFirst(min(cleaned.count, held.count))
                emit(cleaned)
            } catch { giveUp(error) }
        }

        mutating func finish() async {
            if let pair = pairing.take(all: true) { await cancel(pair.microphone, pair.reference) }
            if let stream {
                do {
                    let tail = try await stream.flush()
                    held.removeFirst(min(tail.count, held.count))
                    emit(tail)
                } catch { giveUp(error) }
            }
            for chunk in chunker.finish() { onChunk(chunk) }
        }

        /// The rest of the call goes to the live transcript as heard, from the first sample not yet handed on.
        mutating func giveUp(_ error: any Error) {
            log("live echo cancellation stopped: \(error.localizedDescription)")
            stream = nil
            emit(held)
            held = []
        }

        /// Clamped as the recorder clamps what it writes: the speech model rejects samples past ±1.
        mutating func emit(_ samples: [Float]) {
            let clamped = samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
            onSamples?(clamped)
            for chunk in chunker.feed(clamped) { onChunk(chunk) }
        }
    }

    /// LocalVQE from gob.lin's pinned copy, when the pass after a call has downloaded it; nil before then. A call never
    /// waits on the download.
    static let localVQE: @Sendable () async throws -> LiveEchoStream? = {
        let files = MeetingEchoModel.files
        guard files.isDownloaded else { return nil }
        _ = try await files.ensureAvailable()
        let manager = try LocalVqeManager(config: MeetingEchoModel.config, modelDirectory: files.directory)
        let stream = try await manager.makeStream()
        return LiveEchoStream(enhance: { try await stream.enhance(mic: $0, reference: $1) }, flush: { try await stream.flush() })
    }
}

/// Lines up the microphone with the call's sound by sample, both counted from the session's start, and hands out
/// stretches of microphone with the call's sound for the same samples. Where the call's track has nothing for a
/// sample (it stalled), the pair gets silence there.
struct EchoPairing {
    /// The call's sound kept ahead of the microphone, such as while the mic is gone: a minute, trimmed 10 s at a time.
    static let maximumReference = 960_000
    static let trimStep = 160_000

    /// The session sample the next microphone sample is.
    private(set) var position = 0
    private var microphone: [Float] = []
    private var reference: [Float] = []
    /// The session sample `reference[0]` is.
    private var referenceStart = 0

    mutating func addMicrophone(_ samples: [Float]) { microphone += samples }

    mutating func addReference(_ samples: [Float]) {
        reference += samples
        trim()
    }

    /// The microphone heard so far that the call's sound has caught up with; with `all`, all of it. Nil when there's
    /// nothing to hand out.
    mutating func take(all: Bool) -> (microphone: [Float], reference: [Float])? {
        let count = all ? microphone.count : min(microphone.count, referenceStart + reference.count - position)
        guard count > 0 else { return nil }
        let taken = Array(microphone.prefix(count))
        microphone.removeFirst(count)
        var paired = [Float](repeating: 0, count: count)
        let from = max(position, referenceStart), to = min(position + count, referenceStart + reference.count)
        if from < to {
            paired.replaceSubrange(from - position..<to - position, with: reference[from - referenceStart..<to - referenceStart])
        }
        position += count
        trim()
        return (taken, paired)
    }

    /// Drops the call's sound the microphone has passed, and the oldest beyond `maximumReference`.
    private mutating func trim() {
        let passed = min(reference.count, max(0, position - referenceStart))
        var drop = passed
        if reference.count - passed > Self.maximumReference + Self.trimStep { drop = reference.count - Self.maximumReference }
        guard drop > 0 else { return }
        reference.removeFirst(drop)
        referenceStart += drop
    }
}
