import Foundation
import GoblinCore

public struct SpeechDictionaryUsage: Codable, Equatable, Sendable {
    public let included: [String]
    public let excluded: [String]
    public let tokenCount: Int
    public let tokenLimit: Int
}

public struct RecognitionOptions: Sendable, Hashable, Codable {
    /// Nil requests automatic language detection where the model supports it.
    public let language: String?
    public let vocabulary: [String]
    /// Corrects `vocabulary` terms after recognizing a whole utterance (Parakeet's dictionary correction).
    /// Live preview windows never request it; they are partial and their word timings must match their text.
    public let dictionaryCorrection: Bool
    public init(language: String? = nil, vocabulary: [String] = [], dictionaryCorrection: Bool = false) {
        self.language = language; self.vocabulary = vocabulary; self.dictionaryCorrection = dictionaryCorrection
    }

    /// The same options for a live preview window.
    public var preview: RecognitionOptions { RecognitionOptions(language: language, vocabulary: vocabulary) }

    private enum CodingKeys: CodingKey { case language, vocabulary, dictionaryCorrection }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        vocabulary = try values.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        dictionaryCorrection = try values.decodeIfPresent(Bool.self, forKey: .dictionaryCorrection) ?? false
    }
}

public struct TranscriptionRequest: Sendable {
    public let audioFileURL: URL
    public let options: RecognitionOptions

    public init(audioFileURL: URL, options: RecognitionOptions = .init()) {
        self.audioFileURL = audioFileURL
        self.options = options
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let tokens: [TranscriptionToken]
    public let speechPresence: SpeechPresence?
    public let dictionaryUsage: SpeechDictionaryUsage?

    public init(text: String, tokens: [TranscriptionToken] = [], speechPresence: SpeechPresence? = nil,
                dictionaryUsage: SpeechDictionaryUsage? = nil) {
        self.text = text
        self.tokens = tokens
        self.speechPresence = speechPresence
        self.dictionaryUsage = dictionaryUsage
    }
}

public enum SpeechPresence: Sendable, Equatable {
    case notDetected
    case detected(endSeconds: Double)
}

/// Both the app and evaluation CLI use this boundary.
public protocol SpeechEngine: Sendable {
    var identifier: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public struct TranscriptionToken: Sendable, Equatable, Codable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let confidence: Float
    public let tokenID: Int?

    public init(text: String, startSeconds: Double, endSeconds: Double, confidence: Float, tokenID: Int? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
        self.tokenID = tokenID
    }
}

/// Ordered 16 kHz mono PCM windows; the session coordinator owns tail retention and text commitment.
public protocol PCMSpeechEngine: SpeechEngine {
    var maximumWindowSamples: Int { get }
    func prepare() async throws
    func unload() async
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult
}

public extension PCMSpeechEngine {
    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try await transcribe(samples: samples, options: .init())
    }
}

public struct SpeechModelPreparationProgress: Sendable, Equatable {
    public enum Phase: Sendable { case checkingCache, downloading, compiling, loading }
    public let phase: Phase
    public let fractionCompleted: Double?
    public let component: String?

    public init(phase: Phase, fractionCompleted: Double? = nil, component: String? = nil) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.component = component
    }
}
