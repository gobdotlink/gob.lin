import Foundation

actor SignalPCM: PCMSpeechEngine {
    nonisolated let identifier = "check"
    nonisolated let maximumWindowSamples = 240_000
    private let timings: Bool
    private var failures: Int
    private(set) var calls = 0
    private(set) var largestWindow = 0
    init(timings: Bool = true, failures: Int = 0) { self.timings = timings; self.failures = failures }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError("File recovery is checked separately") }
    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        calls += 1
        largestWindow = max(largestWindow, samples.count)
        precondition(samples.count <= maximumWindowSamples)
        if failures > 0 { failures -= 1; throw CheckError.decode }
        var pieces: [TranscriptionToken] = []
        var text: [String] = []
        var lastEnd = 0
        for (signal, word) in [(Float(0.1), "hello world."), (Float(0.2), "Second sentence."), (Float(0.3), "yeah")] {
            guard let first = samples.firstIndex(of: signal), let last = samples.lastIndex(of: signal) else { continue }
            text.append(word)
            // One timing piece deliberately contains multiple normalized word boundaries.
            pieces.append(.init(text: " " + word, startSeconds: Double(first) / 16_000,
                                endSeconds: Double(last + 1) / 16_000, confidence: 1))
            lastEnd = max(lastEnd, last + 1)
        }
        if text.isEmpty { return .init(text: "", speechPresence: .notDetected) }
        return .init(text: text.joined(separator: " "), tokens: timings ? pieces : [],
                     speechPresence: .detected(endSeconds: Double(lastEnd) / 16_000))
    }
    enum CheckError: Error { case decode }
}

actor Values {
    private(set) var values: [LiveTranscript] = []
    func add(_ value: LiveTranscript) { values.append(value) }
}

actor ScriptedPCM: PCMSpeechEngine {
    enum FinalOverlap: Sendable { case unchanged, interiorWord, leadingFragment }
    nonisolated let identifier = "check"
    nonisolated let maximumWindowSamples = 240_000
    private let empty: Bool
    private let finalOverlap: FinalOverlap
    private var calls = 0
    init(empty: Bool = false, finalOverlap: FinalOverlap = .unchanged) { self.empty = empty; self.finalOverlap = finalOverlap }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError("File path is checked separately") }
    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        precondition(samples.count <= maximumWindowSamples)
        if empty { return TranscriptionResult(text: "") }
        calls += 1
        var text = "hello world tail"
        var tokens: [TranscriptionToken] = [
            .init(text: "▁hel", startSeconds: 0, endSeconds: 0.2, confidence: 1),
            .init(text: "lo", startSeconds: 0.2, endSeconds: 0.5, confidence: 1),
            .init(text: " ", startSeconds: 0.5, endSeconds: 0.6, confidence: 1),
            .init(text: "world", startSeconds: 0.6, endSeconds: 1, confidence: 1),
            .init(text: " tail", startSeconds: 2.5, endSeconds: 3, confidence: 1)
        ]
        if calls >= 3 {
            switch finalOverlap {
            case .unchanged: break
            case .interiorWord:
                text = "hello extra world tail"
                tokens.insert(.init(text: " extra", startSeconds: 0.52, endSeconds: 0.58, confidence: 1), at: 2)
            case .leadingFragment:
                text = "fragment hello world tail"
                tokens.insert(.init(text: " fragment", startSeconds: 0, endSeconds: 0.02, confidence: 1), at: 0)
            }
        }
        return TranscriptionResult(text: text, tokens: tokens)
    }
}


actor WordSequencePCM: PCMSpeechEngine {
 nonisolated let identifier = "sequence"
 nonisolated let maximumWindowSamples = 240_000
 func prepare() async throws {}
 func unload() async {}
 func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError() }
 func transcribe(samples: [Float]) async throws -> TranscriptionResult {
  var tokens: [TranscriptionToken] = []
  var start = 0
  while start < samples.count {
   let marker = samples[start]
   var end = start + 1
   while end < samples.count && samples[end] == marker { end += 1 }
   let word = "word" + String(Int((marker * 100).rounded()))
   tokens.append(.init(text: " " + word, startSeconds: Double(start) / 16_000, endSeconds: Double(end) / 16_000, confidence: 1))
   start = end
  }
  return .init(text: tokens.map { $0.text }.joined().trimmingCharacters(in: .whitespaces), tokens: tokens)
 }
}

