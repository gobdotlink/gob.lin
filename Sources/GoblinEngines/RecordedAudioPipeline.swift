import Foundation
import GoblinCore

public struct ProcessedTranscript: Sendable {
    public var text: String
    public var tone: String
    public var polished: Bool

    public init(text: String, tone: String = "formal", polished: Bool = false) {
        self.text = text
        self.tone = tone
        self.polished = polished
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
}

public enum RecordedAudioError: Error, LocalizedError {
    case engineNotConfigured
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .engineNotConfigured: "No speech engine is configured. Engine selection follows the benchmark; use replay --recorded to evaluate existing transcripts."
        case .invalidFile: "Audio input must be a readable local file."
        }
    }
}

/// The app and CLI can use the same engine and postprocessor for captured files.
public struct RecordedAudioPipeline: Sendable {
    public typealias Postprocessor = @Sendable (String) async throws -> ProcessedTranscript
    public let engine: any SpeechEngine
    private let postprocessor: Postprocessor?

    public init(engine: any SpeechEngine, postprocessor: Postprocessor? = nil) {
        self.engine = engine
        self.postprocessor = postprocessor
    }

    public func transcribe(_ audioFileURL: URL) async throws -> TranscriptionRun {
        guard audioFileURL.isFileURL,
              FileManager.default.isReadableFile(atPath: audioFileURL.path),
              try audioFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecordedAudioError.invalidFile
        }
        let recognitionStart = ContinuousClock.now
        let recognition = try await engine.transcribe(TranscriptionRequest(audioFileURL: audioFileURL))
        let recognitionTime = milliseconds(since: recognitionStart)
        var processed = ProcessedTranscript(text: recognition.text)
        var processingError: String?
        var rewriteTime = 0.0
        if let postprocessor {
            let rewriteStart = ContinuousClock.now
            do { processed = try await postprocessor(recognition.text) }
            catch { processingError = error.localizedDescription }
            rewriteTime = milliseconds(since: rewriteStart)
        }
        return TranscriptionRun(rawText: recognition.text, finalText: processed.text, tone: processed.tone,
                                polished: processed.polished, model: engine.identifier,
                                timings: DictationTimings(asrMilliseconds: recognitionTime, rewriteMilliseconds: rewriteTime),
                                postprocessingError: processingError)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
}
