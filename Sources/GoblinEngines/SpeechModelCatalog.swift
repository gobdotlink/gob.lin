import Foundation

public enum SpeechLanguageControl: Sendable, Equatable { case fixed, scriptHint, hint, explicit }
public enum SpeechRuntimeKind: Sendable, Equatable { case parakeet, whisper, senseVoice, nemotron }

public struct SpeechModelCapabilities: Sendable, Equatable {
    public let sampleRate = 16_000
    public let fileTranscription = true
    public let pcmTranscription = true
    public let nativeStreaming = false
    /// Whisper's decoder prompt: preferred spellings guide decoding within a token budget.
    public let customVocabulary: Bool
    public let livePreview: Bool
    public let automaticLanguage: Bool
    public let languageControl: SpeechLanguageControl
    public let languageCodes: [String]

    public func options(for intent: String) -> RecognitionOptions {
        let preferred = SpeechModelCatalog.canonicalLanguage(intent)
        if let language = languageCodes.first(where: { SpeechModelCatalog.canonicalLanguage($0) == preferred }) {
            return RecognitionOptions(language: language)
        }
        return RecognitionOptions(language: automaticLanguage ? nil : (languageCodes.contains("en") ? "en" : languageCodes.first))
    }
}

public struct SpeechModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let purpose: String
    public let detail: String
    public let recommended: Bool
    public let kind: SpeechRuntimeKind
    public let cacheFolder: String
    public let capabilities: SpeechModelCapabilities
    /// Mid-month of the month the upstream model was published, so time zone shifts never change the month.
    public let released: Date
    public var downloadBytes: Int64 { SpeechModelAssets.manifest(for: id).files.reduce(0) { $0 + $1.size } }
    public var runtime: String { kind == .whisper ? "WhisperKit · Core ML" : "FluidAudio · Core ML" }
    public var selectionSummary: String {
        switch id {
        case "parakeet-tdt-v3": "Efficient everyday dictation in European languages."
        case "whisper-tiny": "Small download; lower accuracy on difficult speech."
        case "whisper-large-v3-turbo": "100 languages; a smaller download than full Large v3."
        case "whisper-large-v3": "Full-size multilingual. More memory and processing time."
        case "parakeet-redux": "Smaller encoder; the same languages as Parakeet v3."
        case "parakeet-ultra": "Retrained Parakeet with a larger encoder."
        case "phonon-2": "Compressed English-only Parakeet derivative."
        case "parakeet-tdt-ctc-110m": "Compact English-only model with 110M parameters."
        case "sensevoice-small": "East Asian languages and English. Text after recording."
        case "nemotron-3.5": "Multilingual alternative with text while speaking."
        default: capabilities.languageControl == .fixed
            ? "English only. Larger sizes need more memory."
            : "Broad language coverage. Larger sizes need more memory."
        }
    }
}

public enum SpeechModelCatalog {
    public static let parakeet = model("parakeet-tdt-v3", "Parakeet TDT v3", purpose: "Everyday default",
        detail: "Efficient dictation across 25 European languages. A preferred language guides the writing script; it cannot force one language over another using the same script.",
        kind: .parakeet, released: (2025, 8), folder: "parakeet-tdt-0.6b-v3", control: .scriptHint)
    public static let whisperTiny = model("whisper-tiny", "Whisper Tiny", purpose: "Compact multilingual",
        detail: "A compact multilingual model for short, simple speech when download size matters more than accuracy.", kind: .whisper, released: (2022, 9))
    public static let whisperTurbo = model("whisper-large-v3-turbo", "Whisper Large v3 Turbo", purpose: "Broad language coverage",
        detail: "A compressed multilingual model with a smaller decoder than full Large v3. Supports automatic or explicit language selection.", kind: .whisper, released: (2024, 10))
    public static let whisperLarge = model("whisper-large-v3", "Whisper Large v3", purpose: "Full-size multilingual",
        detail: "The full multilingual model for difficult recordings. Requires a larger download and more memory and processing time.", kind: .whisper, released: (2023, 11))
    public static let whisperTinyEnglish = whisper("tiny", english: true)
    public static let whisperBase = whisper("base")
    public static let whisperBaseEnglish = whisper("base", english: true)
    public static let whisperSmall = whisper("small")
    public static let whisperSmallEnglish = whisper("small", english: true)
    public static let whisperMedium = whisper("medium")
    public static let whisperMediumEnglish = whisper("medium", english: true)
    public static let parakeetRedux = model("parakeet-redux", "Parakeet Redux", purpose: "Compact European-language model",
        detail: "A ternary retraining of Parakeet v3 with a smaller encoder. Covers the same 25 languages and offers writing-script hints.",
        kind: .parakeet, released: (2026, 9), recommended: false, control: .scriptHint)
    public static let parakeetUltra = model("parakeet-ultra", "Parakeet Ultra", purpose: "Retrained multilingual Parakeet",
        detail: "A post-trained Parakeet v3 derivative with a larger encoder. An alternative for difficult dictation across 25 European languages; offers writing-script hints.",
        kind: .parakeet, released: (2026, 9), recommended: false, control: .scriptHint)
    public static let phonon = model("phonon-2", "Phonon-2", purpose: "Compact English Parakeet derivative",
        detail: "An English-only retraining of Parakeet with compressed five-value encoder weights. Uses the fixed 15-second encoder conversion.",
        kind: .parakeet, released: (2026, 9), recommended: false, automatic: false, control: .fixed)
    public static let parakeetCompact = model("parakeet-tdt-ctc-110m", "Parakeet TDT-CTC 110M", purpose: "Small English transducer",
        detail: "A 110-million-parameter English recognizer with a smaller decoder and vocabulary than Parakeet v3. A compact alternative to the larger English models.",
        kind: .parakeet, released: (2024, 9), recommended: false, automatic: false, control: .fixed)
    public static let senseVoice = model("sensevoice-small", "SenseVoice Small", purpose: "Chinese, Cantonese, Japanese and Korean",
        detail: "A compact recognizer for Mandarin, Cantonese, English, Japanese and Korean. Offers automatic detection or a language hint. Text appears after recording.",
        kind: .senseVoice, released: (2024, 7), recommended: false, preview: false, control: .hint)
    public static let nemotron = model("nemotron-3.5", "Nemotron 3.5", purpose: "Streaming-trained multilingual alternative",
        detail: "A cache-aware 2026 recognizer with automatic detection or language hints. Offers 28 languages that support transcription without further training. The app uses bounded live-preview windows.",
        kind: .nemotron, released: (2026, 6), recommended: false, control: .hint)
    public static let supported = [parakeet, whisperTiny, whisperTurbo, whisperLarge,
        parakeetRedux, parakeetUltra, phonon, parakeetCompact, senseVoice, nemotron,
        whisperTinyEnglish, whisperBase, whisperBaseEnglish, whisperSmall, whisperSmallEnglish, whisperMedium, whisperMediumEnglish]
    public static var recommended: [SpeechModelDescriptor] { supported.filter(\.recommended) }
    public static let defaultModel = parakeet

