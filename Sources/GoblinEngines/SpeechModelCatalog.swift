import Foundation

public struct SpeechModelCapabilities: Sendable, Equatable {
    public let sampleRate: Int
    public let fileTranscription: Bool
    public let pcmTranscription: Bool
    public let nativeStreaming: Bool
    public let customVocabulary: Bool
    public let languageCodes: [String]
}

public struct SpeechModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let runtime: String
    public let capabilities: SpeechModelCapabilities
}

public enum SpeechModelCatalog {
    public static let parakeet = SpeechModelDescriptor(
        id: "parakeet-tdt-v3", name: "Parakeet TDT v3", runtime: "FluidAudio · Core ML",
        capabilities: SpeechModelCapabilities(
            sampleRate: 16_000, fileTranscription: true, pcmTranscription: true,
            nativeStreaming: false, customVocabulary: false,
            languageCodes: ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                            "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]))
    public static let supported = [parakeet]
    public static let defaultModel = parakeet
}

public enum SpeechModelCacheUse: String, Sendable, Codable { case installed, cached }

public protocol SpeechModelAcquiring: Sendable {
    var directory: URL { get }
    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse
    func removeCachedModel() async throws
}
