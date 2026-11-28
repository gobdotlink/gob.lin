import AppKit
import GoblinCore

/// The profile one take is written with, and the app it was chosen for.
struct ProfileRoute: Equatable {
    var profile: CleanupProfile
    var bundleIdentifier: String?
    var processID: pid_t?
    /// Asked once the text lands, only if it lands in this app.
    var question: ProfileQuestion?
}

/// Puts each take in a profile: the app's own placement, then a decision model's guess for an app seen for the first
/// time or a browser tab, then Everywhere. Guesses are remembered for the launch, so a draft cleanup and the final one
/// share one request, and a sure guess is saved so the app is never asked about again.
@MainActor
final class ProfileRouter {
    private let defaults: UserDefaults
    private let decisions = ProfileDecisionClient()
    /// By bundle identifier, or bundle identifier and window title for a browser tab.
    private var guesses: [String: ProfileGuess] = [:]
    private var guessing: [String: Task<ProfileGuess?, Never>] = [:]
    /// The profiles the guesses were made among; editing them makes every guess stale.
    private var guessedAmong: [String] = []
    /// Takes into an app no guess could place.
    private var unplacedTakes: [String: Int] = [:]
    /// Apps already asked about this launch. Not Now, or letting the question go, waits for the next launch.
    private var asked: Set<String> = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    var profiles: CleanupProfiles { CleanupProfileStore.load(defaults: defaults) }

    /// The profile an app uses without asking a model: its placement, a sure guess already made, or Everywhere.
    func knownProfile(for bundleIdentifier: String?) -> CleanupProfile {
        let profiles = profiles
        if let placed = profiles.placedProfile(for: bundleIdentifier) { return placed }
        if let bundleIdentifier, let guess = guesses[bundleIdentifier], guess.certainty != .lost, let profile = profiles.profile(guess.profile) {
            return profile
        }
        return profiles.everywhere
    }

    /// The decision model sorting would use and its key, or nil when there's none to ask.
    func sorter(_ profiles: CleanupProfiles) -> (sorter: ProfileSorter, key: String)? {
        let cleanup = RewriteSettingsStore.load(defaults: defaults).provider
        guard let sorter = profiles.sorter.resolved(cleanup: cleanup, hasKey: { !key(for: $0).isEmpty },
                                                    onDevice: OnDeviceCleanup.availability == .available) else { return nil }
        return (sorter, key(for: sorter))
    }

    private func key(for sorter: ProfileSorter) -> String {
        sorter.keyAccount.map { RewriteKeyStore.load(account: $0, defaults: defaults) } ?? ""
    }

    /// Starts at key-down, while the user speaks. A placed app is settled at once.
    func route(_ app: NSRunningApplication?) -> Task<ProfileRoute, Never> {
        let profiles = profiles
        let pid = app?.processIdentifier, bundleID = app?.bundleIdentifier
        func routed(_ profile: CleanupProfile, question: ProfileQuestion? = nil) -> ProfileRoute {
            ProfileRoute(profile: profile, bundleIdentifier: bundleID, processID: pid, question: question)
        }
        guard let app, let bundle = app.bundleIdentifier, app.processIdentifier != getpid() else {
            return Task { ProfileRoute(profile: profiles.everywhere) }
        }
        if let placed = profiles.placedProfile(for: bundle) { return Task { routed(placed) } }
        let name = app.localizedName ?? DictionaryApps.name(bundle)
        guard profiles.sortsApps, profiles.profiles.count > 1, let (sorter, key) = sorter(profiles) else {
            return Task { routed(profiles.everywhere) }
        }
        forgetStaleGuesses(profiles)
        if CleanupProfiles.isBrowser(bundle) {
            guard profiles.sortsBrowserTabs else { return Task { routed(profiles.everywhere) } }
            return Task { [weak self] in
                let title = await Task.detached { pid.flatMap(FocusedText.windowTitle(pid:)) }.value
                guard let self, let title else { return routed(profiles.everywhere) }
                let guess = await self.guess(bundle + "\n" + title, application: name, bundle: bundle, title: title,
                                             profiles: profiles, sorter: sorter, key: key)
                // A tab is never saved or asked about: the next one may be a different kind of page.
                guard let guess, guess.certainty != .lost, let profile = profiles.profile(guess.profile) else { return routed(profiles.everywhere) }
                return routed(profile)
            }
        }
        return Task { [weak self] in
            guard let self else { return routed(profiles.everywhere) }
            let guess = await self.guess(bundle, application: name, bundle: bundle, title: nil, profiles: profiles, sorter: sorter, key: key)
            // Placed by hand while the model thought: that wins.
            let current = self.profiles
            if let placed = current.placedProfile(for: bundle) { return routed(placed) }
            let choices = current.profiles.map { ProfileQuestion.Choice(id: $0.id, name: $0.name) }
            let ask = !self.asked.contains(bundle)
            switch (guess?.certainty, guess.flatMap { current.profile($0.profile) }) {
            case (.sure, let profile?):
                self.place(bundle, in: profile.id, automatic: true)
                return routed(profile)
            // An unsure Everywhere is no placement at all: asking to keep it there would only nag.
            case (.unsure, let profile?) where !profile.isEverywhere:
                let question = ask ? ProfileQuestion(bundleIdentifier: bundle, application: name,
                                                     guess: .init(id: profile.id, name: profile.name), choices: choices) : nil
                return routed(profile, question: question)
            case (nil, _):
                // Offline, timed out or refused: nothing learned, so nothing to ask.
                return routed(current.everywhere)
            default:
                self.unplacedTakes[bundle, default: 0] += 1
                // ponytail: asks on the second unplaced take, so an app used once never nags.
                let question = ask && self.unplacedTakes[bundle, default: 0] >= 2
                    ? ProfileQuestion(bundleIdentifier: bundle, application: name, guess: nil, choices: choices) : nil
                return routed(current.everywhere, question: question)
            }
        }
    }

    /// The question is on screen: it isn't asked again this launch.
    func didAsk(_ question: ProfileQuestion) { asked.insert(question.bundleIdentifier) }

    /// Puts an app in a profile. Yours unless `automatic`.
    func place(_ bundle: String, in profile: String, automatic: Bool = false) {
        var profiles = profiles
        profiles.apps[bundle] = AppPlacement(profile: profile, automatic: automatic)
        try? CleanupProfileStore.save(profiles, defaults: defaults)
        unplacedTakes[bundle] = nil
    }

    private func forgetStaleGuesses(_ profiles: CleanupProfiles) {
        let among = [profiles.openRouterModel] + profiles.profiles.map { $0.id + "\u{1F}" + $0.name + "\u{1F}" + $0.purpose }
        guard among != guessedAmong else { return }
        guessedAmong = among
        guesses.removeAll()
    }

    private func guess(_ cacheKey: String, application: String, bundle: String, title: String?, profiles: CleanupProfiles,
                       sorter: ProfileSorter, key: String) async -> ProfileGuess? {
        if let known = guesses[cacheKey] { return known }
        if let pending = guessing[cacheKey] { return await pending.value }
        let decisions = decisions, options = profiles.profiles, model = profiles.openRouterModel
        let task = Task { await decisions.guess(application: application, bundleIdentifier: bundle, windowTitle: title,
                                                profiles: options, sorter: sorter, model: model, apiKey: key) }
        guessing[cacheKey] = task
        let result = await task.value
        guessing[cacheKey] = nil
        // ponytail: browser titles pile up for the launch; a few hundred short strings at most.
        if let result { guesses[cacheKey] = result }
        return result
    }
}
