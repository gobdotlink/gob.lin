import ArgmaxCore
import CoreML
import FluidAudio
import Foundation
@preconcurrency import WhisperKit

public actor WhisperSpeechEngine: PCMSpeechEngine {
    public nonisolated let identifier: String
    public nonisolated let maximumWindowSamples = 240_000
    private let model: SpeechModelDescriptor
    private let directory: URL
    private var runtime: WhisperKit?
    private var decodingOptions: DecodingOptions?
    private var detector: SpeechActivityDetector?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(model: SpeechModelDescriptor, directory: URL) {
        precondition(model.kind == .whisper)
        self.model = model; self.directory = directory; identifier = model.id
    }

    public func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if runtime != nil { return }
        guard PinnedSpeechModelStore.isDownloaded(model: model, directory: directory) else { throw SpeechRuntimeError.modelNotInstalled }
        try await Self.validateLocalTokenizer(model: model, directory: directory)
        let detector = try SpeechActivityDetector.load(beside: directory)
        let runtime = try await WhisperKit(WhisperKitConfig(modelFolder: directory.path, tokenizerFolder: directory,
            verbose: false, prewarm: false, load: false, download: false))
        do {
            // Tokenizer injection would skip the SDK's model capability initialization.
            try await runtime.loadModels()
            guard runtime.modelVariant == Self.variant(for: model),
                  runtime.textDecoder.isModelMultilingual == runtime.modelVariant.isMultilingual,
                  runtime.tokenizer != nil, let vocabularySize = runtime.textDecoder.logitsSize else {
                throw SpeechModelStoreError.invalidCache
            }
            let configuration = try WhisperGenerationConfiguration.load(from: directory)
            decodingOptions = try configuration.decodingOptions(vocabularySize: vocabularySize)
            // The SDK's inferred whitespace ID can be EOT; use the published IDs directly.
            runtime.textDecoder.logitsFilters = [WhisperBeginSuppressionFilter(tokens: configuration.beginSuppressTokens,
                sampleBegin: runtime.textDecoder.isModelMultilingual ? 4 : 2)]
            try Task.checkCancellation()
        } catch { decodingOptions = nil; await runtime.unloadModels(); throw error }
        self.runtime = runtime
        self.detector = detector
    }

    static func variant(for model: SpeechModelDescriptor) -> ModelVariant {
        switch model.id {
        case "whisper-tiny": .tiny
        case "whisper-tiny-en": .tinyEn
        case "whisper-base": .base
        case "whisper-base-en": .baseEn
        case "whisper-small": .small
        case "whisper-small-en": .smallEn
        case "whisper-medium": .medium
        case "whisper-medium-en": .mediumEn
        case "whisper-large-v3", "whisper-large-v3-turbo": .largev3
        default: preconditionFailure("Unsupported Whisper model: \(model.id)")
        }
    }

    static func validateLocalTokenizer(model: SpeechModelDescriptor, directory: URL) async throws {
        // The SDK prefers its Hub subfolder and falls back to network on parse errors.
        let repository = SpeechModelAssets.manifest(for: model.id).files.first { $0.destination == "tokenizer.json" }!.repository
        let hubFolder = HubApiWrapper(downloadBase: directory).localRepoLocation(.init(id: repository))
        guard !FileManager.default.fileExists(atPath: hubFolder.appendingPathComponent("tokenizer.json").path) else {
            throw SpeechModelStoreError.invalidCache
        }
        _ = try await AutoTokenizerWrapper.from(modelFolder: directory)
    }

    public func unload() async {
        await acquire()
        defer { release() }
        await runtime?.unloadModels()
        runtime = nil; decodingOptions = nil; detector = nil
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard request.audioFileURL.isFileURL, FileManager.default.isReadableFile(atPath: request.audioFileURL.path),
              try request.audioFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RecordedAudioError.invalidFile }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let runtime else { throw SpeechRuntimeError.modelNotInstalled }
        return try await recognize(AudioConverter().resampleAudioFile(request.audioFileURL), runtime: runtime, options: request.options)
    }

    public func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        guard samples.count <= maximumWindowSamples else { throw SpeechRuntimeError.windowTooLong }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SpeechRuntimeError.invalidSamples }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let runtime else { throw SpeechRuntimeError.modelNotInstalled }
        return try await recognize(samples, runtime: runtime, options: options)
    }

    private func recognize(_ samples: [Float], runtime: WhisperKit, options: RecognitionOptions) async throws -> TranscriptionResult {
        let language = try options.validatedLanguage(for: model)
        guard let detector else { throw SpeechRuntimeError.speechDetectorNotInstalled }
        guard var decodeOptions = decodingOptions else { throw SpeechRuntimeError.modelNotInstalled }
        let presence = try await detector.presence(in: samples)
        guard presence != .notDetected else { return .init(text: "", speechPresence: .notDetected) }
        decodeOptions.language = language
        decodeOptions.detectLanguage = language == nil && runtime.textDecoder.isModelMultilingual
        decodeOptions.windowClipTime = samples.count <= WhisperKit.sampleRate ? 0 : 1
        let results = try await runtime.transcribe(audioArray: samples, decodeOptions: decodeOptions)
        try Task.checkCancellation()
        let tokens = results.flatMap(\.allWords).map {
            TranscriptionToken(text: $0.word, startSeconds: Double($0.start), endSeconds: Double($0.end), confidence: $0.probability)
        }
        return .init(text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                     tokens: tokens, speechPresence: presence)
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

struct WhisperGenerationConfiguration: Decodable {
    let suppressTokens: [Int]
    let beginSuppressTokens: [Int]

    enum CodingKeys: String, CodingKey {
        case suppressTokens = "suppress_tokens"
        case beginSuppressTokens = "begin_suppress_tokens"
    }

    static func load(from directory: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("generation_config.json")))
        } catch { throw SpeechModelStoreError.invalidCache }
    }

    func decodingOptions(vocabularySize: Int) throws -> DecodingOptions {
        guard (suppressTokens + beginSuppressTokens).allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw SpeechModelStoreError.invalidCache
        }
        return DecodingOptions(task: .transcribe, skipSpecialTokens: true, wordTimestamps: true,
                               suppressTokens: suppressTokens, concurrentWorkerCount: 1)
    }
}

struct WhisperBeginSuppressionFilter: LogitsFiltering {
    let filter: SuppressTokensFilter
    let sampleBegin: Int

    init(tokens: [Int], sampleBegin: Int) {
        filter = SuppressTokensFilter(suppressTokens: tokens)
        self.sampleBegin = sampleBegin
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        tokens.count == sampleBegin ? filter.filterLogits(logits, withTokens: tokens) : logits
    }
}
