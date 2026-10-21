import Foundation
import FluidAudio
import CoreML

public enum SpeechRuntimeError: Error, LocalizedError {
    case invalidSamples
    case windowTooLong
    case modelNotInstalled
    case speechDetectorNotInstalled
    case languageRequired
    case unsupportedLanguage(String)
    case decoderLimit

    public var errorDescription: String? {
        switch self {
        case .invalidSamples: "Speech samples must be finite, normalized 16 kHz mono PCM."
        case .windowTooLong: "Live recognition windows must be at most 15 seconds."
        case .modelNotInstalled: "The selected speech model is not installed. Prepare the model before transcription."
        case .speechDetectorNotInstalled: "The speech detector is missing. Retry model preparation in Settings while online."
        case .languageRequired: "This model requires an explicit recognition language."
        case .unsupportedLanguage(let code): "This model does not support the recognition language \(code)."
        case .decoderLimit: "The model could not finish decoding this audio. The recording is kept; try another speech model."
        }
    }
}

/// Engines whose dictionary correction loads a separately downloaded model, only while the dictionary has terms.
public protocol DictionaryCorrectingEngine: PCMSpeechEngine {
    /// Returns whether correction is loaded into the prepared engine; an unprepared engine is skipped.
    @discardableResult func prepareDictionaryCorrection() async throws -> Bool
    func unloadDictionaryCorrection() async
}

/// One model and one serialized inference owner, shared by file and bounded-tail recognition.
public actor ParakeetSpeechEngine: DictionaryCorrectingEngine {
    public nonisolated let identifier: String
    public nonisolated let maximumWindowSamples = 240_000
    public nonisolated let modelDirectory: URL
    /// Present for models with dictionary correction. It loads on demand, after the model, while there are terms.
    public nonisolated let dictionaryCorrection: ParakeetDictionaryCorrection?
    private let model: SpeechModelDescriptor
    let version: AsrModelVersion
    private var manager: AsrManager?
    private var speechDetector: SpeechActivityDetector?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    public init(model: SpeechModelDescriptor = SpeechModelCatalog.parakeet,
                modelDirectory: URL = ParakeetSpeechEngine.defaultModelDirectory,
                dictionaryCorrection: ParakeetDictionaryCorrection? = nil) {
        precondition(model.kind == .parakeet)
        precondition(dictionaryCorrection == nil || model.capabilities.dictionaryCorrection)
        self.model = model
        identifier = model.id
        version = Self.version(for: model)
        self.modelDirectory = modelDirectory
        self.dictionaryCorrection = dictionaryCorrection
    }

    static func version(for model: SpeechModelDescriptor) -> AsrModelVersion {
        switch model.id {
        case "parakeet-tdt-v3": .v3
        case "parakeet-redux": .redux
        case "parakeet-ultra": .ultra
        case "phonon-2": .phonon2
        case "parakeet-tdt-ctc-110m": .tdtCtc110m
        default: preconditionFailure("Unsupported Parakeet model: \(model.id)")
        }
    }

    public func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if manager != nil, speechDetector != nil { return }
        guard PinnedSpeechModelStore.isDownloaded(model: model, directory: modelDirectory) else {
            throw SpeechRuntimeError.modelNotInstalled
        }
        let detector = try SpeechActivityDetector.load(beside: modelDirectory)
        let models = try AsrModels.loadLocal(from: modelDirectory, version: version, encoderPrecision: .int8)
        try Task.checkCancellation()
        let loadedManager = AsrManager(config: .default)
        try await loadedManager.loadModels(models)
        if Task.isCancelled {
            await loadedManager.cleanup()
            throw CancellationError()
        }
        manager = loadedManager
        speechDetector = detector
    }

    /// Loads correction into a prepared engine. An unprepared engine is skipped; its owner calls this again after
    /// `prepare`, so an empty dictionary never loads the correction model. Loading doesn't hold the inference gate:
    /// recognition continues meanwhile and corrects once the model is loaded. An unload during the load discards it.
    @discardableResult public func prepareDictionaryCorrection() async throws -> Bool {
        guard manager != nil, let dictionaryCorrection else { return false }
        return try await dictionaryCorrection.load()
    }

    public func unloadDictionaryCorrection() async {
        await dictionaryCorrection?.unload()
    }

    public func unload() async {
        await acquire()
        defer { release() }
        // Cleared before awaiting, so no correction load starts for a recognizer that is going away.
        let unloading = manager
        manager = nil
        speechDetector = nil
        await dictionaryCorrection?.unload()
        await unloading?.cleanup()
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
        let samples = try AudioConverter().resampleAudioFile(request.audioFileURL)
        return try await recognize(samples, manager: manager, options: request.options)
    }

    public func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        guard samples.count <= maximumWindowSamples else { throw SpeechRuntimeError.windowTooLong }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SpeechRuntimeError.invalidSamples }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let manager else { throw SpeechRuntimeError.modelNotInstalled }
        return try await recognize(samples, manager: manager, options: options)
    }

    private func recognize(_ samples: [Float], manager: AsrManager, options: RecognitionOptions) async throws -> TranscriptionResult {
        guard let speechDetector else { throw SpeechRuntimeError.speechDetectorNotInstalled }
        let code = try options.validatedLanguage(for: model)
        let language = code.flatMap(Language.init(rawValue:))
        let presence = try await speechDetector.presence(in: samples)
        try Task.checkCancellation()
        guard presence != .notDetected else {
            return TranscriptionResult(text: "", speechPresence: .notDetected)
        }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await manager.transcribe(padded, decoderState: &state, language: language)
        try Task.checkCancellation()
        let recognition = Self.result(result, speechPresence: presence)
        // An empty dictionary, a live preview or a correction model that isn't loaded yet means no extra pass.
        guard options.dictionaryCorrection, !options.vocabulary.isEmpty, let dictionaryCorrection,
              await dictionaryCorrection.isLoaded else { return recognition }
        let text: String
        do {
            text = try await dictionaryCorrection.correct(recognition, samples: samples, terms: options.vocabulary, language: code,
                                                          candidates: model.capabilities.languageCodes)
        }
        catch is CancellationError { throw CancellationError() }
        catch { return recognition }  // Correction failure keeps the recognized text.
        try Task.checkCancellation()
        // Token timings still describe the recognized words, before correction.
        return TranscriptionResult(text: text, tokens: recognition.tokens, speechPresence: recognition.speechPresence)
    }

    private static func result(_ result: ASRResult, speechPresence: SpeechPresence) -> TranscriptionResult {
        TranscriptionResult(text: result.text, tokens: (result.tokenTimings ?? []).map {
            TranscriptionToken(text: $0.token, startSeconds: $0.startTime, endSeconds: $0.endTime, confidence: $0.confidence, tokenID: $0.tokenId)
        }, speechPresence: speechPresence)
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
