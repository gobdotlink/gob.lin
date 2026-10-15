import Foundation

public enum RewriteSettingsStore {
    public static let preferenceKey = "rewriteSettings"

    public static func load(defaults: UserDefaults = .standard) -> RewriteSettings {
        guard let data = defaults.data(forKey: preferenceKey), let settings = try? JSONDecoder().decode(RewriteSettings.self, from: data) else {
            var settings = RewriteSettings()
            settings.provider = .cerebras
            settings.configuration = RewriteProvider.cerebras.configuration
            return settings
        }
        return settings
    }

    public static func save(_ settings: RewriteSettings, defaults: UserDefaults = .standard) throws {
        _ = try settings.extraRequestParameters()
        defaults.set(try JSONEncoder().encode(settings), forKey: preferenceKey)
    }
}

// ponytail: provider keys sit unencrypted in preferences as a compromise until builds are signed with an
// Apple Development certificate. The local certificate has no Team ID, so the login keychain asks for the
// account password after every rebuild or update. Move keys back to Keychain once that certificate exists.
public enum RewriteKeyStore {
    public static let preferenceKey = "rewriteAPIKeys"

    /// Named providers keep one key across address edits. Custom is scoped to its endpoint, so it never
    /// picks up a named provider's key or another custom server's.
    public static func load(for settings: RewriteSettings, defaults: UserDefaults = .standard) throws -> String {
        keys(defaults)[try account(settings)] ?? ""
    }

    /// Saving an empty key removes it.
    public static func save(_ key: String, for settings: RewriteSettings, defaults: UserDefaults = .standard) throws {
        var keys = keys(defaults)
        keys[try account(settings)] = key.isEmpty ? nil : key
        defaults.set(keys, forKey: preferenceKey)
    }

    private static func account(_ settings: RewriteSettings) throws -> String {
        settings.provider == .custom ? "custom " + (try settings.endpoint().absoluteString) : settings.provider.rawValue
    }

    private static func keys(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
    }
}
