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

    /// The name each provider's key is stored under: `load` and `save` use it here, and the iPhone's Keychain uses it.
    public static func account(_ settings: RewriteSettings) throws -> String {
        settings.provider == .custom ? "custom " + (try settings.endpoint().absoluteString) : settings.provider.rawValue
    }

    private static func keys(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
    }
}

/// Why these settings can't run cleanup yet, or nil when they can.
public func cleanupSetupProblem(_ settings: RewriteSettings, hasKey: Bool) -> String? {
    if settings.provider.runsOnDevice { return OnDeviceCleanup.availability.problem }
    let endpoint: URL
    do { endpoint = try settings.endpoint() } catch { return error.localizedDescription }
    if settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a model before turning on AI cleanup." }
    if !hasKey, !isLocalHost(endpoint.host) { return "Add an API key before turning on AI cleanup." }
    return nil
}

public func isLocalHost(_ host: String?) -> Bool { ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host ?? "") }
