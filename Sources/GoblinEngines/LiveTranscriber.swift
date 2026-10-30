import Foundation

public enum LiveRecoveryReason: String, Sendable {
    case windowLimit, decodeFailed, decodeUnavailable, modelPreviewUnavailable, overlapMismatch, timingUnavailable, inputDiscontinuity, invalidSamples
}

public struct LiveTranscript: Sendable, Equatable {
    public let committedText: String
    public let tentativeText: String
    public let recoveryReason: LiveRecoveryReason?
}

/// How a live take ends at key-up.
public struct LiveEnding: Sendable {
    /// The final transcript, or nil when the original recording must be recognized instead.
    public let result: TranscriptionResult?
    /// With a nil `result`: a best-effort transcript of the whole take from the live window. Only for work that
    /// is discarded unless the original recording's transcript turns out to match it exactly.
    public let draft: String?
    /// Decode time spent on the draft, when it needed one.
    public let draftMilliseconds: Double?

    init(_ result: TranscriptionResult?, draft: String? = nil, draftMilliseconds: Double? = nil) {
        self.result = result; self.draft = draft; self.draftMilliseconds = draftMilliseconds
    }
}

/// Decodes only the retained tail; original disk audio is the recovery source.
public actor LiveTranscriber {
    public nonisolated let updates: AsyncStream<LiveTranscript>
    private let continuation: AsyncStream<LiveTranscript>.Continuation
    /// The settled text each time a pause's whole decode finishes, for work that can start before key-up.
    public nonisolated let settledTexts: AsyncStream<String>
    private let settledContinuation: AsyncStream<String>.Continuation
    private let engine: Task<any PCMSpeechEngine, Error>
    private let options: RecognitionOptions
    private let maximumSamples: Int
    private var samples: [Float] = []
    private var origin: Int64 = 0
    private var received: Int64 = 0
    private var lastScheduled: Int64 = 0
    private var settled = ""
    private var committed: [Word] = []
    private var previous: [Word] = []
    private var previousText = ""
    private var tentative = ""
    private var inference: Task<Void, Never>?
    private var generation = 0
    private var consecutiveDecodeFailures = 0
    private var recoveryReason: LiveRecoveryReason?
    private var previewHasGap = false
    /// False once audio left the window without being transcribed: the window can no longer draft the whole take.
    private var draftable = true
    /// The final transcript is built in chunks while the user talks. A chunk closes at a gap between words, at a pause or
    /// once it nears a window, and is decoded once in the background with the speech before it as context, as a decode of
    /// the whole recording hears it. Key-up decodes only the open chunk. This replaces previews' text, which comes from
    /// partial windows and drops words a decode with context keeps.
    private var history: [Float] = []
    private var historyOrigin: Int64 = 0
    private var chunkStart: Int64 = 0
    /// `heard`: the previews heard words in the chunk, so an empty decode of it lost them.
    private var chunks: [(text: Task<String?, Never>, pause: Bool, heard: Bool)] = []
    /// False once a chunk couldn't close between words in time, or audio went missing.
    private var chunking = true
    private var cancelled = false
    private var finishing = false
    private var previewStopped = false
    public private(set) var requiresFinalRecovery = false
    public private(set) var computeMilliseconds = 0.0
    private var chunksUsable: Bool { draftable && chunking && received - chunkStart <= Int64(maximumSamples) }

    public init(engine: Task<any PCMSpeechEngine, Error>, maximumWindowSamples: Int = 240_000,
                options: RecognitionOptions = .init(), previewAvailable: Bool = true) {
        self.engine = engine
        self.options = options
        maximumSamples = min(240_000, max(6_400, maximumWindowSamples))
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (settledTexts, settledContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        if !previewAvailable {
            recoveryReason = .modelPreviewUnavailable
            requiresFinalRecovery = true
            draftable = false
            continuation.yield(.init(committedText: "", tentativeText: "", recoveryReason: .modelPreviewUnavailable))
        }
    }

    public func append(_ frame: [Float], at samplePosition: Int64) {
        guard !cancelled, !finishing, !unavailable else { return }
        guard samplePosition >= received else {
            draftable = false
            degrade(.inputDiscontinuity, needsOriginal: true)
            return
        }
        if samplePosition != received {
            draftable = false
            history.removeAll()
            historyOrigin = samplePosition
            samples.removeAll()
            origin = samplePosition
            received = samplePosition
            generation += 1
            previous = []
            previousText = ""
            degrade(.inputDiscontinuity, needsOriginal: true)
        }
        guard frame.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            draftable = false
            received += Int64(frame.count)
            history.removeAll()
            historyOrigin = received
            samples.removeAll()
            origin = received
            generation += 1
            degrade(.invalidSamples, needsOriginal: true)
            return
        }
        // Keep the in-flight snapshot valid, but allow at most three seconds of pending audio.
        guard frame.count <= maximumSamples + 48_000 - samples.count else {
            draftable = false
            degrade(.decodeUnavailable, needsOriginal: true)
            return
        }
        received += Int64(frame.count)
        samples.append(contentsOf: frame)
        history.append(contentsOf: frame)
        // Two windows: a chunk of up to one, and up to one of speech before it.
        if history.count > 2 * maximumSamples + 48_000 {
            let excess = history.count - 2 * maximumSamples
            history.removeFirst(excess)
            historyOrigin += Int64(excess)
        }
        if chunking, received - chunkStart > Int64(maximumSamples) + 48_000 { chunking = false }
        scheduleIfNeeded()
    }

    /// Closes the open chunk at `boundary`, a point between words, and decodes it with the speech before it as context.
    private func closeChunk(at boundary: Int64, pause: Bool, heard: Bool) {
        guard chunking, draftable, boundary > chunkStart else { return }
        // Up to a second after the boundary is heard as right context, so the chunk's last words aren't read as the end of
        // an utterance (a stray full stop, or a clipped word).
        let through = min(received, boundary + 16_000)
        guard through - chunkStart <= Int64(maximumSamples), let window = contextWindow(through: through), window.origin <= chunkStart else {
            chunking = false; return
        }
        let engine = engine, options = options, start = chunkStart
        chunks.append((Task {
            guard let runtime = try? await engine.value else { return nil }
            return (try? await Self.decode(window, from: start, before: boundary, runtime: runtime, options: options))??.text
        }, pause, heard))
        chunkStart = boundary
        // At a pause the take may be over: its text so far can go to cleanup while the key is still held.
        if pause {
            let count = chunks.count
            Task { [weak self] in await self?.publishChunks(count) }
        }
    }

    /// Once the open chunk reaches two thirds of a window, it closes at the widest gap between committed words after its
    /// first quarter window.
    private func closeLongChunk() {
        guard chunking, received - chunkStart >= Int64(maximumSamples) * 2 / 3 else { return }
        let words = committed.filter { $0.start >= chunkStart }
        var best: (gap: Int64, boundary: Int64)?
        for (word, next) in zip(words, words.dropFirst()) where word.end >= chunkStart + Int64(maximumSamples) / 4 {
            let gap = next.start - word.end
            if gap >= 2_400, gap >= best?.gap ?? 0 { best = (gap, word.end + gap / 2) }
        }
        if let best { closeChunk(at: best.boundary, pause: false, heard: true) }
    }

    private func publishChunks(_ count: Int) async {
        guard let text = await chunkText(), !cancelled, !previewStopped, chunks.count == count, !text.isEmpty else { return }
        settledContinuation.yield(text)
    }

    /// The closed chunks' text, or nil if a decode failed or kept none of the words the previews heard in its chunk.
    private func chunkText() async -> String? {
        var parts: [String] = []
        for chunk in chunks {
            guard let text = await chunk.text.value, !(text.isEmpty && chunk.heard) else { return nil }
            parts.append(text)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// At key-up: the closed chunks as decoded, then what the previews heard in the open one.
    public func speculativeText() async -> String {
        guard chunksUsable, let closed = await chunkText() else { return Self.join(committedText, tentative) }
        return Self.join(closed, Self.text(openPreviewWords))
    }

    /// The words the previews heard in the open chunk.
    private var openPreviewWords: [Word] { (committed + previous).filter { $0.start >= chunkStart - 1_600 } }

    /// For diagnostics: closed chunks, and how many closed at a pause.
    public func chunkDiagnostics() -> (chunks: Int, pauses: Int, chunking: Bool) {
        (chunks.count, chunks.filter(\.pause).count, chunking)
    }

    /// Up to one window of audio ending at `end`.
    private func contextWindow(through end: Int64) -> (audio: [Float], origin: Int64)? {
        let start = max(historyOrigin, end - Int64(maximumSamples))
        guard end > start, end <= historyOrigin + Int64(history.count) else { return nil }
        return (Array(history[Int(start - historyOrigin)..<Int(end - historyOrigin)]), start)
    }

    /// The words a decode of `window` places in its chunk: starting from `start` and, for a closed chunk, before `end`.
    /// Boundaries sit between words, and one shared threshold just before each assigns every word to exactly one chunk.
    /// Start times are compared, not gaps: a word's end can stretch to punctuation emitted after it, which moved gaps and
    /// repeated words at seams on real dictation. Nil without word timings.
    private static func decode(_ window: (audio: [Float], origin: Int64), from start: Int64, before end: Int64? = nil,
                               runtime: any PCMSpeechEngine, options: RecognitionOptions) async throws -> (text: String, presence: SpeechPresence?)? {
        let result = try await runtime.transcribe(samples: window.audio, options: options)
        if result.speechPresence == .notDetected { return ("", .notDetected) }
        // A window holding only this chunk needs no timings.
        if window.origin >= start, end == nil { return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.speechPresence) }
        guard let words = words(result, origin: window.origin) else { return nil }
        let kept = words.filter { word in word.start >= start - 1_600 && (end.map { word.start < $0 - 1_600 } ?? true) }
        return (text(kept), result.speechPresence)
    }

    /// Call only after capture and its ordered frame consumer have drained.
    public func finish() async throws -> TranscriptionResult? { try await finishWithDraft().result }

    /// Call only after capture and its ordered frame consumer have drained.
    public func finishWithDraft() async throws -> LiveEnding {
        finishing = true
        settledContinuation.finish()
        await inference?.value
        try checkCancellation()
        defer { continuation.finish() }
        if samples.count > maximumSamples { degrade(.decodeUnavailable, needsOriginal: true) }
        if chunksUsable, let ending = try await finishChunks() { return ending }
        guard !samples.isEmpty else {
            return requiresFinalRecovery ? LiveEnding(nil) : LiveEnding(TranscriptionResult(text: committedText))
        }
        let trusted = !requiresFinalRecovery
        guard trusted || draftable else { return LiveEnding(nil) }
        let runtime = try await engine.value
        try checkCancellation()
        let start = ContinuousClock.now
        let result: TranscriptionResult
        do { result = try await runtime.transcribe(samples: samples, options: options) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if trusted { degrade(.decodeFailed, needsOriginal: true) }
            return LiveEnding(nil)
        }
        let elapsed = Self.milliseconds(since: start)
        computeMilliseconds += elapsed
        try checkCancellation()
        let recover = { LiveEnding(nil, draft: self.draft(from: result), draftMilliseconds: elapsed) }
        guard trusted else { return recover() }
        if result.speechPresence == .notDetected {
            // An explicit no-speech result must not trigger an ungated second recognition.
            return previousText.isEmpty ? LiveEnding(TranscriptionResult(text: committedText, speechPresence: .notDetected)) : recover()
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return recover() }
        if committed.isEmpty { return LiveEnding(TranscriptionResult(text: Self.join(settled, result.text))) }
        guard let words = Self.words(result, origin: origin), let remainder = remainingWords(words) else {
            degrade(.overlapMismatch, needsOriginal: true)
            return recover()
        }
        return LiveEnding(TranscriptionResult(text: Self.join(settled, Self.text(committed + remainder))))
    }

    /// The closed chunks, then the open one decoded with the speech before it. Nil leaves key-up to the other paths.
    private func finishChunks() async throws -> LiveEnding? {
        let runtime = try await engine.value
        try checkCancellation()
        let start = ContinuousClock.now
        var open: (text: String, presence: SpeechPresence?)?
        if received > chunkStart, let window = contextWindow(through: received), window.origin <= chunkStart {
            do { open = try await Self.decode(window, from: chunkStart, runtime: runtime, options: options) }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
        } else if received == chunkStart { open = ("", nil) }
        computeMilliseconds += Self.milliseconds(since: start)
        try checkCancellation()
        guard let open, let closed = await chunkText() else { return nil }
        // Previews that heard words the decodes didn't keep leave the take to the other paths rather than drop them.
        if open.text.isEmpty, !openPreviewWords.isEmpty || (committed.isEmpty && previous.isEmpty && !previousText.isEmpty) { return nil }
        let text = Self.join(closed, open.text)
        if text.isEmpty, !committed.isEmpty || !previousText.isEmpty || !settled.isEmpty { return nil }
        return LiveEnding(TranscriptionResult(text: text, speechPresence: text.isEmpty && open.presence == .notDetected ? .notDetected : nil))
    }

    /// The whole take as the window last heard it. When the window's words no longer line up with the committed
    /// ones, its own reading of the audio it holds replaces those committed words.
    private func draft(from result: TranscriptionResult) -> String? {
        guard draftable else { return nil }
        let text: String
        if let words = Self.words(result, origin: origin), let remainder = remainingWords(words) {
            text = Self.join(settled, Self.text(committed + remainder))
        } else {
            let tail = result.speechPresence == .notDetected ? "" : result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = Self.join(settled, Self.join(Self.text(committed.filter { $0.end <= origin }), tail))
        }
        return text.isEmpty ? nil : text
    }

    /// Stop publishing previews immediately, while still accepting the capture's final frames.
    public func stopPreview() {
        previewStopped = true
        continuation.finish()
        settledContinuation.finish()
    }

    public func cancel() async {
        cancelled = true
        inference?.cancel()
        for chunk in chunks { chunk.text.cancel() }
        continuation.finish()
        settledContinuation.finish()
        await inference?.value
        samples.removeAll()
    }

    private var committedText: String { Self.join(settled, Self.text(committed)) }

    private var unavailable: Bool { recoveryReason == .decodeUnavailable || recoveryReason == .modelPreviewUnavailable }

    private func scheduleIfNeeded() {
        guard !cancelled, !finishing, !previewStopped, !unavailable, inference == nil, !samples.isEmpty,
              received - lastScheduled >= (previousText.isEmpty ? 6_400 : 9_600) else { return }
        if samples.count > maximumSamples {
            // A skipped boundary starts a separate preview; original audio owns final continuity.
            degrade(.windowLimit, needsOriginal: true)
            discard(before: received - Int64(maximumSamples))
            previewHasGap = true
            draftable = false
            settled = ""
            committed = []
            previous = []
            previousText = ""
        }
        let snapshot = samples
        let snapshotOrigin = origin
        let snapshotEnd = received
        let snapshotGeneration = generation
        lastScheduled = received
        let engine = engine
        let options = options
        inference = Task { [weak self] in
            do {
                let runtime = try await engine.value
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let result = try await runtime.transcribe(samples: snapshot, options: options)
                try Task.checkCancellation()
                await self?.accept(result, origin: snapshotOrigin, end: snapshotEnd, generation: snapshotGeneration,
                                   milliseconds: Self.milliseconds(since: start))
            } catch {
                await self?.decodeFailed(generation: snapshotGeneration)
            }
        }
    }

    private func accept(_ result: TranscriptionResult, origin snapshotOrigin: Int64, end: Int64,
                        generation snapshotGeneration: Int, milliseconds: Double) {
        inference = nil
        computeMilliseconds += milliseconds
        guard !cancelled, !unavailable else { return }
        guard snapshotGeneration == generation else { scheduleIfNeeded(); return }
        consecutiveDecodeFailures = 0
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: Bool
        if case .detected(let seconds) = result.speechPresence, seconds.isFinite, seconds >= 0,
           seconds <= Double(end - snapshotOrigin) / 16_000 {
            endpoint = end - snapshotOrigin - Int64(seconds * 16_000) >= 12_288
        } else { endpoint = false }

        if result.speechPresence == .notDetected, previousText.isEmpty,
           committed.allSatisfy({ $0.end <= snapshotOrigin }) {
            tentative = ""
            recoveryReason = previewHasGap ? .windowLimit : nil
            discard(before: max(origin, end - 8_000))
            publish()
        } else if let words = Self.words(result, origin: snapshotOrigin) {
            if let remainder = remainingWords(words) {
                let agreement = zip(previous, remainder).prefix { old, new in
                    old.text == new.text && abs(old.end - new.end) <= 4_000
                }.count
                if endpoint, text == previousText, agreement == remainder.count {
                    let heard = committed + remainder
                    settled = Self.join(settled, Self.text(heard))
                    closeChunk(at: max(chunkStart, end - 8_000), pause: true, heard: heard.contains { $0.start >= chunkStart - 1_600 })
                    committed = []
                    previous = []
                    previousText = ""
                    tentative = ""
                    // Keep onset context and any newer frames that arrived during this decode.
                    discard(before: max(origin, end - 8_000))
                } else {
                    let stable = remainder.prefix(agreement).prefix { $0.end <= end - 32_000 }
                    committed.append(contentsOf: stable)
                    previous = Array(remainder.dropFirst(stable.count))
                    previousText = text
                    tentative = Self.text(previous)
                    if let last = committed.last {
                        let overlapStart = last.end - 24_000
                        let wordStart = committed.first { $0.end > overlapStart }?.start ?? overlapStart
                        discard(before: max(origin, wordStart))
                    }
                    closeLongChunk()
                }
                recoveryReason = previewHasGap ? .windowLimit : nil
                publish()
            } else {
                // Re-decode retained audio instead of permanently latching a stale suffix.
                committed.removeAll { $0.end > snapshotOrigin }
                previous = words
                previousText = text
                tentative = text
                degrade(.overlapMismatch, needsOriginal: true)
            }
        } else if committed.isEmpty {
            // Whole-hypothesis agreement plus a speech endpoint can settle output without timings.
            if endpoint, !text.isEmpty, text == previousText {
                settled = Self.join(settled, text)
                closeChunk(at: max(chunkStart, end - 8_000), pause: true, heard: true)
                previousText = ""
                tentative = ""
                discard(before: max(origin, end - 8_000))
                recoveryReason = previewHasGap ? .windowLimit : nil
            } else {
                previousText = text
                tentative = text
                recoveryReason = previewHasGap ? .windowLimit : (text.isEmpty ? nil : .timingUnavailable)
            }
            previous = []
            publish()
        } else { degrade(.timingUnavailable, needsOriginal: true) }
        scheduleIfNeeded()
    }

    /// The words of a new decode after the committed words still inside the window. A word matches across decodes
    /// within a quarter second, ignoring case and the edge punctuation its new right context can change ("it," with
    /// more speech after it, "it." at the end). Committed words keep their text.
    private func remainingWords(_ words: [Word]) -> [Word]? {
        let overlap = committed.filter { $0.end > origin }
        guard let first = overlap.first else { return words }
        guard var index = words.indices.first(where: { Self.sameWord(words[$0], first) }) else { return nil }
        for old in overlap {
            guard index < words.count, Self.sameWord(words[index], old) else { return nil }
            index += 1
        }
        return Array(words.dropFirst(index))
    }

    private static func sameWord(_ new: Word, _ old: Word) -> Bool {
        abs(new.end - old.end) <= 4_000 && identity(new.text) == identity(old.text)
    }

    private static func identity(_ word: String) -> String {
        let core = word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        return core.isEmpty ? word : core
    }

    private func discard(before position: Int64) {
        let count = min(samples.count, max(0, Int(position - origin)))
        if count > 0 { samples.removeFirst(count); origin += Int64(count) }
    }

    private func decodeFailed(generation snapshotGeneration: Int) {
        inference = nil
        guard !cancelled, !unavailable else { return }
        if snapshotGeneration == generation {
            consecutiveDecodeFailures += 1
            degrade(consecutiveDecodeFailures < 3 ? .decodeFailed : .decodeUnavailable,
                    needsOriginal: consecutiveDecodeFailures >= 3)
        }
        scheduleIfNeeded()
    }

    private func degrade(_ reason: LiveRecoveryReason, needsOriginal: Bool) {
        requiresFinalRecovery = requiresFinalRecovery || needsOriginal
        guard !unavailable else { return }
        recoveryReason = reason
        if unavailable {
            inference?.cancel()
            samples.removeAll()
            draftable = false
        }
        publish()
    }

    private func publish() {
        continuation.yield(LiveTranscript(committedText: committedText,
            tentativeText: (committedText.isEmpty || tentative.isEmpty ? "" : " ") + tentative,
            recoveryReason: recoveryReason))
    }

    private func checkCancellation() throws {
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private struct Word: Sendable {
        var text: String
        var start: Int64
        var end: Int64
    }

    private static func words(_ result: TranscriptionResult, origin: Int64) -> [Word]? {
        var words: [Word] = []
        var boundary = true
        for token in result.tokens {
            if token.text == "<blank>" || token.text == "<pad>" { continue }
            guard token.startSeconds.isFinite, token.endSeconds.isFinite,
                  token.startSeconds >= 0, token.endSeconds >= token.startSeconds,
                  token.endSeconds <= 16 else { return nil }
            let start = origin + Int64(token.startSeconds * 16_000)
            let end = origin + Int64(token.endSeconds * 16_000)
            // Timing tokens can contain normalized spaces, standalone boundaries or punctuation pieces.
            for character in token.text.replacingOccurrences(of: "▁", with: " ") {
                if character.isWhitespace { boundary = true; continue }
                if boundary || words.isEmpty { words.append(Word(text: String(character), start: start, end: end)) }
                else { words[words.count - 1].text.append(character); words[words.count - 1].end = max(words[words.count - 1].end, end) }
                boundary = false
            }
        }
        guard !words.isEmpty,
              text(words) == result.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") else { return nil }
        return words
    }

    private static func text(_ words: [Word]) -> String { words.map(\.text).joined(separator: " ") }
    private static func join(_ prefix: String, _ tail: String) -> String {
        [prefix, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
