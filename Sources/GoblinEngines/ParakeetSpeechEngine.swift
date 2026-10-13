import Foundation
import FluidAudio

public enum SpeechRuntimeError: Error, LocalizedError {
    case invalidSamples
    case windowTooLong
    case modelNotInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidSamples: "Speech samples must be finite, normalized 16 kHz mono PCM."
        case .windowTooLong: "Live recognition windows must be at most 15 seconds."
        case .modelNotInstalled: "Parakeet is not installed. Prepare the model before transcription."
        }
    }
}

/// One model and one serialized inference owner, shared by file and bounded-tail recognition.
public actor ParakeetSpeechEngine: PCMSpeechEngine {
    public nonisolated let identifier = "parakeet-tdt-v3"
    public nonisolated let maximumWindowSamples = 240_000
    public nonisolated let modelDirectory: URL
    private var manager: AsrManager?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }

    public init(modelDirectory: URL = ParakeetSpeechEngine.defaultModelDirectory) {
        self.modelDirectory = modelDirectory
    }

    public func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if manager != nil { return }
        guard AsrModels.modelsExist(at: modelDirectory, version: .v3) else {
            throw SpeechRuntimeError.modelNotInstalled
        }
        let models = try AsrModels.loadLocal(from: modelDirectory, version: .v3, encoderPrecision: .int8)
        try Task.checkCancellation()
        let loadedManager = AsrManager(config: .default)
        try await loadedManager.loadModels(models)
        if Task.isCancelled {
            await loadedManager.cleanup()
            throw CancellationError()
        }
        manager = loadedManager
    }

    public func unload() async {
        await acquire()
        defer { release() }
        await manager?.cleanup()
        manager = nil
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard request.audioFileURL.isFileURL,
              FileManager.default.isReadableFile(atPath: request.audioFileURL.path),
              try request.audioFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecordedAudioError.invalidFile
        }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let manager else { throw SpeechRuntimeError.modelNotInstalled }
        var state = TdtDecoderState.make(decoderLayers: 2)
        let result = try await manager.transcribe(request.audioFileURL, decoderState: &state)
        try Task.checkCancellation()
        return Self.result(result)
    }

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        guard samples.count <= maximumWindowSamples else { throw SpeechRuntimeError.windowTooLong }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SpeechRuntimeError.invalidSamples }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let manager else { throw SpeechRuntimeError.modelNotInstalled }
        if samples.isEmpty { return TranscriptionResult(text: "") }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: 2)
        let result = try await manager.transcribe(padded, decoderState: &state)
        try Task.checkCancellation()
        return Self.result(result)
    }

    private static func result(_ result: ASRResult) -> TranscriptionResult {
        TranscriptionResult(text: result.text, tokens: (result.tokenTimings ?? []).map {
            TranscriptionToken(text: $0.token, startSeconds: $0.startTime, endSeconds: $0.endTime, confidence: $0.confidence)
        })
    }

    // Actor methods reenter at await; the gate also protects the SDK's mutable decoder/model state.
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
