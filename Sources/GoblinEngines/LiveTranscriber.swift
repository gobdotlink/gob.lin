import Foundation

public struct LiveTranscript: Sendable, Equatable {
    public let committedText: String
    public let tentativeText: String
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
    private var committed: [Word] = []
    private var previous: [Word] = []
    private var inference: Task<Void, Never>?
    private var failed = false
    private var cancelled = false
    private var finishing = false
    private var hasText = false
    public private(set) var computeMilliseconds = 0.0

    public init(engine: Task<any PCMSpeechEngine, Error>, maximumWindowSamples: Int = 96_000) {
        self.engine = engine
        maximumSamples = min(240_000, max(1, maximumWindowSamples))
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func append(_ frame: [Float], at samplePosition: Int64) {
        guard !cancelled, !finishing, !failed else { return }
        guard samplePosition == received, frame.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              frame.count <= maximumSamples - samples.count else { fail(); return }
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
        guard !failed else { return nil }
        guard !samples.isEmpty else {
            return committed.isEmpty ? nil : TranscriptionResult(text: Self.text(committed))
        }
        let runtime = try await engine.value
        try checkCancellation()
        let start = ContinuousClock.now
        let result: TranscriptionResult
        do { result = try await runtime.transcribe(samples: samples) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        computeMilliseconds += Self.milliseconds(since: start)
        try checkCancellation()
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if committed.isEmpty { return result }
        guard let words = Self.words(result, origin: origin), let remainder = remainingWords(words) else { return nil }
        let text = Self.text(committed + remainder)
        continuation.yield(LiveTranscript(committedText: text, tentativeText: ""))
        return TranscriptionResult(text: text)
    }

    public func cancel() async {
        cancelled = true
        inference?.cancel()
        continuation.finish()
        await inference?.value
        samples.removeAll()
    }

    private func scheduleIfNeeded() {
        guard !failed, !cancelled, !finishing, inference == nil,
              received - lastScheduled >= (hasText ? 9_600 : 6_400) else { return }
        let snapshot = samples
        let snapshotOrigin = origin
        let snapshotEnd = received
        lastScheduled = received
        let engine = engine
        inference = Task { [weak self] in
            do {
                let runtime = try await engine.value
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let result = try await runtime.transcribe(samples: snapshot)
                try Task.checkCancellation()
                await self?.accept(result, origin: snapshotOrigin, end: snapshotEnd,
                                   milliseconds: Self.milliseconds(since: start))
            } catch {
                await self?.decodeFailed()
            }
        }
    }

    private func accept(_ result: TranscriptionResult, origin: Int64, end: Int64, milliseconds: Double) {
        inference = nil
        computeMilliseconds += milliseconds
        guard !cancelled, !failed else { return }
        hasText = hasText || !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let words = Self.words(result, origin: origin), let remainder = remainingWords(words) {
            let agreement = zip(previous, remainder).prefix { old, new in
                old.text == new.text && abs(old.end - new.end) <= 4_000
            }.count
            let stable = remainder.prefix(agreement).prefix { $0.end <= end - 32_000 }
            committed.append(contentsOf: stable)
            previous = Array(remainder.dropFirst(stable.count))
            let prefix = Self.text(committed)
            let tail = Self.text(previous)
            continuation.yield(LiveTranscript(committedText: prefix,
                tentativeText: (prefix.isEmpty || tail.isEmpty ? "" : " ") + tail))
            if let last = committed.last {
                let overlapStart = last.end - 24_000
                let wordStart = committed.first { $0.end > overlapStart }?.start ?? overlapStart
                let retainedOrigin = max(self.origin, wordStart)
                let discard = Int(retainedOrigin - self.origin)
                if discard > 0 {
                    samples.removeFirst(discard)
                    self.origin = retainedOrigin
                }
            }
        } else if committed.isEmpty {
            previous = []
            continuation.yield(LiveTranscript(committedText: "", tentativeText: result.text))
        } else { fail() }
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

    private func decodeFailed() {
        inference = nil
        fail()
    }

    private func fail() { failed = true; samples.removeAll() }

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
        var pendingBoundary = false
        for token in result.tokens {
            if token.text == "<blank>" || token.text == "<pad>" { continue }
            guard token.startSeconds.isFinite, token.endSeconds.isFinite,
                  token.startSeconds >= 0, token.endSeconds >= token.startSeconds,
                  token.endSeconds <= 16 else { return nil }
            let startsWord = pendingBoundary || token.text.hasPrefix("▁") || token.text.first?.isWhitespace == true
            let text = token.text.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { pendingBoundary = startsWord; continue }
            pendingBoundary = false
            let start = origin + Int64(token.startSeconds * 16_000)
            let end = origin + Int64(token.endSeconds * 16_000)
            if startsWord || words.isEmpty { words.append(Word(text: text, start: start, end: end)) }
            else {
                words[words.count - 1].text += text
                words[words.count - 1].end = end
            }
        }
        guard !words.isEmpty,
              text(words) == result.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return words
    }

    private static func text(_ words: [Word]) -> String { words.map(\.text).joined(separator: " ") }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