@main
struct LiveTranscriptionCheck {
    static func verify(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func feed(_ signal: Float, seconds: Double, live: LiveTranscriber, position: inout Int64) async throws {
        var remaining = Int(seconds * 16_000)
        while remaining > 0 {
            let count = min(6_400, remaining)
            await live.append([Float](repeating: signal, count: count), at: position)
            position += Int64(count)
            remaining -= count
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func main() async throws {
        let runtime = SignalPCM()
        let live = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
        let values = Values()
        let collector = Task { for await value in live.updates { await values.add(value) } }
        var position: Int64 = 0
        try await feed(0, seconds: 10, live: live, position: &position)
        verify(await values.values.allSatisfy { $0.committedText.isEmpty && $0.tentativeText.isEmpty }, "Quiet delayed onset fabricated text")
        try await feed(0.1, seconds: 1.2, live: live, position: &position)
        try await feed(0, seconds: 9, live: live, position: &position)
        verify(await values.values.contains { $0.committedText == "hello world." && $0.tentativeText.isEmpty }, "Sentence did not settle during the pause")
        try await feed(0.2, seconds: 1.2, live: live, position: &position)
        try await feed(0, seconds: 12, live: live, position: &position)
        let final = try await live.finish()
        await collector.value
        verify(final?.text == "hello world. Second sentence.", "Long pauses lost or duplicated speech")
        verify(await values.values.contains { $0.committedText == "hello world. Second sentence." }, "Second sentence only appeared at release")
        verify(!(await live.requiresFinalRecovery), "Normal pauses needlessly required full-file catch-up")
        verify(await runtime.largestWindow <= 240_000, "Retained resource bound exceeded")

        let sequence = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { WordSequencePCM() }, maximumWindowSamples: 96_000)
        var sequencePosition: Int64 = 0
        for word in 1...80 { try await feed(Float(word) / 100, seconds: 0.4, live: sequence, position: &sequencePosition) }
        let sequenceResult = try await sequence.finish()
        verify(sequenceResult?.text == (1...80).map { "word" + String($0) }.joined(separator: " "), "Continuous speech lost or duplicated words at retained boundaries")
        verify(!(await sequence.requiresFinalRecovery), "Continuous timed speech fell back instead of advancing")

        for variation in [ScriptedPCM.FinalOverlap.unchanged, .interiorWord, .leadingFragment] {
            let revised = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { ScriptedPCM(finalOverlap: variation) })
            await revised.append([Float](repeating: 0.1, count: 64_000), at: 0)
            try await Task.sleep(for: .milliseconds(20))
            await revised.append([Float](repeating: 0.1, count: 9_600), at: 64_000)
            try await Task.sleep(for: .milliseconds(20))
            let final = try await revised.finish()
            if variation == .interiorWord { verify(final == nil, "Interior overlap mismatch did not preserve original-file recovery") }
            else { verify(final?.text == "hello world tail", "Consecutive overlap or leading-fragment handling regressed") }
        }

        // Whole-hypothesis agreement can settle at an endpoint without invented token timings.
        let untimed = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { SignalPCM(timings: false) })
        var untimedPosition: Int64 = 0
        try await feed(0.3, seconds: 0.4, live: untimed, position: &untimedPosition)
        try await feed(0, seconds: 9, live: untimed, position: &untimedPosition)
        verify(try await untimed.finish()?.text == "yeah", "Untimed short speech was lost")

        // Same runtime, fresh live sessions: quiet and short words cannot carry over.
        for signal in [Float(0), Float(0.3), Float(0), Float(0.3)] {
            let reset = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
            var resetPosition: Int64 = 0
            try await feed(signal, seconds: 0.4, live: reset, position: &resetPosition)
            verify(try await reset.finish()?.text == (signal == 0 ? "" : "yeah"), "Warm/cold reset or legitimate short word failed")
        }

        let retry = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { SignalPCM(failures: 1) })
        let retryValues = Values()
        let retryCollector = Task { for await value in retry.updates { await retryValues.add(value) } }
        var retryPosition: Int64 = 0
        try await feed(0.1, seconds: 1.2, live: retry, position: &retryPosition)
        try await feed(0, seconds: 3, live: retry, position: &retryPosition)
        verify(try await retry.finish()?.text == "hello world.", "Recoverable decode froze the session")
        await retryCollector.value
        verify(await retryValues.values.contains { $0.recoveryReason == .decodeFailed }, "Decode failure was silent")
        verify(await retryValues.values.contains { $0.recoveryReason == nil && !$0.committedText.isEmpty }, "Preview never recovered")

        let brokenRuntime = SignalPCM(failures: 20)
        let broken = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { brokenRuntime })
        var brokenPosition: Int64 = 0
        try await feed(0.1, seconds: 12, live: broken, position: &brokenPosition)
        verify(await brokenRuntime.calls == 3, "Persistent failure retried without a bound")
        verify(try await broken.finish() == nil, "Persistent failure did not request original-file recovery")

        let overflow = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime }, maximumWindowSamples: 6_400)
        await overflow.append([Float](repeating: 0.1, count: 12_800), at: 0)
        verify(try await overflow.finish() == nil, "Skipped window did not require original audio")

        let discontinuous = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
        await discontinuous.append([0.1], at: 1)
        verify(try await discontinuous.finish() == nil, "Missing frame was accepted")
        let cancelled = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
        await cancelled.append([Float](repeating: 0.1, count: 6_400), at: 0)
        await cancelled.cancel()
        do { _ = try await cancelled.finish(); preconditionFailure("Cancelled stream produced text") }
        catch is CancellationError {}
        print("Live regression checks passed: 33s replay, repeated long pauses, second sentence, normalized tokens, untimed endpoints, quiet/short/reset, bounded retry/recovery, ordering and cancellation.")
    }
}
