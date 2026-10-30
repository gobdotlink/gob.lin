import GoblinCore
import GoblinEngines
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DictionaryModel: ObservableObject {
    static let suggestsTermsKey = "dictionary.suggestsTerms"
    static let dismissedSuggestionsKey = "dictionary.dismissedSuggestions"

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
        didSet { defaults.set(suggestsTerms, forKey: Self.suggestsTermsKey); reviewSuggestions() }
    }
    private let defaults: UserDefaults
    private var dismissed: Set<String>
    private var correctionCandidates: [TermSuggestion] = []
    private var repositoryCandidates: [TermSuggestion] = []
    private var repositoryCache: [String: (read: Date, candidates: [TermSuggestion])] = [:]
    private var repositoryTask: Task<Void, Never>?

    /// Project names to suggest: T3 Code and Paseo projects on this Mac, the last detected project and existing scopes.
    func knownProjects() async -> [String] {
        var seen: Set<String> = []
        let stored = await Task.detached(priority: .userInitiated) {
            ProjectResolution.t3ProjectTitles() + ProjectResolution.paseoProjectNames()
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
        do { entries = try repository.load(); available = true }
        catch { lastFailure = .dictionaryUnavailable; self.error = "Could not load your dictionary: \(error.localizedDescription)" }
    }

    /// A new term for the last dictation's place: its project if one was detected, otherwise its app.
    func newEntry() -> DictionaryEntry {
        if let project = lastContext?.project?.name { return DictionaryEntry(spelling: "", projects: [project]) }
        if let app = lastContext?.bundleIdentifier, !app.isEmpty { return DictionaryEntry(spelling: "", apps: [app]) }
        return DictionaryEntry(spelling: "")
    }

    // MARK: Suggestions

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

    /// Offers the terms the user fixed after a dictation into `scope`.
    func offerCorrection(dictated: String, edited: String, scope: DictionaryScope) {
        guard suggestsTerms else { return }
        let found = TermSuggestions.fromCorrection(dictated: dictated, edited: edited, scope: scope)
        guard !found.isEmpty else { return }
        correctionCandidates = Array((found + correctionCandidates).prefix(24))
        reviewSuggestions()
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
        let next = TermSuggestions.review(correctionCandidates + repositoryCandidates, entries: entries, dismissed: dismissed,
                                          isKnownWord: TermSuggestions.isKnownEnglishWord)
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
        do { try repository.save(next); entries = try DictionaryRepository.validated(next); error = nil; lastFailure = nil; return true }
        catch { lastFailure = .dictionaryUnavailable; self.error = error.localizedDescription; return false }
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
    @State private var filter = TermFilter.all

    private enum TermFilter: Hashable { case all, everywhere, app(String), project(String) }

    init(model: DictionaryModel, service: SpeechModelService, defaults: UserDefaults = .standard) {
        self.model = model; self.service = service
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

    private var scopedApps: [String] {
        Array(Set(model.entries.flatMap(\.apps))).sorted {
            DictionaryApps.name($0).localizedStandardCompare(DictionaryApps.name($1)) == .orderedAscending
        }
    }

    private var scopedProjects: [String] {
        var seen: Set<String> = []
        return model.entries.flatMap(\.projects).filter { seen.insert(DictionaryScope.projectKey($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var shownEntries: [DictionaryEntry] {
        let entries: [DictionaryEntry]
        switch filter {
        case .all: entries = model.entries
        case .everywhere: entries = model.entries.filter { !$0.isScoped }
        case .app(let id): entries = model.entries.filter { $0.apps.contains(id) }
        case .project(let name):
            entries = model.entries.filter { $0.projects.contains { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(name) } }
        }
        return entries.sorted { $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending }
    }

    private static func describe(_ source: DetectedProject.Source) -> String {
        switch source {
        case .repository: "from the open file's repository"
        case .t3Database, .t3Interface: "from the T3 Code thread"
        case .paseoWorkspaces: "from the Paseo workspace"
        case .paseoInterface: "from Paseo's sidebar, best effort"
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
            if model.entries.isEmpty {
                ContentUnavailableView("Add your vocabulary", systemImage: "character.book.closed",
                    description: Text("Add a preferred spelling and optional “sounds like” aliases. Import a text file with one term per line."))
                    .frame(maxWidth: .infinity)
            } else {
                if scoped {
                    Picker("Show", selection: $filter) {
                        Text("All terms").tag(TermFilter.all)
                        Text("Used everywhere").tag(TermFilter.everywhere)
                        Divider()
                        ForEach(scopedApps, id: \.self) { id in Text(DictionaryApps.name(id)).tag(TermFilter.app(id)) }
                        if !scopedProjects.isEmpty {
                            Divider()
                            ForEach(scopedProjects, id: \.self) { name in Text("Project: \(name)").tag(TermFilter.project(name)) }
                        }
                    }
                }
                ForEach(shownEntries) { entry in
                    LabeledContent {
                        HStack {
                            Button("Edit") { editing = entry }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(entry) }.labelStyle(.iconOnly)
                                .accessibilityLabel("Delete \(entry.spelling)")
                        }
                    } label: {
                        Text(entry.spelling).font(.body.monospaced())
                        if !entry.aliases.isEmpty { Text("sounds like: " + entry.aliases.joined(separator: ", ")) }
                        if entry.isScoped {
                            Text("Only in " + [entry.apps.isEmpty ? nil : DictionaryApps.summary(entry.apps),
                                               entry.projects.isEmpty ? nil : "project " + entry.projects.joined(separator: ", ")]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                        if usage?.excluded.contains(entry.spelling) == true { Text("Not sent to recognition").foregroundStyle(.secondary) }
                    }
                }
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
        } header: {
            HStack {
                Text("Terms")
                Spacer()
                Group {
                    Button("Import Words…") { importing = true }.disabled(!model.available)
                    Button("Add Term", systemImage: "plus") { editing = model.newEntry() }.disabled(!model.available)
                        .prominent()
                }
                // The plate header's small caps and letter spacing are for the label, not the buttons.
                .textCase(nil).tracking(0).font(.callout).controlSize(.small)
            }
        }
        Section {
            LabeledContent {
                Text(service.selectedModel.name)
            } label: {
                Text("Speech Model")
                if service.selectedModel.capabilities.customVocabulary { Text("Spelling hints · whole terms, project and app terms first, then newest") }
            }
            LabeledContent {
                Text("Every model")
            } label: {
                Text("Aliases")
                Text("I replace exact “sounds like” matches after recognition.")
            }
            LabeledContent {
                Text(cleanupEnabled ? "On" : "Off")
            } label: {
                Text("Cleanup")
                Text(cleanupEnabled ? "I add the preferred spellings for the app and project you're dictating into to the prompt."
                                    : "I don't send your dictionary to a rewrite model.")
            }
            Toggle(isOn: $model.suggestsTerms) {
                Text("Suggest words")
                Text("I look for names in the project you're dictating into and in words you fix afterwards. I only add one when you click Add.")
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
        } header: { Text("How I Use Them") } footer: {
            if model.available, scoped, service.selectedModel.capabilities.customVocabulary {
                Text("App-specific terms join these when you dictate into their apps and share the same limit. Project terms apply after recognition, once I know the project.")
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
        .onChange(of: model.entries) {
            // When the filtered app or project loses its last term, or no term is scoped any more, show every term.
            switch filter {
            case .app(let id) where !model.entries.contains(where: { $0.apps.contains(id) }): filter = .all
            case .project(let name) where !scopedProjects.contains(name): filter = .all
            case .everywhere where !model.entries.contains(where: \.isScoped): filter = .all
            default: break
            }
        }
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
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if let place = model.suggestionPlace {
                            let used = model.entries.active(in: place.scope).count
                            Text("\(used) of \(DictionaryScope.activeLimit) words for \(place.name)").font(.system(size: 11.5))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 12)
                    if model.suggestions.count > 1 { Button("Add All") { model.acceptAll() }.controlSize(.small) }
                }
                .padding(.bottom, 6)
                ForEach(model.suggestions) { suggestion in
                    Hairline()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.spelling).font(.body.monospaced())
                            Text(caption(suggestion)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 12)
                        Button("Not Now") { model.dismiss(suggestion) }.accessibilityLabel("Not now, \(suggestion.spelling)")
                        Button("Add") { model.accept(suggestion) }.prominent().accessibilityLabel("Add \(suggestion.spelling)")
                    }
                    .controlSize(.small).padding(.vertical, 8)
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
        case .correction(let heard): reason = "you fixed “\(heard)”"
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

private struct DictionaryEntryEditor: View {
    let entry: DictionaryEntry
    @ObservedObject var model: DictionaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var spelling: String
    @State private var aliases: String
    @State private var apps: [String]
    @State private var projects: [String]
    @State private var suggestions: [String] = []
    @State private var error: String?

    init(entry: DictionaryEntry, model: DictionaryModel) {
        self.entry = entry
        self.model = model
        _spelling = State(initialValue: entry.spelling)
        _aliases = State(initialValue: entry.aliases.joined(separator: "\n"))
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
                    TextEditor(text: $aliases).font(.body.monospaced()).frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Sounds like aliases")
                } header: { Text("Sounds like — one alias per line") } footer: {
                    Text("For example, “day review” → “Dev review”. Aliases match whole words without crossing punctuation.")
                }
                DictionaryAppScopeEditor(apps: $apps)
                DictionaryProjectScopeEditor(projects: $projects, suggestions: suggestions)
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .formStyle(.grouped).frame(height: 560)
            .task { suggestions = await model.knownProjects() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.put(DictionaryEntry(id: entry.id, spelling: spelling, aliases: aliases.components(separatedBy: .newlines), apps: apps,
                                                 projects: projects)) {
                        dismiss()
                    } else { error = model.error; model.error = nil }
                }.keyboardShortcut(.defaultAction).disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
