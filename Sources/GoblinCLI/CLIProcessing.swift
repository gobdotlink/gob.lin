import Foundation
import GoblinCore

struct CLIProcessingOptions {
    var enabled = false
    var allowRewrite = false
    var tone: DictationTone?
    var dictionaryURL: URL?
    /// Bundle identifier whose app-scoped terms apply; terms for every app always apply.
    var application: String?
    /// Project name whose project-scoped terms apply.
    var project: String?

    mutating func consume(_ arguments: [String], index: inout Int) throws -> Bool {
        switch arguments[index] {
        case "--process": enabled = true; index += 1
        case "--rewrite": enabled = true; allowRewrite = true; index += 1
        case "--tone":
            guard index + 1 < arguments.count, let value = DictationTone(rawValue: arguments[index + 1]) else {
                throw CommandError.usage("--tone requires formal, casual, or veryCasual")
            }
            enabled = true; tone = value; index += 2
        case "--dictionary":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CommandError.usage("--dictionary requires a JSON dictionary path")
            }
            guard FileManager.default.fileExists(atPath: arguments[index + 1]) else {
                throw CommandError.usage("--dictionary file not found: \(arguments[index + 1])")
            }
            enabled = true; dictionaryURL = URL(fileURLWithPath: arguments[index + 1]); index += 2
        case "--app":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), application == nil else {
                throw CommandError.usage("--app requires one application bundle identifier")
            }
            enabled = true; application = arguments[index + 1]; index += 2
        case "--project":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), project == nil else {
                throw CommandError.usage("--project requires one project name")
            }
            enabled = true; project = arguments[index + 1]; index += 2
        default: return false
        }
        return true
    }
}

struct CLIProcessingConfiguration: Sendable {
    var entries: [DictionaryEntry]
    var tone: DictationTone
    var rewrite: RewriteSettings
    var apiKey: String

    init(options: CLIProcessingOptions) throws {
        let defaults = UserDefaults(suiteName: GoblinMetadata.bundleIdentifier) ?? .standard
        entries = try (options.dictionaryURL.map(DictionaryRepository.init(url:)) ?? .applicationDefault).load()
            .active(in: DictionaryScope(application: options.application, project: options.project))
        tone = options.tone ?? DictationTone(rawValue: defaults.string(forKey: DictationTone.preferenceKey) ?? "") ?? .formal
        rewrite = RewriteSettingsStore.load(defaults: defaults)
        apiKey = ""
        if options.allowRewrite {
            guard rewrite.enabled, rewrite.cleanup != .none else {
                throw RewriteFailure.configuration("Enable and configure AI cleanup in gob.lin Settings before using --rewrite.")
            }
            apiKey = try Self.loadKey(for: rewrite, defaults: defaults)
        } else { rewrite.enabled = false }
    }

    func process(_ raw: String, using processor: TranscriptPostprocessor) async -> TranscriptProcessingResult {
        await processor.process(raw, dictionaryEntries: entries, tone: tone, rewriteSettings: rewrite, apiKey: apiKey)
    }

    private static func loadKey(for settings: RewriteSettings, defaults: UserDefaults) throws -> String {
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewriteFailure.configuration("Enter a provider model before enabling AI cleanup.")
        }
        return try RewriteKeyStore.load(for: settings, defaults: defaults)
    }
}
