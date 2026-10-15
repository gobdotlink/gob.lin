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
        let keys = keys(defaults), (account, legacy) = try accounts(settings)
        return keys[account] ?? legacy.flatMap { keys[$0] } ?? ""
    }

    /// Saving an empty key removes it. Either way the legacy endpoint entry is dropped.
    public static func save(_ key: String, for settings: RewriteSettings, defaults: UserDefaults = .standard) throws {
        var keys = keys(defaults)
        let (account, legacy) = try accounts(settings)
        keys[account] = key.isEmpty ? nil : key
        if let legacy { keys[legacy] = nil }
        defaults.set(keys, forKey: preferenceKey)
    }

    // Keys used to be stored under the endpoint URL alone.
    private static func accounts(_ settings: RewriteSettings) throws -> (account: String, legacy: String?) {
        guard settings.provider == .custom else { return (settings.provider.rawValue, try? settings.endpoint().absoluteString) }
        let endpoint = try settings.endpoint().absoluteString
        return ("custom " + endpoint, RewriteProvider.matching(baseURL: settings.baseURL) == .custom ? endpoint : nil)
    }

    private static func keys(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
    }
}
