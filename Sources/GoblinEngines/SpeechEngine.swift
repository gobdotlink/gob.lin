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

    public init(text: String) {
        self.text = text
    }
}

/// Both the app and evaluation CLI use this boundary; engine selection follows the benchmark.
public protocol SpeechEngine: Sendable {
    var identifier: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
