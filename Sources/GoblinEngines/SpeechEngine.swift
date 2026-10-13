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

    public init(text: String, tokens: [TranscriptionToken] = []) {
        self.text = text
        self.tokens = tokens
    }
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

    public init(text: String, startSeconds: Double, endSeconds: Double, confidence: Float) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

/// Ordered 16 kHz mono PCM windows; the session coordinator owns tail retention and text commitment.
public protocol PCMSpeechEngine: SpeechEngine {
    var maximumWindowSamples: Int { get }
    func prepare() async throws
    func unload() async
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
}
