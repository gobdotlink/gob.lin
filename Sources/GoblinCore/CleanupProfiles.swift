import Foundation

/// How gob.lin writes in one kind of place: the tone, how much cleanup changes, and the instructions it gets. Each app
/// you dictate into uses one profile; Everywhere covers every app that isn't in another.
public struct CleanupProfile: Codable, Equatable, Identifiable, Sendable {
    public static let everywhereID = "everywhere"

    public var id: String
    public var name: String
    /// When to use it, in a line: shown under its name, and what sorting apps reads to choose it.
    public var purpose: String
    public var tone: DictationTone
    public var cleanup: RewriteCleanup
    public var formatting: RewriteFormatting
    /// Instructions edited from gob.lin's own. While set, the level and formatting don't apply.
    public var customPrompt: String?
    /// With a custom prompt, whether the tone's own pass still runs on what cleanup wrote.
    public var tonesCustomPrompt: Bool

    public init(id: String = UUID().uuidString, name: String, purpose: String = "", tone: DictationTone = .formal,
                cleanup: RewriteCleanup = .light, formatting: RewriteFormatting = .init(), customPrompt: String? = nil,
                tonesCustomPrompt: Bool = false) {
        self.id = id; self.name = name; self.purpose = purpose; self.tone = tone; self.cleanup = cleanup
        self.formatting = formatting; self.customPrompt = customPrompt; self.tonesCustomPrompt = tonesCustomPrompt
    }

    public var isEverywhere: Bool { id == Self.everywhereID }

    /// The instructions this profile sends: its custom prompt, or the ones gob.lin writes from its settings.
    public var instructions: String {
        customPrompt ?? RewritePrompt.instructions(cleanup: cleanup, formatting: formatting, tone: tone)
    }

    /// Whether the tone's own pass runs on what cleanup wrote.
    public var formatsTone: Bool { customPrompt == nil || tonesCustomPrompt }

    /// `settings` with this profile's level and formatting, for one take.
    public func applied(to settings: RewriteSettings) -> RewriteSettings {
        var settings = settings
        // ponytail: a custom prompt decides how much to change, so any level that runs cleanup will do; Light is never shown.
        settings.cleanup = customPrompt == nil ? cleanup : .light
        settings.formatting = formatting
        return settings
    }

    /// "Light · Casual", or "Custom prompt · Casual".
    public var summary: String {
        (customPrompt == nil ? cleanup.title : "Custom prompt") + " · " + tone.title
    }

    public static func everywhere(tone: DictationTone = .formal, cleanup: RewriteCleanup = .light, formatting: RewriteFormatting = .init()) -> Self {
        CleanupProfile(id: everywhereID, name: "Everywhere", purpose: "Every app that isn't in another profile.",
                       tone: tone, cleanup: cleanup, formatting: formatting)
    }

    /// The profiles a new install starts with, after Everywhere.
    public static let starters: [CleanupProfile] = [
        CleanupProfile(id: "code", name: "Code", purpose: "Terminals, code editors, AI coding agents, pull requests and issue trackers.",
                       tone: .casual, cleanup: .light, formatting: RewriteFormatting(commands: true)),
        CleanupProfile(id: "chat", name: "Chat", purpose: "Messages, DMs and team chat, like Slack and Discord.",
                       tone: .veryCasual, cleanup: .light),
        CleanupProfile(id: "email", name: "Email & Docs", purpose: "Email, replies and longer writing in documents.",
                       tone: .formal, cleanup: .medium, formatting: RewriteFormatting(paragraphs: true)),
    ]

    /// Apps that belong in a starter profile, by bundle identifier, offered first when adding apps.
    public static let suggestedApps: [String: [String]] = [
        "code": ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.microsoft.VSCode",
                 "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.openai.codex", "com.linear"],
        "chat": ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
                 "org.whispersystems.signal-desktop", "com.microsoft.teams2"],
        "email": ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop", "com.apple.Notes",
                  "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "net.shinyfrog.bear", "md.obsidian"],
    ]
}

/// Where one app's dictations go.
public struct AppPlacement: Codable, Equatable, Sendable {
    public var profile: String
    /// Sorted by gob.lin, not put there by you.
    public var automatic: Bool

    public init(profile: String, automatic: Bool = false) { self.profile = profile; self.automatic = automatic }
}

/// Which decision model sorts new apps into profiles.
public enum ProfileSorter: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, openAI, openRouter, typeSafe, appleIntelligence
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .typeSafe: "TypeSafe Jev"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    /// The name its key is saved under in `RewriteKeyStore`: OpenAI and OpenRouter share cleanup's.
    public var keyAccount: String? {
        switch self {
        case .openAI: RewriteProvider.openAI.rawValue
        case .openRouter: RewriteProvider.openRouter.rawValue
        case .typeSafe: "typeSafe"
        case .automatic, .appleIntelligence: nil
        }
    }

    /// Decision models OpenRouter routes to, by its model ID, the default first.
    // ponytail: a fixed list; OpenRouter's models endpoint can list them (output_modalities=decisions) if this goes stale.
    public static let openRouterModels: [(id: String, title: String)] = [
        ("perplexity/pplx-decider-v1.2", "Perplexity Decider 1.2"),
        ("~perplexity/pplx-decider-latest", "Perplexity Decider, latest"),
        ("~typesafe/jev-latest", "TypeSafe Jev"),
        ("liquid/d1.2", "Liquid D1.2"),
        ("cloudflare/clef-flash", "Cloudflare Clef Flash"),
        ("inception/mercury-decide", "Inception Mercury Decide"),
    ]

    public static func openRouterTitle(_ model: String) -> String { openRouterModels.first { $0.id == model }?.title ?? model }

    /// Automatic picks the cleanup provider when it can sort, then any saved key, then the on-device model.
    public func resolved(cleanup: RewriteProvider, hasKey: (ProfileSorter) -> Bool, onDevice: Bool) -> ProfileSorter? {
        guard self == .automatic else { return self == .appleIntelligence ? (onDevice ? self : nil) : (hasKey(self) ? self : nil) }
        let own: ProfileSorter? = cleanup == .openAI ? .openAI : cleanup == .openRouter ? .openRouter : nil
        if let own, hasKey(own) { return own }
        if let keyed = [ProfileSorter.openAI, .openRouter, .typeSafe].first(where: hasKey) { return keyed }
        return onDevice ? .appleIntelligence : nil
    }
}

