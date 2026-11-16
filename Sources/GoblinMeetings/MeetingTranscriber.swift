import Foundation
import GoblinEngines

/// A stretch of one track the live transcript didn't get to, by its place in the track's audio file.
public struct DeferredChunk: Codable, Sendable, Hashable {
    public let track: MeetingTrack
    public let startSample: Int
    public let sampleCount: Int

    public init(track: MeetingTrack, startSample: Int, sampleCount: Int) {
        self.track = track
        self.startSample = startSample
        self.sampleCount = sampleCount
    }

    init(_ chunk: SpeechChunk) { self.init(track: chunk.track, startSample: chunk.startSample, sampleCount: chunk.samples.count) }

    public var seconds: Double { Double(sampleCount) / MeetingAudio.sampleRate }

    /// Whether a segment is this chunk's transcript: same track, its middle inside the chunk. Chunks don't overlap.
    func covers(_ segment: TranscriptSegment) -> Bool {
        let start = Double(startSample) / MeetingAudio.sampleRate, middle = (segment.start + segment.end) / 2
        return segment.track == track && middle >= start && middle < start + seconds
    }
}

/// Why a chunk was left for after the call.
public enum DeferralReason: Sendable, Equatable {
    /// The queue was full: the speech model is slower than the call.
    case behind
    /// The speech model couldn't load or failed on the chunk.
    case failed(String)
}

/// Transcribes speech chunks from both tracks in arrival order on one speech engine.
public final class MeetingTranscriber: @unchecked Sendable {
    private let engine: any PCMSpeechEngine
    private let continuation: AsyncStream<(Int, SpeechChunk)>.Continuation
    private let maximumBacklog: Int?
    private let onDeferred: @Sendable (DeferredChunk, DeferralReason) -> Void
    private var worker: Task<Void, Never>?
    private let lock = NSLock()
    private var queued: [Int: DeferredChunk] = [:]
    private var nextID = 0
    private var abandoned = false

    /// `maximumBacklog` caps the chunks waiting in memory; past it a chunk goes to `onDeferred` instead, to be
    /// transcribed from the audio after the call. A chunk the engine fails on goes there too. Nil queues everything,
    /// for a replay that feeds audio faster than real time.
    public init(engine: any PCMSpeechEngine, options: RecognitionOptions = .init(language: "en"), maximumBacklog: Int? = nil,
                onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                onError: @escaping @Sendable (String) -> Void,
                onDeferred: @escaping @Sendable (DeferredChunk, DeferralReason) -> Void = { _, _ in },
                onReady: @escaping @Sendable () -> Void = {}) {
        self.engine = engine
        self.maximumBacklog = maximumBacklog
        self.onDeferred = onDeferred
        let (stream, continuation) = AsyncStream<(Int, SpeechChunk)>.makeStream()
        self.continuation = continuation
        worker = Task.detached(priority: .userInitiated) { [engine, lock] in
            // Chunks queue up while the model loads; capture never waits for it.
            do { try await engine.prepare(); onReady() } catch { onError("speech model failed to load: \(error.localizedDescription)") }
            for await (id, chunk) in stream {
                guard lock.withLock({ !self.abandoned }) else { break }
                let started = Date()
                do {
                    if let segment = try await Self.transcribe(chunk, engine: engine, options: options) {
                        var segment = segment
                        segment.decodeMilliseconds = Date().timeIntervalSince(started) * 1_000
                        onSegment(segment)
                    }
                } catch {
                    onError("transcription failed for a \(chunk.track.rawValue) chunk: \(error.localizedDescription)")
                    onDeferred(DeferredChunk(chunk), .failed(error.localizedDescription))
                }
                lock.withLock { _ = self.queued.removeValue(forKey: id) }
            }
        }
    }

    /// One chunk's transcript on the meeting's timeline, or nil when it holds no words.
    public static func transcribe(_ chunk: SpeechChunk, engine: any PCMSpeechEngine,
                                  options: RecognitionOptions) async throws -> TranscriptSegment? {
        let result = try await engine.transcribe(samples: chunk.samples, options: options)
        let words = WordAssembly.words(from: result, offset: chunk.startSeconds)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let end = chunk.startSeconds + Double(chunk.samples.count) / MeetingAudio.sampleRate
        return TranscriptSegment(track: chunk.track, start: words.first?.start ?? chunk.startSeconds, end: words.last?.end ?? end,
                                 text: text, words: words, decodeMilliseconds: 0)
    }

    /// Transcribes chunks one after another, such as the ones left for after the call. Any failure throws, so a
    /// retry starts from the same chunks.
    public static func transcribeAll(_ chunks: [SpeechChunk], engine: any PCMSpeechEngine,
                                     options: RecognitionOptions) async throws -> [TranscriptSegment] {
        try await engine.prepare()
        var segments: [TranscriptSegment] = []
        for chunk in chunks {
            try Task.checkCancellation()
            if let segment = try await transcribe(chunk, engine: engine, options: options) { segments.append(segment) }
        }
        return segments
    }

    /// Chunks waiting for the engine, including the one being decoded.
    public var backlog: Int { lock.withLock { queued.count } }

    public func submit(_ chunk: SpeechChunk) {
        let id = lock.withLock { () -> Int? in
            if abandoned { return nil }
            if let maximumBacklog, queued.count >= maximumBacklog { return nil }
            nextID += 1
            queued[nextID] = DeferredChunk(chunk)
            return nextID
        }
        guard let id else {
            onDeferred(DeferredChunk(chunk), .behind)
            return
        }
        continuation.yield((id, chunk))
    }

    public func finish() async {
        continuation.finish()
        await worker?.value
    }

    /// Stops taking chunks and hands back the ones not transcribed yet, oldest first, such as when a quit can't wait.
    /// The chunk being decoded may still finish, but nothing after it starts.
    public func abandon() -> [DeferredChunk] {
        continuation.finish()
        return lock.withLock {
            abandoned = true
            defer { queued.removeAll() }
            return queued.sorted { $0.key < $1.key }.map(\.value)
        }
    }
}
