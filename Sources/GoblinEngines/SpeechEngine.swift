import Foundation
import GoblinCore

public struct TranscriptionRequest: Sendable {
    public let audioFileURL: URL

    public init(audioFileURL: URL) {
        self.audioFileURL = audioFileURL
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let tokens: [TranscriptionToken]
    public let speechPresence: SpeechPresence?

    public init(text: String, tokens: [TranscriptionToken] = [], speechPresence: SpeechPresence? = nil) {
        self.text = text
        self.tokens = tokens
        self.speechPresence = speechPresence
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
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
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