/// Every profile, which app goes where, and how new apps are sorted.
public struct CleanupProfiles: Codable, Equatable, Sendable {
    public static let preferenceKey = "cleanupProfiles"

    /// Everywhere first.
    public var profiles: [CleanupProfile]
    /// By bundle identifier.
    public var apps: [String: AppPlacement]
    /// A new app gets a profile from a decision model the first time you dictate into it.
    public var sortsApps: Bool
    /// In a browser, each window's title decides, take by take.
    public var sortsBrowserTabs: Bool
    public var sorter: ProfileSorter
    /// The decision model OpenRouter sorts with; see `ProfileSorter.openRouterModels`.
    public var openRouterModel: String

    public init(profiles: [CleanupProfile] = [.everywhere()] + CleanupProfile.starters, apps: [String: AppPlacement] = [:],
                sortsApps: Bool = false, sortsBrowserTabs: Bool = false, sorter: ProfileSorter = .automatic,
                openRouterModel: String = ProfileSorter.openRouterModels[0].id) {
        self.profiles = profiles; self.apps = apps; self.sortsApps = sortsApps
        self.sortsBrowserTabs = sortsBrowserTabs; self.sorter = sorter; self.openRouterModel = openRouterModel
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(profiles: try fields.decode([CleanupProfile].self, forKey: .profiles),
                  apps: try fields.decodeIfPresent([String: AppPlacement].self, forKey: .apps) ?? [:],
                  sortsApps: try fields.decodeIfPresent(Bool.self, forKey: .sortsApps) ?? false,
                  sortsBrowserTabs: try fields.decodeIfPresent(Bool.self, forKey: .sortsBrowserTabs) ?? false,
                  sorter: try fields.decodeIfPresent(ProfileSorter.self, forKey: .sorter) ?? .automatic,
                  openRouterModel: try fields.decodeIfPresent(String.self, forKey: .openRouterModel) ?? ProfileSorter.openRouterModels[0].id)
    }

    /// Everywhere exists, comes first and appears once; apps point only at profiles that exist.
    private mutating func normalize() {
        let everywhere = profiles.first(where: \.isEverywhere) ?? .everywhere()
        var seen: Set<String> = [CleanupProfile.everywhereID]
        profiles = [everywhere] + profiles.filter { !$0.isEverywhere && seen.insert($0.id).inserted }
        apps = apps.filter { seen.contains($0.value.profile) }
    }

    public var everywhere: CleanupProfile { profiles[0] }

    public func profile(_ id: String) -> CleanupProfile? { profiles.first { $0.id == id } }

    /// The profile an app is in, if it has one. Browsers stay unplaced unless you put them somewhere.
    public func placedProfile(for bundleIdentifier: String?) -> CleanupProfile? {
        bundleIdentifier.flatMap { apps[$0] }.flatMap { profile($0.profile) }
    }

    /// The apps in `profile`, yours first, then sorted.
    public func apps(in profile: String) -> [(id: String, automatic: Bool)] {
        apps.filter { $0.value.profile == profile }.map { ($0.key, $0.value.automatic) }
            .sorted { ($0.automatic ? 1 : 0, $0.id) < ($1.automatic ? 1 : 0, $1.id) }
    }

    public mutating func put(_ profile: CleanupProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        normalize()
    }

    /// Everywhere stays. Its apps go back to being sorted.
    public mutating func remove(_ id: String) {
        guard id != CleanupProfile.everywhereID else { return }
        profiles.removeAll { $0.id == id }
        normalize()
    }

    /// A browser shows many kinds of page, so it is sorted by window title rather than placed once.
    public static func isBrowser(_ bundleIdentifier: String) -> Bool { browsers.contains(bundleIdentifier) }

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "com.openai.atlas", "org.chromium.Chromium",
    ]
}

public enum CleanupProfileStore {
    /// Saved profiles, or the starters with Everywhere set from the level, formatting and tone saved before profiles.
    public static func load(defaults: UserDefaults = .standard) -> CleanupProfiles {
        if let data = defaults.data(forKey: CleanupProfiles.preferenceKey),
           let saved = try? JSONDecoder().decode(CleanupProfiles.self, from: data) { return saved }
        let rewrite = RewriteSettingsStore.load(defaults: defaults)
        let tone = DictationTone(rawValue: defaults.string(forKey: DictationTone.preferenceKey) ?? "") ?? .formal
        return CleanupProfiles(profiles: [.everywhere(tone: tone, cleanup: rewrite.cleanup, formatting: rewrite.formatting)] + CleanupProfile.starters)
    }

    public static func save(_ profiles: CleanupProfiles, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: CleanupProfiles.preferenceKey)
    }

    /// Nothing about cleanup or tone was ever saved: a new install, whose starter profiles may come with their apps.
    public static func isNewInstall(defaults: UserDefaults = .standard) -> Bool {
        [CleanupProfiles.preferenceKey, RewriteSettingsStore.preferenceKey, DictationTone.preferenceKey].allSatisfy { defaults.object(forKey: $0) == nil }
    }
}
