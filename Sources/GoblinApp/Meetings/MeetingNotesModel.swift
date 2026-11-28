import Foundation
import GoblinMeetings
import os

/// Notes for meetings: which installed tool and model write them, the templates, and the runs in progress.
///
/// The model starts as the best one found on this Mac (`NotesModelRanking`), but nothing is sent until the person
/// says so once: by writing a meeting's notes, or by choosing a model in Settings. After that, notes are written after
/// each call while "Write notes after each call" is on.
@MainActor
final class MeetingNotesModel: ObservableObject {
    enum Choice: Equatable, Hashable {
        /// The best model found, which can change as tools are installed.
        case automatic
        case none
        case model(NotesTool, String)
    }

    /// A tool's state on this Mac.
    enum ToolState: Equatable {
        case unknown, notInstalled
        case signedOut(NotesToolInstall)
        case ready(NotesToolInstall)

        var install: NotesToolInstall? {
            switch self {
            case .signedOut(let install), .ready(let install): install
            default: nil
            }
        }
    }

    @Published private(set) var tools: [NotesTool: ToolState] = [:]
    @Published private(set) var models: [NotesTool: [NotesModelOption]] = [:]
    @Published private(set) var scanning = false
    /// Meetings whose notes are being written now.
    @Published private(set) var writing: Set<String> = []
    /// What each run in `writing` is writing with, which may be a one-off model rather than the setting.
    @Published private(set) var active: [String: NotesSettings] = [:]
    /// Whether Meetings is on; set by the meetings controller.
    var meetingsEnabled: @MainActor () -> Bool = { true }
    /// Why the last run for a meeting failed, until the next one starts.
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var customTemplates: [NotesTemplate] = []

    private let defaults: UserDefaults
    private let store: MeetingStore
    private let vocabulary: @MainActor () -> [String]
    private let logger = Logger(subsystem: "app.goblin.dictation", category: "meetings")
    private var scan: Task<Void, Never>?

    static let choiceKey = "meetings.notes.choice"
    static let effortKey = "meetings.notes.effort"
    static let templateKey = "meetings.notes.template"
    static let styleKey = "meetings.notes.style"
    static let automaticKey = "meetings.notes.afterEachCall"
    static let consentKey = "meetings.notes.consented"
    static let customTemplatesKey = "meetings.notes.customTemplates"

    /// Off in previews and screenshots: nothing on this Mac is run or looked for.
    private var discovers: Bool

    init(defaults: UserDefaults, store: MeetingStore, discovers: Bool = true, vocabulary: @escaping @MainActor () -> [String]) {
        self.defaults = defaults
        self.store = store
        self.discovers = discovers
        self.vocabulary = vocabulary
        if let data = defaults.data(forKey: Self.customTemplatesKey),
           let saved = try? JSONDecoder().decode([NotesTemplate].self, from: data) {
            customTemplates = saved
        }
    }

    // MARK: Settings

    var choice: Choice {
        get {
            switch defaults.string(forKey: Self.choiceKey) {
            case nil, "automatic": return .automatic
            case "none": return .none
            case .some(let value):
                let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, let tool = NotesTool(rawValue: parts[0]) else { return .automatic }
                return .model(tool, parts[1])
            }
        }
        set {
            objectWillChange.send()
            switch newValue {
            case .automatic: defaults.set("automatic", forKey: Self.choiceKey)
            case .none: defaults.set("none", forKey: Self.choiceKey)
            case .model(let tool, let model): defaults.set("\(tool.rawValue)/\(model)", forKey: Self.choiceKey)
            }
            // A thinking level belongs to the model it was set for.
            defaults.removeObject(forKey: Self.effortKey)
            // Choosing a model is saying yes to sending transcripts to it.
            if newValue != .none { consented = true }
        }
    }

