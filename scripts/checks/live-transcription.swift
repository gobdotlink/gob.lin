import Foundation

actor SignalPCM: PCMSpeechEngine {
    nonisolated let identifier = "check"
    nonisolated let maximumWindowSamples = 240_000
    private let timings: Bool
    private var failures: Int
    private(set) var calls = 0
    private(set) var largestWindow = 0
    private(set) var optionsUsed: [RecognitionOptions] = []
    init(timings: Bool = true, failures: Int = 0) { self.timings = timings; self.failures = failures }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError("File recovery is checked separately") }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        optionsUsed.append(options)
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

actor SlowUntimedPCM: PCMSpeechEngine {
    nonisolated let identifier = "slow-check"
    nonisolated let maximumWindowSamples = 240_000
    private let delay: Duration
    private(set) var calls = 0
    private(set) var largestWindow = 0
    init(delay: Duration) { self.delay = delay }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError() }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        calls += 1
        largestWindow = max(largestWindow, samples.count)
        precondition(samples.count <= maximumWindowSamples)
        try await Task.sleep(for: delay)
        return .init(text: samples.last == 0.2 ? "Second sentence." : "hello world.")
    }
}

actor ScriptedPCM: PCMSpeechEngine {
    enum FinalOverlap: Sendable { case unchanged, caseOnly, punctuationOnly, interiorWord, leadingFragment }
    nonisolated let identifier = "check"
    nonisolated let maximumWindowSamples = 240_000
    private let empty: Bool
    private let finalOverlap: FinalOverlap
    private var calls = 0
    private(set) var lastWindow = 0
    init(empty: Bool = false, finalOverlap: FinalOverlap = .unchanged) { self.empty = empty; self.finalOverlap = finalOverlap }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError("File path is checked separately") }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        precondition(samples.count <= maximumWindowSamples)
        if empty { return TranscriptionResult(text: "") }
        calls += 1
        lastWindow = samples.count
        var text = "hello world tail"
        var tokens: [TranscriptionToken] = [
            .init(text: "▁hel", startSeconds: 0, endSeconds: 0.2, confidence: 1),
            .init(text: "lo", startSeconds: 0.2, endSeconds: 0.5, confidence: 1),
            .init(text: " ", startSeconds: 0.5, endSeconds: 0.6, confidence: 1),
            .init(text: "world", startSeconds: 0.6, endSeconds: 1, confidence: 1),
            .init(text: " tail", startSeconds: 2.5, endSeconds: finalOverlap == .caseOnly ? 4 : 3, confidence: 1)
        ]
        if calls >= 3 {
            switch finalOverlap {
            case .unchanged: break
            case .caseOnly:
                text = "Hello WORLD tail"
                tokens[0] = .init(text: "▁Hel", startSeconds: 0, endSeconds: 0.2, confidence: 1)
                tokens[3] = .init(text: "WORLD", startSeconds: 0.6, endSeconds: 1, confidence: 1)
            case .punctuationOnly:
                // More speech after a word can move a sentence break; the words themselves are unchanged.
                text = "hello, world. tail"
                tokens[1] = .init(text: "lo,", startSeconds: 0.2, endSeconds: 0.5, confidence: 1)
                tokens[3] = .init(text: "world.", startSeconds: 0.6, endSeconds: 1, confidence: 1)
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
 func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
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

/// Words separated by short silences, too short to settle as a pause: `marker` runs are words, zeros are gaps.
/// With `frame`, times snap to a grid of that many samples from the window's start, as Parakeet's 80 ms frames do, so
/// decodes of windows that start at different places time the same word differently.
actor GappedWordsPCM: PCMSpeechEngine {
    nonisolated let identifier = "gapped"
    nonisolated let maximumWindowSamples = 240_000
    private let frame: Int
    private var muted = false
    private(set) var largestWindow = 0
    init(frame: Int = 1) { self.frame = frame }
    /// Later decodes hear nothing, as if the last words were lost.
    func mute() { muted = true }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { fatalError() }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        largestWindow = max(largestWindow, samples.count)
        if muted { return .init(text: "", speechPresence: .notDetected) }
        let snap = { (sample: Int) in Double(Int((Double(sample) / Double(self.frame)).rounded()) * self.frame) / 16_000 }
        var tokens: [TranscriptionToken] = []
        var start = 0
        while start < samples.count {
            let marker = samples[start]
            var end = start + 1
            while end < samples.count && samples[end] == marker { end += 1 }
            if marker != 0 {
                tokens.append(.init(text: " word" + String(Int((marker * 100).rounded())), startSeconds: snap(start),
                                    endSeconds: max(snap(start), snap(end)), confidence: 1))
            }
            start = end
        }
        let text = tokens.map { $0.text }.joined().trimmingCharacters(in: .whitespaces)
        return .init(text: text, tokens: tokens, speechPresence: tokens.isEmpty ? .notDetected : .detected(endSeconds: tokens.last!.endSeconds))
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

        let preferred = RecognitionOptions(language: "pl", vocabulary: ["Postgres", "CodeRabbit"])
        let languageRuntime = SignalPCM()
        let languageLive = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { languageRuntime }, options: preferred)
        var languagePosition: Int64 = 0
        try await feed(0.1, seconds: 1.2, live: languageLive, position: &languagePosition)
        _ = try await languageLive.finish()
        let used = await languageRuntime.optionsUsed
        verify(!used.isEmpty && used.allSatisfy { $0 == preferred }, "Preview and final window did not preserve language and dictionary")

        let batchRuntime = SignalPCM()
        let batchOnly = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { batchRuntime }, options: preferred, previewAvailable: false)
        await batchOnly.append([Float](repeating: 0.1, count: 480_000), at: 0)
        verify(try await batchOnly.finish() == nil, "Batch-only model lost original-file recovery")
        verify(await batchOnly.requiresFinalRecovery, "Batch-only model did not request file recovery")
        verify(await batchRuntime.calls == 0, "Batch-only model decoded or buffered live windows")

        let sequence = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { WordSequencePCM() }, maximumWindowSamples: 96_000)
        var sequencePosition: Int64 = 0
        for word in 1...80 { try await feed(Float(word) / 100, seconds: 0.4, live: sequence, position: &sequencePosition) }
        let sequenceResult = try await sequence.finish()
        verify(sequenceResult?.text == (1...80).map { "word" + String($0) }.joined(separator: " "), "Continuous speech lost or duplicated words at retained boundaries")
        verify(!(await sequence.requiresFinalRecovery), "Continuous timed speech fell back instead of advancing")

        // Speech with only short gaps never settles a pause, yet each chunk closes between words as it nears a window and
        // is decoded in the background, so key-up decodes only the last one and nothing is lost or repeated.
        let gappedRuntime = GappedWordsPCM()
        let gapped = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { gappedRuntime })
        var gappedPosition: Int64 = 0
        for word in 1...40 {
            try await feed(Float(word) / 100, seconds: 0.4, live: gapped, position: &gappedPosition)
            try await feed(0, seconds: 0.2, live: gapped, position: &gappedPosition)
        }
        let gappedFinal = try await gapped.finish()
        let chunked = await gapped.chunkDiagnostics()
        verify(gappedFinal?.text == (1...40).map { "word" + String($0) }.joined(separator: " "), "Chunked speech lost or repeated words")
        verify(chunked.chunks >= 1 && chunked.chunking, "Long speech without pauses did not close a chunk between words")
        verify(await gappedRuntime.largestWindow <= 240_000, "A chunk decode exceeded one window")

        // Each decode times words on its own 80 ms grid, so the same word's start differs between decodes; a short word
        // beside a boundary must still land in exactly one chunk.
        let jitteredRuntime = GappedWordsPCM(frame: 1_280)
        let jittered = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { jitteredRuntime })
        var jitteredPosition: Int64 = 0
        for word in 1...40 {
            try await feed(Float(word) / 100, seconds: word.isMultiple(of: 2) ? 0.06 : 0.4, live: jittered, position: &jitteredPosition)
            try await feed(0, seconds: 0.15, live: jittered, position: &jitteredPosition)
        }
        let jitteredFinal = try await jittered.finish()
        verify(jitteredFinal?.text == (1...40).map { "word" + String($0) }.joined(separator: " "), "Differently timed decodes lost or repeated a word at a chunk boundary")
        verify(await jittered.chunkDiagnostics().chunks >= 1, "Jittered speech never closed a chunk")

        // Words the previews heard after a pause, which the key-up decode loses, send the take to the original recording
        // instead of ending on the earlier chunk alone.
        let lossyRuntime = GappedWordsPCM()
        let lossy = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { lossyRuntime })
        var lossyPosition: Int64 = 0
        for word in 1...3 {
            try await feed(Float(word) / 100, seconds: 0.4, live: lossy, position: &lossyPosition)
            try await feed(0, seconds: 0.2, live: lossy, position: &lossyPosition)
        }
        try await feed(0, seconds: 9, live: lossy, position: &lossyPosition)
        try await Task.sleep(for: .milliseconds(100))
        verify(await lossy.chunkDiagnostics().pauses == 1, "The pause did not close a chunk")
        for word in 4...5 {
            try await feed(Float(word) / 100, seconds: 0.4, live: lossy, position: &lossyPosition)
            try await feed(0, seconds: 0.2, live: lossy, position: &lossyPosition)
            try await Task.sleep(for: .milliseconds(50))
        }
        await lossyRuntime.mute()
        verify(try await lossy.finish() == nil, "Key-up dropped words the previews heard after the last pause")

        for variation in [ScriptedPCM.FinalOverlap.unchanged, .caseOnly, .punctuationOnly, .interiorWord, .leadingFragment] {
            let script = ScriptedPCM(finalOverlap: variation)
            let revised = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { script })
            let revisedValues = Values()
            let revisedCollector = Task { for await value in revised.updates { await revisedValues.add(value) } }
            await revised.append([Float](repeating: 0.1, count: 64_000), at: 0)
            try await Task.sleep(for: .milliseconds(20))
            await revised.append([Float](repeating: 0.1, count: 9_600), at: 64_000)
            try await Task.sleep(for: .milliseconds(20))
            if variation == .caseOnly {
                await revised.append([Float](repeating: 0.1, count: 9_600), at: 73_600)
                try await Task.sleep(for: .milliseconds(20))
            }
            let final = try await revised.finishWithDraft().result
            await revisedCollector.value
            // Key-up decodes everything since the last pause in one window, so its reading is the final text however
            // the previews' seams lined up, including a word they heard differently (interiorWord).
            let reading = ["hello world tail", "Hello WORLD tail", "hello, world. tail", "hello extra world tail", "fragment hello world tail"]
            let index = [ScriptedPCM.FinalOverlap.unchanged, .caseOnly, .punctuationOnly, .interiorWord, .leadingFragment].firstIndex(of: variation)!
            verify(final?.text == reading[index], "Key-up did not take the whole segment's reading")
            verify(await script.lastWindow == (variation == .caseOnly ? 83_200 : 73_600), "Key-up decoded a tail instead of everything since the pause")
            if variation == .punctuationOnly {
                verify(!(await revised.requiresFinalRecovery), "Punctuation moving at the seam required original-file recovery")
            }
            if variation == .caseOnly {
                let snapshots = await revisedValues.values
                verify(snapshots.last?.committedText == "hello world", "Case-only overlap regressed or recased committed text")
                verify(snapshots.allSatisfy { $0.recoveryReason == nil }, "Case-only overlap needlessly required recovery")
                verify(!(await revised.requiresFinalRecovery), "Case-only overlap required original-file recovery")
            }
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
        let brokenValues = Values()
        let brokenCollector = Task { for await value in broken.updates { await brokenValues.add(value) } }
        var brokenPosition: Int64 = 0
        try await feed(0.1, seconds: 32, live: broken, position: &brokenPosition)
        verify(await brokenRuntime.calls == 3, "Persistent failure retried without a bound")
        verify(try await broken.finish() == nil, "Persistent failure did not request original-file recovery")
        await brokenCollector.value
        verify(await brokenValues.values.last?.recoveryReason == .decodeUnavailable, "Later frames replaced terminal failure with recovering")

        let slowRuntime = SlowUntimedPCM(delay: .milliseconds(20))
        let slow = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { slowRuntime })
        let slowValues = Values()
        let slowCollector = Task { for await value in slow.updates { await slowValues.add(value) } }
        var slowPosition: Int64 = 0
        try await feed(0.1, seconds: 20, live: slow, position: &slowPosition)
        try await feed(0.2, seconds: 8, live: slow, position: &slowPosition)
        verify(try await slow.finish() == nil, "Skipped window invented final transcript continuity")
        await slowCollector.value
        let slowSnapshots = await slowValues.values
        let overflowIndex = slowSnapshots.firstIndex { $0.recoveryReason == .windowLimit }
        verify(overflowIndex != nil, "Slow untimed check did not reach window advancement")
        let resumed = slowSnapshots.dropFirst(overflowIndex ?? slowSnapshots.count)
        verify(resumed.allSatisfy { !$0.tentativeText.isEmpty }, "Window advancement blanked the visible preview")
        verify(resumed.contains { $0.tentativeText == "Second sentence." && $0.committedText.isEmpty && $0.recoveryReason == .windowLimit },
               "Slow decode did not progress after overflow or stitched across skipped audio")
        verify(await slowRuntime.calls <= 35, "Overflow started repeated catch-up inference")
        verify(await slowRuntime.largestWindow <= 240_000, "Pending audio reached the engine beyond its limit")

        let ceilingRuntime = SlowUntimedPCM(delay: .milliseconds(100))
        let ceiling = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { ceilingRuntime })
        let ceilingValues = Values()
        let ceilingCollector = Task { for await value in ceiling.updates { await ceilingValues.add(value) } }
        var ceilingPosition: Int64 = 0
        try await feed(0.1, seconds: 30, live: ceiling, position: &ceilingPosition)
        let stoppedCalls = await ceilingRuntime.calls
        verify(stoppedCalls <= 5, "Hard ceiling kept starting full-window inference")
        verify(await ceilingValues.values.last?.recoveryReason == .decodeUnavailable, "Hard memory ceiling did not stop live preview explicitly")
        try await feed(0.2, seconds: 10, live: ceiling, position: &ceilingPosition)
        verify(await ceilingRuntime.calls == stoppedCalls, "Later frames restarted a terminal ceiling stop")
        verify(try await ceiling.finish() == nil, "Ceiling stop lost original-file recovery")
        await ceilingCollector.value
        verify(await ceilingValues.values.last?.recoveryReason == .decodeUnavailable, "Terminal ceiling reason was overwritten")

        let overflow = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime }, maximumWindowSamples: 6_400)
        await overflow.append([Float](repeating: 0.1, count: 12_800), at: 0)
        let overflowEnding = try await overflow.finishWithDraft()
        verify(overflowEnding.result == nil, "Skipped window did not require original audio")
        verify(overflowEnding.draft == nil, "A window that dropped audio drafted the take")

        let releaseRuntime = SlowUntimedPCM(delay: .milliseconds(100))
        let released = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { releaseRuntime })
        let releaseValues = Values()
        let releaseCollector = Task { for await value in released.updates { await releaseValues.add(value) } }
        await released.append([Float](repeating: 0.1, count: 6_400), at: 0)
        await released.stopPreview()
        await released.append([Float](repeating: 0.2, count: 9_600), at: 6_400)
        verify(try await released.finish()?.text == "Second sentence.", "Stopping preview dropped capture's final frames")
        await releaseCollector.value
        verify(await releaseValues.values.isEmpty, "Release replayed pending live previews")
        verify(await releaseRuntime.calls == 2, "Release decoded a queued preview before final recognition")

        let discontinuous = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
        await discontinuous.append([0.1], at: 1)
        let gap = try await discontinuous.finishWithDraft()
        verify(gap.result == nil, "Missing frame was accepted")
        verify(gap.draft == nil, "A window with missing frames drafted the take")
        let cancelled = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { runtime })
        await cancelled.append([Float](repeating: 0.1, count: 6_400), at: 0)
        await cancelled.cancel()
        do { _ = try await cancelled.finish(); preconditionFailure("Cancelled stream produced text") }
        catch is CancellationError {}
        print("Live regression checks passed: long pauses, continuous speech, slow untimed overflow progress, terminal ceiling/failure, overlap/punctuation/fragments, whole segments at key-up, chunks between words, drafts, reset, ordering and cancellation.")
    }
}
