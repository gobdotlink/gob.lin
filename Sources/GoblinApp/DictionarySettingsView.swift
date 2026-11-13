import GoblinCore
import GoblinEngines
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DictionaryModel: ObservableObject {
    static let suggestsTermsKey = "dictionary.suggestsTerms"
    static let dismissedSuggestionsKey = "dictionary.dismissedSuggestions"
    static let syncsWithICloudKey = "sync.iCloud"
    /// Most fixed words remembered: those of the 500 latest edited dictations, about two each.
    static let fixLimit = 1_000

    @Published private(set) var entries: [DictionaryEntry] = [] { didSet { reviewSuggestions() } }
    @Published var error: String?
    @Published private(set) var lastFailure: DiagnosticFailure?
    /// The app and detected project of the most recent dictation, shown so users can check project detection. `bundleIdentifier`
    /// is the app's dictionary scope: "" is gob.lin itself.
    @Published var lastContext: (application: String?, bundleIdentifier: String?, project: DetectedProject?)?
    /// Terms worth adding for the places you dictate into, best first. Nothing is added until the user accepts one.
    @Published private(set) var suggestions: [TermSuggestion] = []
    /// Whether gob.lin reads the project you dictate into and your fixes for suggestions; on by default.
    @Published var suggestsTerms: Bool {
        didSet {
            defaults.set(suggestsTerms, forKey: Self.suggestsTermsKey)
            if suggestsTerms, !fixesLoaded { Task { await refreshFixes() } }
            reviewSuggestions()
        }
    }
    /// Whether gob.lin syncs through the person's iCloud, set on the General page; off by default. The dictionary is the
    /// only thing that syncs so far.
    @Published var syncsWithICloud: Bool {
        didSet { defaults.set(syncsWithICloud, forKey: Self.syncsWithICloudKey); sync() }
    }
    /// Why the last sync failed, in words for the General page.
    @Published private(set) var syncError: String?
    /// Only a build signed for iCloud can reach it; development builds can't, and never touch iCloud.
    let canSync = SecTaskCreateFromSelf(nil).flatMap {
        SecTaskCopyValueForEntitlement($0, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil)
    } != nil
    private let defaults: UserDefaults
    private var dismissed: Set<String>
    /// One candidate per word fixed after a dictation, newest first: History's, then this session's.
    private var correctionCandidates: [TermSuggestion] = []
    private var fixesLoaded = false
    /// The spell checker's answers, since review asks about every remembered fix each time.
    private var knownWords: [String: Bool] = [:]
    /// The dictations History has seen edited, newest first; nil when History can't be read.
    var loadFixes: (@MainActor () async -> [HistoryEntry]?)?
    private var repositoryCandidates: [TermSuggestion] = []
    private var repositoryCache: [String: (read: Date, candidates: [TermSuggestion])] = [:]
    private var repositoryTask: Task<Void, Never>?

    /// Project names to suggest: T3 Code, Paseo and Codex projects and Slack workspaces on this Mac, the last detected
    /// project and existing scopes.
    func knownProjects() async -> [String] {
        var seen: Set<String> = []
        let stored = await Task.detached(priority: .userInitiated) {
            ProjectResolution.t3ProjectTitles() + ProjectResolution.paseoProjectNames() + ProjectResolution.codexProjectNames()
                + ProjectResolution.slackWorkspaceNames()
        }.value
        let candidates = [lastContext?.project?.name].compactMap { $0 } + entries.flatMap(\.projects) + stored
        return candidates.filter { seen.insert(DictionaryScope.projectKey($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private let repository: DictionaryRepository
    private(set) var available = false

    init(repository: DictionaryRepository = .applicationDefault, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        suggestsTerms = defaults.object(forKey: Self.suggestsTermsKey) as? Bool ?? true
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedSuggestionsKey) ?? [])
        syncsWithICloud = defaults.bool(forKey: Self.syncsWithICloudKey)
        do { entries = try repository.load(); available = true }
        catch { lastFailure = .dictionaryUnavailable; self.error = "Could not load your dictionary: \(error.localizedDescription)" }
        guard canSync else { return }
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        sync()
    }

    // MARK: iCloud

    /// Merges this Mac's dictionary with the copy in iCloud and writes back whatever iCloud is missing.
    // ponytail: iCloud refuses a copy over 1 MB without telling this code; watch for
    // NSUbiquitousKeyValueStoreQuotaViolationChange if dictionaries reach thousands of entries.
    private func sync() {
        guard syncsWithICloud, canSync, available else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        var synced = entries
        // Also after a failure: the merged entries may be saved even when the sync state then isn't.
        defer { if synced != entries { entries = synced } }
        do {
            if let push = try repository.syncRound(&synced, remote: cloud.data(forKey: SyncedDictionary.cloudKey)) {
                cloud.set(push, forKey: SyncedDictionary.cloudKey)
            }
            syncError = nil
        } catch { syncError = error.localizedDescription }
    }

    /// Where each project has been dictated into, from History, so its words can be listed under those apps.
    @Published private(set) var projectUses: [DictionaryProjectUse] = []
    var loadProjectUses: (@MainActor () async -> [DictionaryProjectUse])?

    func refreshProjectUses() async {
        if let uses = await loadProjectUses?() { projectUses = uses }
    }

    /// The places the Dictionary page lists, including the last dictation's.
    var places: DictionaryPlaces {
        let current = lastContext.map { DictionaryScope(application: $0.bundleIdentifier, project: $0.project?.name) }
        return DictionaryPlaces(entries: entries, uses: projectUses, current: current)
    }

    // MARK: Suggestions

    /// Reads the fixes from History, so repeated fixes add up across launches and deleting a dictation forgets its fix.
    func refreshFixes() async {
        guard suggestsTerms, let edited = await loadFixes?() ?? nil else { return }
        // Diffing hundreds of long dictations stays off the main actor.
        let found = await Task.detached(priority: .utility) {
            edited.flatMap { entry in
                entry.editedText.map { TermSuggestions.fromCorrection(dictated: entry.finalText, edited: $0, scope: entry.dictionaryContext) } ?? []
            }
        }.value
        fixesLoaded = true
        correctionCandidates = found
        reviewSuggestions()
    }

    /// Reads the project's folder in the background, at most every 10 minutes per folder, for names to suggest.
    func offerTerms(from project: DetectedProject) {
        guard suggestsTerms, let root = project.root else { return }
        let key = project.name + "\n" + root.standardizedFileURL.path
        if let cached = repositoryCache[key], cached.read.timeIntervalSinceNow > -600 {
            repositoryCandidates = cached.candidates
            reviewSuggestions()
            return
        }
        repositoryTask?.cancel()
        repositoryTask = Task { [weak self] in
            let name = project.name
            let found = await Task.detached(priority: .utility) { TermSuggestions.fromRepository(root: root, project: name) }.value
            guard let self, !Task.isCancelled else { return }
            repositoryCache[key] = (Date(), found)
            repositoryCandidates = found
            reviewSuggestions()
        }
    }

    /// Offers the terms the user fixed after a dictation into `scope`, and returns the ones that survived review, so the
    /// overlay can offer them on the spot.
    @discardableResult
    func offerCorrection(dictated: String, edited: String, scope: DictionaryScope) -> [TermSuggestion] {
        guard suggestsTerms else { return [] }
        // History couldn't be read at launch; it holds this edit too by now.
        if !fixesLoaded { Task { await refreshFixes() } }
        let found = TermSuggestions.fromCorrection(dictated: dictated, edited: edited, scope: scope)
        guard !found.isEmpty else { return [] }
        correctionCandidates = Array((found + correctionCandidates).prefix(Self.fixLimit))
        reviewSuggestions()
        // Review may swap in an existing entry's spelling or widen the place, so match on the spelling alone.
        return suggestions.filter { suggestion in
            found.contains { $0.spelling.caseInsensitiveCompare(suggestion.spelling) == .orderedSame }
        }
    }

    func accept(_ suggestion: TermSuggestion) { _ = persist(entries.accepting(suggestion)) }

    func acceptAll() { _ = persist(suggestions.reduce(entries) { $0.accepting($1) }) }

    func dismiss(_ suggestion: TermSuggestion) {
        dismissed.insert(suggestion.id)
        defaults.set(dismissed.sorted(), forKey: Self.dismissedSuggestionsKey)
        reviewSuggestions()
    }

    /// The project or app every suggestion is for, when they share one: "gob.lin" or "Slack".
    var suggestionPlace: (name: String, isProject: Bool, scope: DictionaryScope)? {
        guard let first = suggestions.first, !first.isEverywhere, suggestions.allSatisfy({ $0.place == first.place }) else { return nil }
        if let project = first.projects.first { return (project.split(separator: "/").last.map(String.init) ?? project, true, first.place) }
        return first.apps.first.map { (DictionaryApps.name($0), false, first.place) }
    }

    private func reviewSuggestions() {
        // Before init finishes loading, and while the file can't be read, there is nothing to compare against.
        guard suggestsTerms, available else { if !suggestions.isEmpty { suggestions = [] }; return }
        let next = TermSuggestions.review(correctionCandidates + repositoryCandidates, entries: entries, dismissed: dismissed) { word in
            if let known = knownWords[word] { return known }
            let known = TermSuggestions.isKnownEnglishWord(word)
            knownWords[word] = known
            return known
        }
        if next != suggestions { suggestions = next }
    }

    func put(_ entry: DictionaryEntry) -> Bool {
        var next = entries.filter { $0.id != entry.id }
        next.append(entry)
        return persist(next)
    }

    func delete(_ entry: DictionaryEntry) { _ = persist(entries.filter { $0.id != entry.id }) }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { _ = persist(try DictionaryRepository.importing(String(contentsOf: url, encoding: .utf8), into: entries)) }
        catch { lastFailure = .dictionaryUnavailable; self.error = "Could not import the word list: \(error.localizedDescription)" }
    }

    private func persist(_ next: [DictionaryEntry]) -> Bool {
        guard available else {
            lastFailure = .dictionaryUnavailable
            error = "Your dictionary could not be loaded. Fix the file before saving to avoid losing existing entries."
            return false
        }
        do { try repository.save(next); entries = try DictionaryRepository.validated(next); error = nil; lastFailure = nil }
        catch { lastFailure = .dictionaryUnavailable; self.error = error.localizedDescription; return false }
        sync()
        return true
    }
}

struct DictionarySettingsView: View {
    @ObservedObject var model: DictionaryModel
    @ObservedObject var service: SpeechModelService
    @AppStorage private var rewriteData: Data
    @State private var editing: DictionaryEntry?
    @State private var importing = false
    @State private var preview: (request: PreviewRequest, usage: SpeechDictionaryUsage)?
    @State private var previewError: (request: PreviewRequest, message: String)?
    private let place: DictionaryPlace

    init(model: DictionaryModel, service: SpeechModelService, defaults: UserDefaults = .standard, place: DictionaryPlace = .everywhere) {
        self.model = model; self.service = service; self.place = place
        _rewriteData = AppStorage(wrappedValue: Data(), RewriteSettingsStore.preferenceKey, store: defaults)
    }

    private struct PreviewRequest: Hashable {
        let modelID: String
        let directory: URL
        let terms: [String]
        let installed: Bool
    }

    private var request: PreviewRequest {
        // App-scoped terms vary by app, so the preview covers the terms used everywhere.
        PreviewRequest(modelID: service.selectedModel.id, directory: service.directory, terms: model.entries.active(in: nil).map(\.spelling),
                       installed: PinnedSpeechModelStore.isDownloaded(model: service.selectedModel, directory: service.directory))
    }
    private var cleanupEnabled: Bool {
        guard let settings = try? JSONDecoder().decode(RewriteSettings.self, from: rewriteData) else { return false }
        return settings.enabled && settings.cleanup != .none
    }

    private static func describe(_ source: DetectedProject.Source) -> String {
        switch source {
        case .repository: "from the open file's repository"
        case .t3Database, .t3Interface: "from the T3 Code thread"
        case .paseoWorkspaces: "from the Paseo workspace"
        case .paseoInterface: "from Paseo's sidebar, best effort"
        case .slackWindow: "from the Slack workspace"
        case .codexDatabase: "from the Codex thread"
        case .claudeSession: "from the Claude Code session"
        }
    }

    var body: some View {
        let current = request
        let usage = preview?.request == current ? preview?.usage : nil
        let scoped = model.entries.contains(where: \.isScoped)
        if model.suggestsTerms, !model.suggestions.isEmpty {
            Section { DictionarySuggestionsCard(model: model) }.containerValue(\.plateless, true)
        }
        Section {
            DictionaryBrowser(model: model, excluded: Set(usage?.excluded ?? []), editing: $editing, importing: $importing, place: place)
        }
        .containerValue(\.plateless, true)
        Section {
            Toggle(isOn: $model.suggestsTerms) {
                Text("Suggest words")
                Text("From project names and your fixes. Nothing is added without a click.").rowDetail()
            }
            if model.entries.contains(where: { !$0.projects.isEmpty }) {
                if let context = model.lastContext {
                    StatusRow(context.project == nil ? .off : .ready,
                              Text(context.project.map { "Last dictation: \(context.application ?? "unknown app") · project \($0.name) (\(Self.describe($0.source)))." }
                                   ?? "Last dictation: \(context.application ?? "unknown app") · I couldn't tell which project was open."))
                } else {
                    StatusRow(.waiting, Text("After your next dictation I'll show which project I detected."))
                }
            }
            if !model.available {
                StatusRow(.problem, Text("I couldn't load your dictionary."))
            } else if !service.selectedModel.capabilities.customVocabulary {
                StatusRow(.off, Text("\(service.selectedModel.name) doesn't support a native dictionary. I don't send terms during recognition."))
            } else if current.terms.isEmpty {
                StatusRow(.ready, Text("\(service.selectedModel.name) supports a native dictionary. I'll send the terms you add automatically."))
            } else if let usage {
                StatusRow(usage.excluded.isEmpty ? .ready : .waiting,
                          Text("I send \(usage.included.count) of \(current.terms.count) terms\(scoped ? " used in every app" : "") to \(service.selectedModel.name).")
                            .monospacedDigit()) {
                    Text("\(usage.tokenCount)/\(usage.tokenLimit) tokens").monospacedDigit()
                }
            } else if !current.installed {
                StatusRow(.waiting, Text("Prepare \(service.selectedModel.name) in Model settings so I can check which terms fit."))
            } else if let error = previewError, error.request == current {
                StatusRow(.problem, Text("I couldn't check the dictionary limit: \(error.message)"))
            } else {
                StatusRow(.waiting, Text("I'm checking which terms fit…"))
            }
        } header: { Text("How I use them") } footer: {
            // The facts that used to be three read-only rows.
            Text("I swap exact “sounds like” matches after recognition, with every model.")
            if service.selectedModel.capabilities.customVocabulary {
                Text("\(service.selectedModel.name) also takes spelling hints as it listens: project and app terms first, then the newest.")
            }
            Text(cleanupEnabled ? "Cleanup is on, so its prompt gets the spellings for the app and project you're in."
                                : "Cleanup is off, so your dictionary isn't sent to a rewrite model.")
            if model.available, scoped, service.selectedModel.capabilities.customVocabulary {
                Text("App terms join in when you dictate into their app and share the limit. Project terms apply after recognition.")
            }
        }
        .task(id: current) {
            guard model.available, service.selectedModel.capabilities.customVocabulary, current.installed, !current.terms.isEmpty else { return }
            do {
                let result = try await WhisperSpeechEngine.dictionaryUsage(terms: current.terms, model: service.selectedModel, directory: current.directory)
                try Task.checkCancellation()
                preview = (current, result)
            } catch {
                guard !Task.isCancelled else { return }
                previewError = (current, error.localizedDescription)
            }
        }
        .sheet(item: $editing) { entry in DictionaryEntryEditor(entry: entry, model: model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            switch result {
            case .success(let url): model.importFile(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("Dictionary", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// The goblin's finds for the places you dictate into, above the term list.
private struct DictionarySuggestionsCard: View {
    @ObservedObject var model: DictionaryModel

    private var title: String {
        guard let place = model.suggestionPlace else { return "I found some words for your dictionary" }
        return place.isProject ? "I found some words in \(place.name)" : "I found some words for \(place.name)"
    }

    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.row.weight(.semibold))
                        if let place = model.suggestionPlace {
                            let used = model.entries.active(in: place.scope).count
                            Text("\(used) of \(DictionaryScope.activeLimit) words for \(place.name)").font(.meta)
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 12)
                    if model.suggestions.count > 1 { Button("Add All") { model.acceptAll() } }
                }
                .padding(.bottom, 6)
                ForEach(model.suggestions) { suggestion in
                    Hairline()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.spelling)
                            Text(caption(suggestion)).font(.meta).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 12)
                        Button("Not Now") { model.dismiss(suggestion) }.accessibilityLabel("Not now, \(suggestion.spelling)")
                        Button("Add") { model.accept(suggestion) }.prominent().accessibilityLabel("Add \(suggestion.spelling)")
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            PeekingGoblin(sprite: .look, scale: 1).alignmentGuide(.top) { $0[.bottom] }.padding(.trailing, 40)
        }
        .padding(.top, 60)
    }

    private func caption(_ suggestion: TermSuggestion) -> String {
        let existing = model.entries.first { $0.spelling.caseInsensitiveCompare(suggestion.spelling) == .orderedSame }
        let reason: String
        switch suggestion.reason {
        case .correction(let heard):
            reason = suggestion.timesFixed > 1 ? "you fixed it \(suggestion.timesFixed) times" : "you fixed “\(heard)”"
        case .projectName: reason = "the project's name"
        case .manifest(let file): reason = "from \(file)"
        case .author: reason = "a contributor"
        case .folder: reason = "a folder in the project"
        case .everywhere:
            if let existing, existing.projects.count >= 2, existing.apps.isEmpty { return "you use it in \(existing.projects.count) projects — use it everywhere?" }
            if let existing, existing.apps.count >= 2, existing.projects.isEmpty { return "you use it in \(existing.apps.count) apps — use it everywhere?" }
            return "you use it in more than one place — use it everywhere?"
        }
        var parts = [reason]
        if !suggestion.aliases.isEmpty {
            let heard = suggestion.aliases.map { "“\($0)”" }.joined(separator: ", ")
            // Accepting keeps the entry's own context, which then limits the new aliases too.
            let near = suggestion.context.isEmpty ? existing?.context ?? [] : suggestion.context
            parts.append("sounds like \(heard)" + (near.isEmpty ? "" : " near \(near.joined(separator: ", "))"))
        }
        if model.suggestionPlace == nil {
            parts.append(suggestion.projects.first.map { "project \($0)" } ?? DictionaryApps.summary(suggestion.apps))
        }
        if let existing, existing.isScoped {
            let places = existing.projects + existing.apps.map(DictionaryApps.name)
            parts.append("already in " + places.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

struct DictionaryEntryEditor: View {
    let entry: DictionaryEntry
    @ObservedObject var model: DictionaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var spelling: String
    @State private var aliases: String
    @State private var context: String
    @State private var apps: [String]
    @State private var projects: [String]
    @State private var suggestions: [String] = []
    @State private var error: String?

    init(entry: DictionaryEntry, model: DictionaryModel) {
        self.entry = entry
        self.model = model
        _spelling = State(initialValue: entry.spelling)
        _aliases = State(initialValue: entry.aliases.joined(separator: "\n"))
        _context = State(initialValue: entry.context.joined(separator: "\n"))
        _apps = State(initialValue: entry.apps)
        _projects = State(initialValue: entry.projects)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(entry.spelling.isEmpty ? "Add term" : "Edit term") {
                    TextField("Preferred spelling", text: $spelling)
                }
                Section {
                    TextEditor(text: $aliases).font(.row.monospaced()).frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Sounds like aliases")
                } header: { Text("Sounds like — one alias per line") } footer: {
                    Text("For example, “day review” → “Dev review”. Aliases match whole words without crossing punctuation.")
                }
                Section {
                    TextEditor(text: $context).font(.row.monospaced()).frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Only near these words")
                } header: { Text("Only near — one word per line") } footer: {
                    Text("Aliases then replace only within three words of one of these, so “soul” becomes “Sol” near “GPT” and stays “soul” elsewhere.")
                }
                DictionaryAppScopeEditor(apps: $apps)
                DictionaryProjectScopeEditor(projects: $projects, suggestions: suggestions)
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .formStyle(.grouped).frame(height: 660)
            .task { suggestions = await model.knownProjects() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.put(DictionaryEntry(id: entry.id, spelling: spelling, aliases: aliases.components(separatedBy: .newlines), apps: apps,
                                                 projects: projects, context: context.components(separatedBy: .newlines))) {
                        dismiss()
                    } else { error = model.error; model.error = nil }
                }.keyboardShortcut(.defaultAction).prominent().disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .closingActions()
            .padding([.horizontal, .bottom], GoblinBrand.pagePadding)
        }
        .frame(width: 460)
    }
}

extension TermSuggestions {
    // NSSpellChecker knows inflections ("manages", "windows") that plain word lists lack.
    // Proper nouns are accepted in their capitalized form ("Monday"). Words the user taught macOS count as known.
    @MainActor static func isKnownEnglishWord(_ surface: String) -> Bool {
        let word = surface.trimmingCharacters(in: .punctuationCharacters)
        guard word.contains(where: \.isLetter) else { return true }
        let checker = NSSpellChecker.shared
        func known(_ value: String) -> Bool {
            checker.checkSpelling(of: value, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
        let lower = word.lowercased()
        return known(lower) || known(lower.prefix(1).uppercased() + lower.dropFirst())
    }
}