    /// Nil: the model's default (or the ranking's, for the automatic choice).
    var effort: String? {
        get { defaults.string(forKey: Self.effortKey) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.effortKey) }
    }

    var template: NotesTemplate {
        get {
            let id = defaults.string(forKey: Self.templateKey) ?? NotesTemplate.auto.id
            return allTemplates.first { $0.id == id } ?? .auto
        }
        set { objectWillChange.send(); defaults.set(newValue.id, forKey: Self.templateKey) }
    }

    var style: NotesStyle {
        get { defaults.string(forKey: Self.styleKey).flatMap(NotesStyle.init(rawValue:)) ?? .concise }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Self.styleKey) }
    }

    var afterEachCall: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.automaticKey) }
    }

    /// The person has said yes to sending transcripts to a notes model.
    var consented: Bool {
        get { defaults.bool(forKey: Self.consentKey) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.consentKey) }
    }

    var allTemplates: [NotesTemplate] { NotesTemplate.builtIns + customTemplates }

    func saveTemplate(_ template: NotesTemplate) {
        var saved = template
        saved.builtIn = false
        if let index = customTemplates.firstIndex(where: { $0.id == saved.id }) { customTemplates[index] = saved } else { customTemplates.append(saved) }
        persistTemplates()
    }

    func deleteTemplate(_ template: NotesTemplate) {
        customTemplates.removeAll { $0.id == template.id }
        persistTemplates()
        if defaults.string(forKey: Self.templateKey) == template.id { defaults.removeObject(forKey: Self.templateKey) }
    }

    private func persistTemplates() {
        if let data = try? JSONEncoder().encode(customTemplates) { defaults.set(data, forKey: Self.customTemplatesKey) }
    }

    /// What notes would be written with now: the choice resolved against the tools found. Nil with None, or when
    /// the chosen tool isn't ready.
    var settings: NotesSettings? {
        let ready = readyModels
        var resolved: NotesSettings?
        switch choice {
        case .none: return nil
        case .automatic: resolved = NotesModelRanking.best(available: ready)
        case .model(let tool, let model):
            guard ready[tool] != nil else { return nil }
            resolved = NotesSettings(tool: tool, model: model, effort: option(tool, model)?.defaultEffort)
        }
        guard var settings = resolved else { return nil }
        if let effort, let model = settings.model, option(settings.tool, model)?.efforts.contains(effort) ?? true { settings.effort = effort }
        settings.template = template
        settings.style = style
        return settings
    }

    /// A tool that's signed in but whose models couldn't be listed (it timed out, or failed to start).
    var unlistedTool: NotesTool? {
        NotesTool.allCases.first { tool in
            if case .ready = tools[tool] { return models[tool]?.isEmpty ?? true }
            return false
        }
    }

    /// Models of the tools that are installed and signed in.
    var readyModels: [NotesTool: [NotesModelOption]] {
        var ready: [NotesTool: [NotesModelOption]] = [:]
        for tool in NotesTool.allCases {
            if case .ready = tools[tool], let list = models[tool], !list.isEmpty { ready[tool] = list }
        }
        return ready
    }

    func option(_ tool: NotesTool, _ model: String) -> NotesModelOption? { models[tool]?.first { $0.id == model } }

    /// "GPT-6.2-Sol", for sentences.
    func modelName(_ settings: NotesSettings) -> String {
        settings.model.flatMap { option(settings.tool, $0)?.title } ?? settings.model ?? settings.tool.title
    }

    /// "GPT-6.2-Sol through Codex", for sentences about where the transcript goes.
    func describe(_ settings: NotesSettings) -> String {
        "\(modelName(settings)) through \(settings.tool.title)"
    }

    // MARK: Finding tools

    /// Looks for Codex and Claude Code again, and asks each signed-in one for its models.
    func refresh() {
        guard discovers, scan == nil else { return }
        scanning = true
        scan = Task { [weak self] in
            var found: [NotesTool: ToolState] = [:]
            var lists: [NotesTool: [NotesModelOption]] = [:]
            for tool in NotesTool.allCases {
                guard let install = await NotesTools.find(tool) else { found[tool] = .notInstalled; continue }
                guard install.signedIn else { found[tool] = .signedOut(install); continue }
                found[tool] = .ready(install)
                lists[tool] = (try? await NotesTools.models(install)) ?? []
            }
            guard let self else { return }
            self.tools = found
            self.models = lists
            self.scanning = false
            self.scan = nil
        }
    }

    /// Synthetic tools for screenshots, which are never looked for.
    func usePreview(tools: [NotesTool: ToolState], models: [NotesTool: [NotesModelOption]]) {
        discovers = false
        self.tools = tools
        self.models = models
    }

    /// Waits for a scan, starting one when nothing was ever found.
    func ready() async {
        if tools.isEmpty { refresh() }
        await scan?.value
    }

    // MARK: Writing

    /// Writes a meeting's notes with the current settings, or `override` for this meeting only. Saying yes here
    /// is the consent for later calls too.
    /// A write the person asked for. It's still checked right before the transcript goes: Meetings turned off, or
    /// notes switched to None meanwhile, stop it.
    /// `onDone` is told whether notes were saved: false when the write was skipped, cancelled or failed.
    func write(_ meetingID: String, override: NotesSettings? = nil, consent: Bool = true, onDone: (@MainActor (Bool) -> Void)? = nil) {
        // Any change of the notes model in Settings meanwhile (None, or another tool) stops it: the destination the
        // person was shown is no longer this one. A one-off "Write Again With" model stays fine while it doesn't.
        // Best Available is checked by what it resolves to as well, which a fresh look at the tools can change.
        let startChoice = choice
        let startRoute = settings.map { ($0.tool, $0.model) }
        Task {
            let wrote = await write(meetingID, override: override, consent: consent, stillWanted: { [weak self] in
                guard let self, self.meetingsEnabled(), self.choice == startChoice else { return false }
                let route = self.settings.map { ($0.tool, $0.model) }
                return route?.0 == startRoute?.0 && route?.1 == startRoute?.1
            })
            onDone?(wrote)
        }
    }

    /// Returns whether notes were saved.
    @discardableResult
    func write(_ meetingID: String, override: NotesSettings? = nil, consent: Bool = true,
               stillWanted: @escaping @MainActor @Sendable () -> Bool = { true }) async -> Bool {
        guard !writing.contains(meetingID) else { return false }
        await ready()
        // Another request for this meeting may have started while the tools were being found.
        guard !writing.contains(meetingID) else { return false }
        guard let settings = override ?? settings else {
            failures[meetingID] = "There's no notes model to write with. Choose one in Settings › Meeting Recording."
            return false
        }
        guard let install = tools[settings.tool]?.install, case .ready = tools[settings.tool] else {
            failures[meetingID] = (tools[settings.tool] == .notInstalled ? MeetingNotesError.notInstalled(settings.tool)
                : MeetingNotesError.signedOut(settings.tool)).localizedDescription
            return false
        }
        if consent { consented = true }
        writing.insert(meetingID)
        active[meetingID] = settings
        failures[meetingID] = nil
        let words = vocabulary()
        let logger = logger
        var wrote = false
        do {
            try await store.writeNotes(meetingID, settings: settings, vocabulary: words, runner: NotesTools.runner(install),
                                       proceed: { await stillWanted() }) { line in
                logger.info("\(line, privacy: .public)")
            }
            wrote = true
        } catch MeetingNotesError.tooShort {
            failures[meetingID] = MeetingNotesError.tooShort.localizedDescription
        } catch {
            if !(error is CancellationError) { failures[meetingID] = error.localizedDescription }
            // The tool's own message can hold anything it chose to say back, so it stays private in the log.
            logger.error("notes failed: \(error.localizedDescription, privacy: .private)")
        }
        writing.remove(meetingID)
        active[meetingID] = nil
        NotificationCenter.default.post(name: .meetingsEdited, object: nil)
        return wrote
    }

    /// After a call is processed: writes its notes when the person has said yes and "Write notes after each call" is
    /// on. Returns whether it wrote any.
    /// `allowed` is the caller's own say, asked again after finding the tools: Meetings still on, not quitting.
    func afterProcessing(_ meetingID: String, allowed: @escaping @MainActor @Sendable () -> Bool = { true }) async -> Bool {
        guard wanted(allowed) else { return false }
        await ready()
        // Finding the tools takes a moment, in which notes or Meetings may have been turned off; so does starting the
        // tool, so the runner asks once more right before the transcript goes.
        guard wanted(allowed), let chosen = settings else { return false }
        // The tool and model it's sent to must still be the chosen ones when it goes, or Settings would have named
        // another destination meanwhile.
        await write(meetingID, override: chosen, consent: false, stillWanted: { [weak self] in
            guard let self, self.wanted(allowed), let now = self.settings else { return false }
            return now.tool == chosen.tool && now.model == chosen.model
        })
        return failures[meetingID] == nil
    }

    /// The person said yes once, wants notes after each call, has a model chosen, and the caller still agrees.
    private func wanted(_ allowed: @MainActor () -> Bool) -> Bool {
        consented && afterEachCall && choice != .none && allowed()
    }

    // MARK: Fixes

    func dismissFix(_ meetingID: String, heard: String) async throws { try await store.dismissFix(meetingID, heard: heard) }
    func applyFix(_ meetingID: String, heard: String) async throws { try await store.applyFix(meetingID, heard: heard) }
    func applyFixes(_ meetingID: String, heard: [String]) async throws { try await store.applyFixes(meetingID, heard: heard) }
    func suggestFixes(_ meetingID: String, heard: [String]) async throws { try await store.suggestFixes(meetingID, heard: heard) }

    func deleteNotes(_ meetingID: String) async throws {
        try await store.deleteNotes(meetingID)
        failures[meetingID] = nil
    }
}
