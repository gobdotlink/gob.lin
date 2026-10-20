import Foundation
import GoblinCore

public struct ProcessedTranscript: Sendable {
    public var text: String
    public var tone: String
    public var polished: Bool
    public var warning: String?
    public var processingMilliseconds: Double?

    public init(text: String, tone: String = "formal", polished: Bool = false, warning: String? = nil, processingMilliseconds: Double? = nil) {
        self.text = text
        self.tone = tone
        self.polished = polished
        self.warning = warning
        self.processingMilliseconds = processingMilliseconds
    }
}

public struct TranscriptionRun: Codable, Sendable {
    public var rawText: String
    public var finalText: String
    public var tone: String
    public var polished: Bool
    public var model: String
    public var timings: DictationTimings
    public var postprocessingError: String?
    public var dictionaryUsage: SpeechDictionaryUsage?
}

public enum RecordedAudioError: Error, LocalizedError {
    case engineNotConfigured
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .engineNotConfigured: "No speech engine is configured. Use replay --recorded to evaluate existing transcripts."
        case .invalidFile: "Audio input must be a readable local file."
        }
    }
}

/// The app and CLI can use the same engine and postprocessor for captured files.
public struct RecordedAudioPipeline: Sendable {
    public typealias Postprocessor = @Sendable (String) async throws -> ProcessedTranscript
    public let engine: any SpeechEngine
    private let options: RecognitionOptions
    private let postprocessor: Postprocessor?

    public init(engine: any SpeechEngine, options: RecognitionOptions = .init(), postprocessor: Postprocessor? = nil) {
        self.engine = engine
        self.options = options
        self.postprocessor = postprocessor
    }

    public init(engine: any SpeechEngine, processor: TranscriptPostprocessor, dictionaryEntries: [DictionaryEntry],
                tone: DictationTone, rewriteSettings: RewriteSettings, apiKey: String = "", options: RecognitionOptions = .init()) {
        self.init(engine: engine, options: RecognitionOptions(language: options.language, vocabulary: dictionaryEntries.map(\.spelling))) { raw in
            let result = await processor.process(raw, dictionaryEntries: dictionaryEntries, tone: tone,
                                                 rewriteSettings: rewriteSettings, apiKey: apiKey)
            return ProcessedTranscript(text: result.finalText, tone: result.tone.rawValue, polished: result.polished,
                                       warning: result.warning?.message, processingMilliseconds: result.timings.rewriteMilliseconds)
        }
    }

    public func transcribe(_ audioFileURL: URL) async throws -> TranscriptionRun {
        guard audioFileURL.isFileURL,
              FileManager.default.isReadableFile(atPath: audioFileURL.path),
              try audioFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecordedAudioError.invalidFile
        }
        let recognitionStart = ContinuousClock.now
        let recognition = try await engine.transcribe(TranscriptionRequest(audioFileURL: audioFileURL, options: options))
        let recognitionTime = milliseconds(since: recognitionStart)
        var processed = ProcessedTranscript(text: recognition.text)
        var processingError: String?
        var rewriteTime = 0.0
        if let postprocessor {
            let rewriteStart = ContinuousClock.now
            do { processed = try await postprocessor(recognition.text) }
            catch { processingError = error.localizedDescription }
            rewriteTime = processed.processingMilliseconds ?? milliseconds(since: rewriteStart)
            processingError = processed.warning ?? processingError
        }
        return TranscriptionRun(rawText: recognition.text, finalText: processed.text, tone: processed.tone,
                                polished: processed.polished, model: engine.identifier,
                                timings: DictationTimings(asrMilliseconds: recognitionTime, rewriteMilliseconds: rewriteTime),
                                postprocessingError: processingError, dictionaryUsage: recognition.dictionaryUsage)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
}
