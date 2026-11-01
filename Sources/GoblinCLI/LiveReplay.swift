import FluidAudio
import Foundation
import GoblinCore
import GoblinEngines

/// Replays recordings through the app's live path at speaking pace, then measures what happens at key-up:
/// the live final, and the whole-recording recognition the app falls back to. Prints match flags and timings,
/// never transcript text, unless `--texts` is given; keep that output in a private evaluation directory.
enum LiveReplay {
    static let usage = "Usage: goblin live-replay <audio-file>... [--speed <x>] [--frame-ms <ms>] [--in-flight-ms <ms>] [--stop-ms <ms>] [--texts] [--decode-timing]"

    static func run(_ arguments: [String], engine: any PCMSpeechEngine, options: RecognitionOptions,
                    previewAvailable: Bool) async throws {
        var files: [URL] = []
        // At key-up the last `inFlight` ms of audio are still on their way, and capture takes `stop` ms to close.
        var speed = 1.0, frameMilliseconds = 64.0, inFlightMilliseconds = 100.0, stopMilliseconds = 120.0, texts = false, decodeTiming = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--speed", "--frame-ms", "--in-flight-ms", "--stop-ms":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value >= 0,
                      value > 0 || ["--in-flight-ms", "--stop-ms"].contains(arguments[index]) else { throw CommandError.usage(usage) }
                switch arguments[index] {
                case "--speed": speed = value
                case "--frame-ms": frameMilliseconds = value
                case "--in-flight-ms": inFlightMilliseconds = value
                default: stopMilliseconds = value
                }
                index += 2
            case "--texts": texts = true; index += 1
            case "--decode-timing": decodeTiming = true; index += 1
            case let value where value.hasPrefix("--"): throw CommandError.usage(usage)
            default: files.append(URL(fileURLWithPath: arguments[index])); index += 1
            }
        }
        guard !files.isEmpty else { throw CommandError.usage(usage) }
        try await engine.prepare()
        if decodeTiming {
            // Whole-recording recognition only: where its time goes, without live pacing.
            for file in files {
                let clock = ContinuousClock()
                var record: [String: Any] = ["id": file.lastPathComponent]
                var start = clock.now
                let samples = try AudioConverter().resampleAudioFile(file)
                record["readMilliseconds"] = milliseconds(start.duration(to: clock.now))
                record["seconds"] = Double(samples.count) / 16_000
                start = clock.now
                _ = try await engine.transcribe(TranscriptionRequest(audioFileURL: file, options: options))
                record["fileMilliseconds"] = milliseconds(start.duration(to: clock.now))
                if samples.count <= engine.maximumWindowSamples {
                    start = clock.now
                    _ = try await engine.transcribe(samples: samples, options: options)
                    record["inMemoryMilliseconds"] = milliseconds(start.duration(to: clock.now))
                }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return
        }
        let frame = max(160, Int(frameMilliseconds * 16))
        let recovery = RecordedAudioPipeline(engine: engine, options: options)
        for file in files {
            let samples = try AudioConverter().resampleAudioFile(file)
            let live = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { engine }, options: options,
                                      previewAvailable: previewAvailable)
            let early = Task { () -> (text: String, at: ContinuousClock.Instant)? in
                var latest: (text: String, at: ContinuousClock.Instant)?
                for await text in live.settledTexts { latest = (text, ContinuousClock.now) }
                return latest
            }
            let reasons = Task { () -> [String] in
                var seen: [String] = []
                for await update in live.updates { if let reason = update.recoveryReason?.rawValue, seen.last != reason { seen.append(reason) } }
                return seen
            }
            let clock = ContinuousClock()
            let start = clock.now
            var position = 0
            let released = max(0, samples.count - Int(inFlightMilliseconds * 16))
            while position < released {
                let end = min(released, position + frame)
                await live.append(Array(samples[position..<end]), at: Int64(position))
                position = end
                // Pace frames to the speaking clock, as capture would deliver them.
                let due = start.advanced(by: .milliseconds(Int(Double(position) / 16 / speed)))
                if due > clock.now { try await clock.sleep(until: due) }
            }
            let keyUp = clock.now
            // As in the app: previews stop and the audio so far is decoded for cleanup while capture closes.
            await live.stopPreview()
            let release = Task { () -> (text: String?, at: ContinuousClock.Instant) in (await live.releaseText(), ContinuousClock.now) }
            try await clock.sleep(until: keyUp.advanced(by: .milliseconds(Int(stopMilliseconds))))
            if position < samples.count { await live.append(Array(samples[position...]), at: Int64(position)) }
            let keyUpText = await live.speculativeText()
            let ending = try await live.finishWithDraft()
            let releaseResult = await release.value
            let chunkDiagnostics = await live.chunkDiagnostics()
            let finishMilliseconds = milliseconds(keyUp.duration(to: clock.now))
            let fullStart = clock.now
            let full = try await recovery.transcribe(file).rawText
            let fullMilliseconds = milliseconds(fullStart.duration(to: clock.now))
            await live.cancel()
            let earlyText = await early.value
            let final = ending.result?.text ?? full
            let normalized = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            var record: [String: Any] = [
                "id": file.lastPathComponent, "seconds": Double(samples.count) / 16_000,
                "words": full.split(whereSeparator: \.isWhitespace).count,
                "finishMilliseconds": finishMilliseconds, "fullMilliseconds": fullMilliseconds,
                // At key-up the app recognizes the recording only when the live path has no final.
                "keyUpToTranscriptMilliseconds": finishMilliseconds + (ending.result == nil ? fullMilliseconds : 0),
                "trusted": ending.result != nil, "trustedMatchesFull": ending.result.map { normalized($0.text) == normalized(full) } ?? NSNull(),
                "draft": ending.draft != nil, "draftMatchesFull": ending.draft.map { normalized($0) == normalized(full) } ?? NSNull(),
                "draftMilliseconds": ending.draftMilliseconds ?? NSNull(),
                "recoveryReasons": await reasons.value,
                // Would a cleanup started before the final transcript stand for it? Early: at the last pause, key held.
                "earlyMatch": earlyText.map { "\(DraftTranscriptMatch(draft: $0.text, final: final))" } ?? NSNull(),
                "earlyLeadMilliseconds": earlyText.map { milliseconds($0.at.duration(to: keyUp)) } ?? NSNull(),
                "keyUpMatch": "\(DraftTranscriptMatch(draft: keyUpText, final: final))",
                // The audio received at key-up, decoded at once for cleanup: would its cleanup stand for the final transcript?
                "releaseMilliseconds": milliseconds(keyUp.duration(to: releaseResult.at)),
                "releaseMatch": releaseResult.text.map { "\(DraftTranscriptMatch(draft: $0, final: final))" } ?? NSNull(),
                "chunks": chunkDiagnostics.chunks, "pauseChunks": chunkDiagnostics.pauses, "chunking": chunkDiagnostics.chunking,
            ]
            if texts { record["releaseText"] = releaseResult.text ?? NSNull() }
            if texts { record["full"] = full; record["draftText"] = ending.draft ?? NSNull(); record["trustedText"] = ending.result?.text ?? NSNull() }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
