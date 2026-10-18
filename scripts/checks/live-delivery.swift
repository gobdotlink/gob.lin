import Darwin
import AppKit
import Foundation
import GoblinCore
@testable import GoblinApp
@testable import GoblinEngines

private actor DeliveryEngine: PCMSpeechEngine {
    nonisolated let identifier = SpeechModelCatalog.parakeet.id
    nonisolated let maximumWindowSamples = 240_000
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { .init(text: "") }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult { .init(text: "delivered") }
}

private actor DeliveryStore: SpeechModelAcquiring {
    nonisolated let directory = URL(fileURLWithPath: "/unused-delivery-check")
    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse { .cached }
    func removeCachedModel() async throws {}
}

@main
struct LiveDeliveryCheck {
    @MainActor static func main() async throws {
        let suite = "app.goblin.delivery-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = DeliveryEngine()
        let models = SpeechModelService(engine: engine, store: DeliveryStore(), defaults: defaults)
        let lease = try models.beginSession()
        let active = ActiveDictation(session: DictationSession(target: nil), lease: lease,
            readiness: Task<any PCMSpeechEngine, Error> { engine })
        let frames = active.frames, live = active.live, handler = active.onEvent
        let consumer = Task.detached {
            var positions: [Int64] = []
            for await frame in frames {
                positions.append(frame.samplePosition)
                await live.append(frame.samples, at: frame.samplePosition)
            }
            return positions
        }
        let feeder = Task.detached {
            let id = UUID()
            for frame in 0..<200 {
                handler(.frame(.init(sessionID: id, samplePosition: Int64(frame * 160), samples: .init(repeating: 0.1, count: 160))))
                handler(.level(sessionID: id, rms: Double(frame)))
                try await Task.sleep(for: .milliseconds(2))
            }
            handler(.cancelled(sessionID: id))
        }
        // Deliberately block rendering longer than the old mixed queue's entire capacity.
        usleep(1_000_000)
        try await feeder.value
        let positions = await consumer.value
        precondition(positions == (0..<200).map { Int64($0 * 160) }, "UI stall dropped or reordered live audio")
        let needsRecovery = await live.requiresFinalRecovery
        precondition(!needsRecovery, "UI stall forced original-file recovery")
        var controlCount = 0
        for await event in active.events {
            guard case .cancelled = event else { preconditionFailure("Audio or meter leaked into control events") }
            controlCount += 1
        }
        precondition(controlCount == 1, "Terminal control event was lost")
        var meterValues: [Double] = []
        for await rms in active.levels { meterValues.append(rms) }
        precondition(meterValues == [199], "Meter retained a backlog instead of the latest snapshot")
        await live.cancel()
        models.endSession(lease)
        await models.shutdown()
        print("Live delivery passed: 200 ordered audio frames survive a one-second UI stall; meter coalesces and terminal events drain.")
        try await checkEmptyCleanupCompletion()
    }

    @MainActor private static func checkEmptyCleanupCompletion() async throws {
        _ = NSApplication.shared
        let suite = "app.goblin.empty-cleanup-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false)
        model.lastTranscript = "Previous transcript."
        await model.history.reload()
        let fixtures: [(TranscriptProcessingResult, String?)] = [
            (.init(rawText: "um uh erm", finalText: "", tone: .formal, polished: true), nil),
            (.init(rawText: "", finalText: "", tone: .formal, polished: false), DiagnosticFailure.noTranscriptAvailable.message),
            (.init(rawText: "uh", finalText: "", tone: .formal, polished: false, warning: .rewrite(.transport)), DiagnosticFailure.rewrite(.transport).message),
        ]
        for (result, expectedWarning) in fixtures {
            let audio = directory.appendingPathComponent(UUID().uuidString + ".wav")
            let syntheticBytes = Data([0x52, 0x49, 0x46, 0x46])
            try syntheticBytes.write(to: audio)
            let session = DictationSession(target: nil)
            try await model.finishDictation(result, model: "fixture", audioURL: audio, duration: 1,
                                            timings: DictationTimings(), session: session)
            let entry = model.history.entries.first { $0.id == session.id }
            precondition(entry?.rawText == result.rawText && entry?.finalText == "" && entry?.polished == result.polished,
                         "Empty cleanup lost the original History entry")
            precondition(entry?.processingWarning == expectedWarning, "Intentional empty cleanup became a dictation failure")
            precondition(model.lastTranscript == "Previous transcript." && model.insertion.outcome == .idle,
                         "Empty cleanup changed the previous transcript or attempted insertion")
            guard let savedAudio = try await model.history.store?.audioFileURL(for: session.id) else { preconditionFailure("Missing original audio") }
            let savedBytes = try Data(contentsOf: savedAudio)
            precondition(savedBytes == syntheticBytes, "Empty cleanup lost the original audio")
            precondition(session.audioOwnedByHistory && !FileManager.default.fileExists(atPath: audio.path), "Capture ownership was not transferred")
        }
        await model.shutdown()
        print("Empty cleanup completion passed: no insertion or failure; original text/audio retained; missing ASR and provider errors still warn.")
    }
}
