import Foundation

public enum LiveRecoveryReason: String, Sendable {
    case windowLimit, decodeFailed, decodeUnavailable, overlapMismatch, timingUnavailable, inputDiscontinuity, invalidSamples
}

public struct LiveTranscript: Sendable, Equatable {
    public let committedText: String
    public let tentativeText: String
    public let recoveryReason: LiveRecoveryReason?
}

/// Decodes only the retained tail; original disk audio is the recovery source.
public actor LiveTranscriber {
    public nonisolated let updates: AsyncStream<LiveTranscript>
    private let continuation: AsyncStream<LiveTranscript>.Continuation
    private let engine: Task<any PCMSpeechEngine, Error>
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
    private var cancelled = false
    private var finishing = false
    public private(set) var requiresFinalRecovery = false
    public private(set) var computeMilliseconds = 0.0

    public init(engine: Task<any PCMSpeechEngine, Error>, maximumWindowSamples: Int = 240_000) {
        self.engine = engine
        maximumSamples = min(240_000, max(6_400, maximumWindowSamples))
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func append(_ frame: [Float], at samplePosition: Int64) {
        guard !cancelled, !finishing, !unavailable else { return }
        guard samplePosition >= received else {
            degrade(.inputDiscontinuity, needsOriginal: true)
            return
        }
        if samplePosition != received {
            samples.removeAll()
            origin = samplePosition
            received = samplePosition
            generation += 1
            previous = []
            previousText = ""
            degrade(.inputDiscontinuity, needsOriginal: true)
        }
        guard frame.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            received += Int64(frame.count)
            samples.removeAll()
            origin = received
            generation += 1
            degrade(.invalidSamples, needsOriginal: true)
            return
        }
        // Keep the in-flight snapshot valid, but allow at most three seconds of pending audio.
        guard frame.count <= maximumSamples + 48_000 - samples.count else {
            degrade(.decodeUnavailable, needsOriginal: true)
            return
        }
        received += Int64(frame.count)
        samples.append(contentsOf: frame)
        scheduleIfNeeded()
    }

    /// Call only after capture and its ordered frame consumer have drained.
    public func finish() async throws -> TranscriptionResult? {
        finishing = true
        await inference?.value
        try checkCancellation()
        defer { continuation.finish() }
        guard !requiresFinalRecovery else { return nil }
        guard samples.count <= maximumSamples else {
            degrade(.decodeUnavailable, needsOriginal: true)
            return nil
        }
        guard !samples.isEmpty else { return TranscriptionResult(text: committedText) }
        let runtime = try await engine.value
        try checkCancellation()
        let start = ContinuousClock.now
        let result: TranscriptionResult
        do { result = try await runtime.transcribe(samples: samples) }
        catch is CancellationError { throw CancellationError() }
        catch { degrade(.decodeFailed, needsOriginal: true); return nil }
        computeMilliseconds += Self.milliseconds(since: start)
        try checkCancellation()
        if result.speechPresence == .notDetected {
            // An explicit no-speech result must not trigger an ungated second recognition.
            return previousText.isEmpty ? TranscriptionResult(text: committedText, speechPresence: .notDetected) : nil
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if committed.isEmpty { return TranscriptionResult(text: Self.join(settled, result.text)) }
        guard let words = Self.words(result, origin: origin), let remainder = remainingWords(words) else {
            degrade(.overlapMismatch, needsOriginal: true)
            return nil
        }
        return TranscriptionResult(text: Self.join(settled, Self.text(committed + remainder)))
    }

    public func cancel() async {
        cancelled = true
        inference?.cancel()
        continuation.finish()
        await inference?.value
        samples.removeAll()
    }

    private var committedText: String { Self.join(settled, Self.text(committed)) }
    private var unavailable: Bool { recoveryReason == .decodeUnavailable }

    private func scheduleIfNeeded() {
        guard !cancelled, !finishing, !unavailable, inference == nil, !samples.isEmpty,
              received - lastScheduled >= (previousText.isEmpty ? 6_400 : 9_600) else { return }
        if samples.count > maximumSamples {
            // A skipped boundary starts a separate preview; original audio owns final continuity.
            degrade(.windowLimit, needsOriginal: true)
            discard(before: received - Int64(maximumSamples))
            previewHasGap = true
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
        inference = Task { [weak self] in
            do {
                let runtime = try await engine.value
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let result = try await runtime.transcribe(samples: snapshot)
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
                    settled = Self.join(settled, Self.text(committed + remainder))
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

    private func remainingWords(_ words: [Word]) -> [Word]? {
        let overlap = committed.filter { $0.end > origin }
        guard let first = overlap.first else { return words }
        guard var index = words.indices.first(where: {
            words[$0].text == first.text && abs(words[$0].end - first.end) <= 4_000
        }) else { return nil }
        for old in overlap {
            guard index < words.count, words[index].text == old.text,
                  abs(words[index].end - old.end) <= 4_000 else { return nil }
            index += 1
        }
        return Array(words.dropFirst(index))
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
