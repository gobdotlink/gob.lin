import Foundation
import GoblinEngines
import os

/// The meeting's speech model. When dictation runs on a Parakeet that knows the meeting's languages, it is
/// dictation's own loaded engine, so there is one copy in memory; otherwise a Parakeet v3 the meeting loads for itself and unloads when it ends. It holds no lease
/// on dictation's model: the model can still be switched or unloaded mid-meeting, so it is looked up again for every
/// chunk. Every decode waits its turn behind dictation through `SpeechPriorityGate`.
actor MeetingSpeechEngine: PCMSpeechEngine {
    nonisolated let identifier = SpeechModelCatalog.parakeet.id
    nonisolated let maximumWindowSamples = 240_000
    private let gate: SpeechPriorityGate
    private let dictationEngine: @Sendable () async throws -> (any PCMSpeechEngine)?
    private let onSource: @Sendable (String) -> Void
    private let onDownload: @Sendable (Double?) -> Void
    private var own: SpeechModelRuntime?
    private var ownReady: Task<Void, any Error>?
    private var source: String?

    /// `dictationEngine` answers with dictation's loaded engine, or nil when dictation's model can't serve a meeting.
    /// `onSource` hears which model the transcript uses, each time that changes. `onDownload` hears how far the
    /// meeting's own Parakeet has downloaded (0...1) the first time it's needed, then nil once it's done or failed;
    /// it's never called when the model is already on this Mac.
    init(gate: SpeechPriorityGate, dictationEngine: @escaping @Sendable () async throws -> (any PCMSpeechEngine)?,
         onSource: @escaping @Sendable (String) -> Void = { _ in }, onDownload: @escaping @Sendable (Double?) -> Void = { _ in }) {
        self.gate = gate
        self.dictationEngine = dictationEngine
        self.onSource = onSource
        self.onDownload = onDownload
    }

    func prepare() async throws { _ = try await resolve() }

    /// Unloads the meeting's own copy, if it made one. Dictation's engine is never unloaded from here.
    func unload() async {
        let runtime = own, ready = ownReady
        own = nil
        ownReady = nil
        source = nil
        ready?.cancel()
        _ = try? await ready?.value
        await runtime?.engine.unload()
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let engine = try await resolve()
        return try await gate.runBackground { try await engine.transcribe(request) }
    }

    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        // The engine is found before waiting for a turn, so loading a model never counts as time dictation waited.
        let engine = try await resolve()
        do {
            return try await gate.runBackground { try await engine.transcribe(samples: samples, options: options) }
        } catch SpeechRuntimeError.modelNotInstalled {
            // Dictation's model was unloaded or switched while this chunk waited; look it up once more.
            let engine = try await resolve()
            return try await gate.runBackground { try await engine.transcribe(samples: samples, options: options) }
        }
    }

    private func resolve() async throws -> any PCMSpeechEngine {
        if let engine = try await dictationEngine() {
            // Dictation moved to Parakeet mid-meeting: the spare copy goes.
            if own != nil { await unload() }
            announce("\(engine.identifier), shared with dictation")
            return engine
        }
        let runtime = own ?? SpeechRuntimeFactory.make(SpeechModelCatalog.parakeet)
        own = runtime
        let ready = ownReady ?? Task { [onDownload] in
            let downloading = OSAllocatedUnfairLock(initialState: false)
            defer { if downloading.withLock({ $0 }) { onDownload(nil) } }
            _ = try await runtime.store.ensureAvailable { update in
                guard update.phase == .downloading else { return }
                downloading.withLock { $0 = true }
                onDownload(update.fractionCompleted ?? 0)
            }
            try await runtime.engine.prepare()
        }
        ownReady = ready
        do { try await ready.value } catch {
            if ownReady == ready { ownReady = nil }
            throw error
        }
        announce("\(runtime.engine.identifier), loaded for this meeting")
        return runtime.engine
    }

    private func announce(_ description: String) {
        guard description != source else { return }
        source = description
        onSource(description)
    }
}
