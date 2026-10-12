import Foundation
import GoblinCore
#if canImport(Security)
import Security
#endif

struct CLIProcessingOptions {
    var enabled = false
    var allowRewrite = false
    var tone: DictationTone?
    var dictionaryURL: URL?

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
        tone = options.tone ?? DictationTone(rawValue: defaults.string(forKey: DictationTone.preferenceKey) ?? "") ?? .formal
        rewrite = RewriteSettingsStore.load(defaults: defaults)
        apiKey = ""
        if options.allowRewrite {
            guard rewrite.enabled, rewrite.cleanup != .none else {
                throw RewriteFailure.configuration("Enable and configure AI cleanup in gob.lin Settings before using --rewrite.")
            }
            apiKey = try Self.loadKey(for: rewrite)
        } else { rewrite.enabled = false }
    }

    func process(_ raw: String, using processor: TranscriptPostprocessor) async -> TranscriptProcessingResult {
        await processor.process(raw, dictionaryEntries: entries, tone: tone, rewriteSettings: rewrite, apiKey: apiKey)
    }

    private static func loadKey(for settings: RewriteSettings) throws -> String {
        let endpoint = try settings.endpoint()
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewriteFailure.configuration("Enter a provider model before enabling AI cleanup.")
        }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoblinMetadata.bundleIdentifier + ".rewrite",
            kSecAttrAccount as String: endpoint.absoluteString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw RewriteFailure.configuration("Keychain could not read the cleanup credential. Unlock your Mac and try again.")
        }
        return key
        #else
        throw RewriteFailure.configuration("Cloud rewrite credentials require the macOS Keychain shell.")
        #endif
    }
}
