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
