import AppKit
import GoblinCore

/// The profile one take is written with, and the app it was chosen for.
struct ProfileRoute: Equatable {
    var profile: CleanupProfile
    var bundleIdentifier: String?
    var processID: pid_t?
    /// The app's own placement chose it, not a guess.
    var placed = false
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
    /// By bundle identifier, or bundle identifier and window title for a browser tab, each with what it was made among
    /// (see `among`): a guess counts only while that's unchanged.
    private var guesses: [String: (among: [String], guess: ProfileGuess)] = [:]
    private var guessing: [String: (among: [String], task: Task<ProfileGuess?, Never>)] = [:]
    /// Takes into an app no guess could place.
    private var unplacedTakes: [String: Int] = [:]
    /// Apps already asked about this launch. Not Now, or letting the question go, waits for the next launch.
    private var asked: Set<String> = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    var profiles: CleanupProfiles { CleanupProfileStore.load(defaults: defaults) }

    /// The profile an app uses without asking a model: its placement, a guess already made while sorting is on, or
    /// Everywhere.
    func knownProfile(for bundleIdentifier: String?) -> CleanupProfile {
        let profiles = profiles
        if let placed = profiles.placedProfile(for: bundleIdentifier) { return placed }
        if profiles.sortsApps, let bundleIdentifier, let made = guesses[bundleIdentifier], made.among == Self.among(profiles),
           made.guess.certainty != .lost, let profile = profiles.profile(made.guess.profile) {
            return profile
        }
        return profiles.everywhere
    }

    /// `route` as the profiles stand now, for a take whose route was chosen a while ago: a placement made since wins, the
    /// profile is read again so edits apply, and a guess gives way to Everywhere once sorting is off or its profile is gone.
    func current(_ route: ProfileRoute) -> ProfileRoute {
        var route = route
        let profiles = profiles
        if let placed = profiles.placedProfile(for: route.bundleIdentifier) {
            route.profile = placed
            route.placed = true
            route.question = nil
        } else if route.placed || route.profile.isEverywhere || !profiles.sortsApps {
            // A placement taken away mid-take leaves the app in Everywhere, like any unplaced app's take.
            route.profile = profiles.everywhere
            if route.placed || !profiles.sortsApps { route.question = nil }
            route.placed = false
        } else if let profile = profiles.profile(route.profile.id) {
            route.profile = profile
        } else {
            // The guessed profile was deleted: Everywhere, and no question naming it.
            route.profile = profiles.everywhere
            route.question = nil
        }
        return route
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
        func routed(_ profile: CleanupProfile, placed: Bool = false, question: ProfileQuestion? = nil) -> ProfileRoute {
            ProfileRoute(profile: profile, bundleIdentifier: bundleID, processID: pid, placed: placed, question: question)
        }
        guard let app, let bundle = app.bundleIdentifier, app.processIdentifier != getpid() else {
            return Task { ProfileRoute(profile: profiles.everywhere) }
        }
        // A placement is your own choice, password manager or not, so it applies from key-down to the end of the take.
        if let placed = profiles.placedProfile(for: bundle) { return Task { routed(placed, placed: true) } }
        // A password manager's name is all a decision model would get, and it isn't sent.
        if AppInsertionQuirks.forBundle(bundle, at: app.bundleURL).credentialManager { return Task { routed(profiles.everywhere) } }
        let name = app.localizedName ?? DictionaryApps.name(bundle)
        guard profiles.sortsApps, profiles.profiles.count > 1, let (sorter, key) = sorter(profiles) else {
            return Task { routed(profiles.everywhere) }
        }
        if CleanupProfiles.isBrowser(bundle) {
            guard profiles.sortsBrowserTabs else { return Task { routed(profiles.everywhere) } }
            return Task { [weak self] in
                let title = await Task.detached { pid.flatMap(FocusedText.windowTitle(pid:)) }.value
                guard let self, let title else { return routed(profiles.everywhere) }
                // Reading the title takes a moment: the title goes out only if tab sorting is still on, to the sorter
                // chosen now.
                let now = self.profiles
                if let placed = now.placedProfile(for: bundle) { return routed(placed, placed: true) }
                guard now.sortsApps, now.sortsBrowserTabs, let (sorter, key) = self.sorter(now) else { return routed(now.everywhere) }
                let guess = await self.guess(bundle + "\n" + title, application: name, bundle: bundle, title: title,
                                             profiles: now, sorter: sorter, key: key)
                // Placed by hand, or sorting turned off, while the model thought: that wins.
                let current = self.profiles
                if let placed = current.placedProfile(for: bundle) { return routed(placed, placed: true) }
                // A tab is never saved or asked about: the next one may be a different kind of page.
                guard current.sortsApps, current.sortsBrowserTabs, let guess, guess.certainty != .lost,
                      let profile = current.profile(guess.profile) else { return routed(current.everywhere) }
                return routed(profile)
            }
        }
        return Task { [weak self] in
            guard let self else { return routed(profiles.everywhere) }
            let guess = await self.guess(bundle, application: name, bundle: bundle, title: nil, profiles: profiles, sorter: sorter, key: key)
            // Placed by hand, or sorting turned off, while the model thought: that wins.
            let current = self.profiles
            if let placed = current.placedProfile(for: bundle) { return routed(placed, placed: true) }
            guard current.sortsApps else { return routed(current.everywhere) }
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

    /// Marks the question asked, so it isn't again this launch. False when it already was, by an overlapping take.
    func didAsk(_ question: ProfileQuestion) -> Bool { asked.insert(question.bundleIdentifier).inserted }

    /// Puts an app in a profile. Yours unless `automatic`.
    func place(_ bundle: String, in profile: String, automatic: Bool = false) {
        var profiles = profiles
        profiles.apps[bundle] = AppPlacement(profile: profile, automatic: automatic)
        try? CleanupProfileStore.save(profiles, defaults: defaults)
        unplacedTakes[bundle] = nil
    }

    /// What a guess depends on besides the app: the sorter, its model, and every profile's name and purpose.
    private static func among(_ profiles: CleanupProfiles) -> [String] {
        [profiles.sorter.rawValue, profiles.openRouterModel] + profiles.profiles.map { $0.id + "\u{1F}" + $0.name + "\u{1F}" + $0.purpose }
    }

    private func guess(_ cacheKey: String, application: String, bundle: String, title: String?, profiles: CleanupProfiles,
                       sorter: ProfileSorter, key: String) async -> ProfileGuess? {
        let among = Self.among(profiles)
        if let made = guesses[cacheKey], made.among == among { return made.guess }
        if let pending = guessing[cacheKey], pending.among == among { return await pending.task.value }
        let decisions = decisions, options = profiles.profiles, model = profiles.openRouterModel
        let task = Task { await decisions.guess(application: application, bundleIdentifier: bundle, windowTitle: title,
                                                profiles: options, sorter: sorter, model: model, apiKey: key) }
        guessing[cacheKey] = (among, task)
        let result = await task.value
        if guessing[cacheKey]?.among == among { guessing[cacheKey] = nil }
        // ponytail: browser titles pile up for the launch; a few hundred short strings at most.
        // Profiles or the sorter changed while the model thought: the guess is stale, so it's neither kept nor used.
        guard Self.among(self.profiles) == among else { return nil }
        if let result { guesses[cacheKey] = (among, result) }
        return result
    }
}
