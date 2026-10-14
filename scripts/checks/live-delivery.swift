import Darwin
import Foundation
@testable import GoblinApp
@testable import GoblinEngines

private actor DeliveryEngine: PCMSpeechEngine {
    nonisolated let identifier = SpeechModelCatalog.parakeet.id
    nonisolated let maximumWindowSamples = 240_000
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { .init(text: "") }
    func transcribe(samples: [Float]) async throws -> TranscriptionResult { .init(text: "delivered") }
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
    }
}
