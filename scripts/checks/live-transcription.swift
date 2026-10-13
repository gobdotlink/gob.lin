import Foundation

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

@main
struct LiveTranscriptionCheck {
    static func main() async throws {
        let engine = Task<any PCMSpeechEngine, Error> { ScriptedPCM() }
        let live = LiveTranscriber(engine: engine)
        let snapshots = Task { () -> [LiveTranscript] in
            var values: [LiveTranscript] = []
            for await value in live.updates { values.append(value) }
            return values
        }
        await live.append([Float](repeating: 0.1, count: 64_000), at: 0)
        try await Task.sleep(for: .milliseconds(40))
        await live.append([Float](repeating: 0.1, count: 9_600), at: 64_000)
        try await Task.sleep(for: .milliseconds(40))
        let result = try await live.finish()
        precondition(result?.text == "hello world tail", "Final tail was lost or overlap duplicated")
        let values = await snapshots.value
        precondition(values.contains { $0.committedText == "hello world" && $0.tentativeText == " tail" },
                     "Stable prefix or sentence-piece joining failed")

        for variation in [ScriptedPCM.FinalOverlap.interiorWord, .leadingFragment] {
            let revised = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { ScriptedPCM(finalOverlap: variation) })
            await revised.append([Float](repeating: 0.1, count: 64_000), at: 0)
            try await Task.sleep(for: .milliseconds(40))
            await revised.append([Float](repeating: 0.1, count: 9_600), at: 64_000)
            try await Task.sleep(for: .milliseconds(40))
            let final = try await revised.finish()
            if variation == .interiorWord { precondition(final == nil, "An interior overlap word was silently dropped instead of requiring recovery") }
            else { precondition(final?.text == "hello world tail", "Leading-fragment tolerance regressed") }
        }

        let overflow = LiveTranscriber(engine: engine)
        await overflow.append([Float](repeating: 0.1, count: 240_001), at: 0)
        let overflowResult = try await overflow.finish()
        precondition(overflowResult == nil, "Unbounded tail did not require disk batch recovery")

        let empty = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { ScriptedPCM(empty: true) })
        await empty.append([Float](repeating: 0, count: 6_400), at: 0)
        let emptyResult = try await empty.finish()
        precondition(emptyResult == nil, "Empty streaming output did not require batch recovery")

        let cancelled = LiveTranscriber(engine: engine)
        await cancelled.append([Float](repeating: 0.1, count: 6_400), at: 0)
        await cancelled.cancel()
        do { _ = try await cancelled.finish(); preconditionFailure("Cancelled stream produced final text") }
        catch is CancellationError {}

        let discontinuous = LiveTranscriber(engine: engine)
        await discontinuous.append([0.1], at: 1)
        let discontinuousResult = try await discontinuous.finish()
        precondition(discontinuousResult == nil, "A missing audio frame was accepted")
        print("Live tail: sentence pieces, commitment, final tail, consecutive overlap, leading fragments, bounded recovery, cancellation and frame ordering passed.")
    }
}
