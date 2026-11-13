import Foundation

public struct DictationTimings: Codable, Sendable, Equatable {
    public var captureMilliseconds: Double
    public var trimMilliseconds: Double
    public var asrMilliseconds: Double
    public var rewriteMilliseconds: Double
    public var insertionMilliseconds: Double

    public init(captureMilliseconds: Double = 0, trimMilliseconds: Double = 0,
                asrMilliseconds: Double = 0, rewriteMilliseconds: Double = 0,
                insertionMilliseconds: Double = 0) {
        self.captureMilliseconds = captureMilliseconds
        self.trimMilliseconds = trimMilliseconds
        self.asrMilliseconds = asrMilliseconds
        self.rewriteMilliseconds = rewriteMilliseconds
        self.insertionMilliseconds = insertionMilliseconds
    }

    public var processingMilliseconds: Double {
        trimMilliseconds + asrMilliseconds + rewriteMilliseconds + insertionMilliseconds
    }
}

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var rawText: String
    public var finalText: String
    public var tone: String
    public var polished: Bool
    public var targetBundleIdentifier: String?
    public var targetApplicationName: String?
    /// The app frontmost when dictation started, whose dictionary scope applied; "" when none (gob.lin itself).
    /// It can differ from the target when text is delivered to the field focused at the end.
    public var dictionaryBundleIdentifier: String?
    /// The project detected where dictation started, for project-scoped terms; nil when none was found.
    public var dictionaryProject: String?
    public var createdAt: Date
    public var completedAt: Date
    public var audioDuration: Double
    public var wordCount: Int
    public var model: String
    public var latencies: DictationTimings
    public var starred: Bool
    public var processingWarning: String?
    /// Post-paste edit observation, filled in after insertion when the target could be watched.
    public var editOutcome: EditOutcome?
    public var editDistance: Int?
    public var maximumEditDistance: Int?
    /// The pasted span's final text. Stored only when the outcome is `edited`:
    /// beyond the edit threshold the field may hold unrelated typing.
    public var editedText: String?
    /// The ID of the device that made this entry. Nil means it was made here, before devices were recorded,
    /// so every reader treats nil as this device.
    public var device: String?
    public internal(set) var audioFilename: String?

    public init(id: UUID = UUID(), rawText: String, finalText: String, tone: String = "formal",
                polished: Bool = false, targetBundleIdentifier: String? = nil,
                targetApplicationName: String? = nil, dictionaryBundleIdentifier: String? = nil, dictionaryProject: String? = nil, createdAt: Date = Date(),
                completedAt: Date = Date(), audioDuration: Double = 0, model: String = "",
                latencies: DictationTimings = DictationTimings(), starred: Bool = false, processingWarning: String? = nil) {
        self.id = id
        self.rawText = rawText
        self.finalText = finalText
        self.tone = tone
        self.polished = polished
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetApplicationName = targetApplicationName
        self.dictionaryBundleIdentifier = dictionaryBundleIdentifier
        self.dictionaryProject = dictionaryProject
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.audioDuration = audioDuration
        self.wordCount = finalText.split(whereSeparator: { $0.isWhitespace }).count
        self.model = model
        self.latencies = latencies
        self.starred = starred
        self.processingWarning = processingWarning
        self.audioFilename = nil
    }
}

extension HistoryEntry {
    /// The app whose dictionary terms reprocessing should use. Entries saved before scopes fall back to the target.
    public var dictionaryScope: String? { dictionaryBundleIdentifier ?? targetBundleIdentifier }

    /// The app and project whose dictionary terms reprocessing should use.
    public var dictionaryContext: DictionaryScope { DictionaryScope(application: dictionaryScope, project: dictionaryProject) }
}

public struct HistoryRetention: Codable, Sendable, Equatable {
    public var maximumUnstarredCount: Int?
    public var maximumAgeDays: Int?

    public init(maximumUnstarredCount: Int? = nil, maximumAgeDays: Int? = nil) {
        self.maximumUnstarredCount = maximumUnstarredCount
        self.maximumAgeDays = maximumAgeDays
    }

    /// Whether this keeps something `other` trims: a limit raised or lifted. A synced History then fetches everything
    /// again, see `HistorySyncEngine.fetchAll()`.
    public func keepsMore(than other: HistoryRetention) -> Bool {
        func looser(_ new: Int?, _ old: Int?) -> Bool { old.map { old in new.map { $0 > old } ?? true } ?? false }
        return looser(maximumUnstarredCount, other.maximumUnstarredCount) || looser(maximumAgeDays, other.maximumAgeDays)
    }
}

public enum HistoryError: Error, LocalizedError, Sendable {
    case database(String)
    case unsupportedSchema(Int)
    case unsafeAudioPath
    case invalidRetention
    case entryNotFound
    case invalidAudioFile

    public var errorDescription: String? {
        switch self {
        case .database(let message): "History database: \(message)"
        case .unsupportedSchema(let version): "History was created by a newer gob.lin (schema \(version)). Update the app; your history has been left untouched."
        case .unsafeAudioPath: "History refused an audio path outside its data folder."
        case .invalidRetention: "Retention count must be zero or greater, and age must be at least one day."
        case .entryNotFound: "This dictation is no longer in History."
        case .invalidAudioFile: "The original capture must be a regular local file."
        }
    }
}