    public static func model(id: String) -> SpeechModelDescriptor? { supported.first { $0.id == id } }

    public static func matching(query: String = "", language: String? = nil, livePreviewOnly: Bool = false,
                                recommendedOnly: Bool = false) -> [SpeechModelDescriptor] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return supported.filter { model in
            if recommendedOnly && !model.recommended { return false }
            if livePreviewOnly && !model.capabilities.livePreview { return false }
            if let language, !model.capabilities.languageCodes.contains(where: { canonicalLanguage($0) == canonicalLanguage(language) }) { return false }
            let names = model.capabilities.languageCodes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            let text = ([model.name, model.purpose, model.detail] + names).joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    public static func canonicalLanguage(_ value: String) -> String {
        let base = value.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "auto"
        switch base { case "nb": return "no"; case "fil": return "tl"; default: return base }
    }

    private static func whisper(_ size: String, english: Bool = false) -> SpeechModelDescriptor {
        let name = size.capitalized
        return model("whisper-\(size)\(english ? "-en" : "")", "Whisper \(name)\(english ? " (English)" : "")",
            purpose: english ? "\(name) English-only" : "\(name) multilingual",
            detail: english ? "An English-only Whisper model. Choose its size to trade download and memory use against recognition quality; other languages require a multilingual model."
                : "An intermediate Whisper size between Tiny and Large. Offers broad language coverage with automatic detection or explicit language selection.",
            kind: .whisper, released: (2022, 9), recommended: false, automatic: !english, control: english ? .fixed : .explicit)
    }

    private static func model(_ id: String, _ name: String, purpose: String, detail: String, kind: SpeechRuntimeKind,
                              released: (year: Int, month: Int), recommended: Bool = true,
                              folder: String? = nil, automatic: Bool = true, preview: Bool = true,
                              control: SpeechLanguageControl = .explicit) -> SpeechModelDescriptor {
        SpeechModelDescriptor(id: id, name: name, purpose: purpose, detail: detail, recommended: recommended, kind: kind, cacheFolder: folder ?? id,
            capabilities: SpeechModelCapabilities(customVocabulary: kind == .whisper,
                                                 livePreview: preview, automaticLanguage: automatic, languageControl: control,
                                                 languageCodes: SpeechModelAssets.manifest(for: id).languages),
            released: Calendar(identifier: .gregorian).date(from: DateComponents(year: released.year, month: released.month, day: 15))!)
    }
}

public enum SpeechModelCacheUse: String, Sendable, Codable { case installed, cached }

public protocol SpeechModelAcquiring: Sendable {
    var directory: URL { get }
    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse
    func removeCachedModel() async throws
}

struct SpeechModelAsset: Codable, Sendable {
    let repository: String
    let revision: String
    let path: String
    let destination: String
    let size: Int64
    let sha256: String
    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")! }
}

struct SpeechModelManifest: Codable, Sendable {
    let languages: [String]
    let files: [SpeechModelAsset]
}

enum SpeechModelAssets {
    private static let manifests: [String: SpeechModelManifest] = {
        do {
            // Signed apps keep SwiftPM bundles in Contents/Resources rather than beside the executable.
            let packaged = Bundle.main.resourceURL?.appendingPathComponent("Goblin_GoblinEngines.bundle", isDirectory: true)
            let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
            let url = bundle.url(forResource: "speech-model-assets", withExtension: "json")!
            return try JSONDecoder().decode([String: SpeechModelManifest].self, from: Data(contentsOf: url))
        } catch { preconditionFailure("Invalid bundled speech model catalog: \(error)") }
    }()

    static func manifest(for id: String) -> SpeechModelManifest {
        guard let manifest = manifests[id] else { preconditionFailure("Missing speech model assets: \(id)") }
        return manifest
    }
}
