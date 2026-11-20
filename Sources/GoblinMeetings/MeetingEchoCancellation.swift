import FluidAudio
import Foundation
import GoblinCore
import GoblinEngines

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
    static func echoCancelledMicrophone(directory: URL, microphone: [Float], system: [Float], session: MeetingSessionInfo?,
                                        options: MeetingPostProcessOptions,
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
            let segments = try await transcribe(chunks, RecognitionOptions(language: session?.language)).sorted { $0.start < $1.start }
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
