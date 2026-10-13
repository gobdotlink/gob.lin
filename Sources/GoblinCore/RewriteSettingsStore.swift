import Foundation

public enum RewriteSettingsStore {
    public static let preferenceKey = "rewriteSettings"

    public static func load(defaults: UserDefaults = .standard) -> RewriteSettings {
        guard let data = defaults.data(forKey: preferenceKey), let settings = try? JSONDecoder().decode(RewriteSettings.self, from: data) else {
            return RewriteSettings()
        }
        return settings
    }

    public static func save(_ settings: RewriteSettings, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: preferenceKey)
    }
}
