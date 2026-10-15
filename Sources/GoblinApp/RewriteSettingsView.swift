import GoblinCore
import SwiftUI

struct RewriteSettingsView: View {
    @State private var settings: RewriteSettings
    @State private var savedSettings: RewriteSettings
    private let defaults: UserDefaults
    private let inspectCredentials: Bool
    private let onSaved: () -> Void
    private let onFailure: (DiagnosticFailure) -> Void
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var message: String?
    @State private var failed = false
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testOutput: String?
    @State private var testMeta: String?
    /// The provider's model list, with the provider, address and key it was loaded for.
    @State private var listing: ModelListing?
    @State private var loadingModels = false
    @State private var refreshes = 0
    @State private var handledRefreshes = 0

    init(defaults: UserDefaults = .standard, inspectCredentials: Bool = true, onSaved: @escaping () -> Void = {},
         onFailure: @escaping (DiagnosticFailure) -> Void = { _ in }) {
        self.defaults = defaults; self.inspectCredentials = inspectCredentials
        self.onSaved = onSaved; self.onFailure = onFailure
        let saved = RewriteSettingsStore.load(defaults: defaults)
        _settings = State(initialValue: saved)
        _savedSettings = State(initialValue: saved)
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                Text("AI cleanup")
                Text("Off unless you turn it on. Only the text of each take is sent, never the audio.")
            }
            StatusRow(savedOn ? .ready : .off,
                      Text(savedOn ? "Your text goes to \(Text(savedSettings.provider.title).fontWeight(.semibold)). Everything else stays on this Mac."
                                   : "Off. Everything stays on this Mac."))
            if hasUnsavedChanges {
                StatusRow(.waiting, Text("Unsaved changes. They apply to dictation once you save.")) {
                    Button("Save Settings") { save() }.prominent().disabled(testing)
                }
            }
            if let message {
                StatusRow(failed ? .problem : .ready, Text(message))
            }
        }
        Section {
            LabeledContent("Service") {
                Picker("Service", selection: Binding(get: { settings.provider }, set: { provider in
                    settings.selectProvider(provider)
                    // Never carry a draft credential to a different provider, even with the same URL.
                    apiKey = ""; message = nil; refreshKeyStatus()
                })) {
                    ForEach(RewriteProviderGroup.allCases) { group in
                        Section {
                            ForEach(RewriteProvider.allCases.filter { $0.group == group }) { Text($0.title).tag($0) }
                        } header: {
                            // "Custom" over a lone "Custom" says nothing.
                            if group != .custom { Text(group.title) }
                        }
                    }
                }
                .labelsHidden().fixedSize()
            }
            LabeledContent("Address") {
                TextField("Address", text: $settings.baseURL, prompt: Text("https://…"))
                    .labelsHidden().font(.body.monospaced()).autocorrectionDisabled().frame(width: 300)
            }
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    TextField("Model", text: Binding(get: { settings.model }, set: { typed in
                        // A completion or paste that lands on a preset counts as choosing it; a keystroke doesn't.
                        if abs(typed.count - settings.model.count) > 1, settings.provider.models.contains(where: { $0.id == typed }) {
                            chooseModel(typed)
                        } else { settings.model = typed }
                    }), prompt: Text("model-id"))
                        .labelsHidden().font(.body.monospaced()).autocorrectionDisabled().frame(width: 190)
                        .textInputSuggestions {
                            ForEach(modelSuggestions) { option in
                                Text("\(Text(option.id).monospaced())  \(Text(option.name ?? "").foregroundStyle(.secondary))")
                                    .textInputCompletion(option.id)
                            }
                        }
                    Menu("Suggested") {
                        if !settings.provider.models.isEmpty {
                            Section("Suggested") {
                                ForEach(settings.provider.models) { preset in
                                    Button { chooseModel(preset.id) } label: { Text(preset.title); Text(preset.id) }
                                }
                            }
                        }
                        if !listedModels.isEmpty {
                            Section("From \(modelSourceName)") {
                                ForEach(listedModels) { option in
                                    Button { chooseModel(option.id) } label: {
                                        Text(option.name ?? option.id)
                                        if option.name != nil { Text(option.id) }
                                    }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(settings.provider.models.isEmpty && listedModels.isEmpty)
                    Button { refreshes += 1 } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                            .opacity(loadingModels ? 0 : 1)
                            .overlay { if loadingModels { ProgressView().controlSize(.small) } }
                    }
                    .help("Ask \(modelSourceName) which models this key can use")
                    .disabled(!inspectCredentials)
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text(keySaved ? "••••••••••••" : "Paste a key"))
                        .labelsHidden().font(.body.monospaced()).frame(width: 190)
                    if keySaved {
                        Button("Remove") {
                            do {
                                try RewriteKeyStore.save("", for: settings, defaults: defaults)
                                keySaved = false; apiKey = ""; message = "API key removed."; failed = false
                                onSaved()
                            }
                            catch { show(error) }
                        }
                    }
                }
            } label: {
                Text("API key")
                Label(keySaved ? "Saved in gob.lin preferences" : "Stored unencrypted in gob.lin preferences", systemImage: "key")
            }
            modelStatus
        } header: { Text("Provider") } footer: {
            Text(settings.provider.detail)
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Level") {
                    Picker("Level", selection: $settings.cleanup) {
                        ForEach(RewriteCleanup.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().tint(GoblinBrand.moss)
                }
                Text(settings.cleanup.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            LabeledContent {
                Picker("Reasoning", selection: $settings.reasoning) {
                    ForEach(RewriteReasoning.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            } label: {
                Text("Reasoning")
                Text("Off is fastest. Cleanup rarely needs more.")
            }
        } header: { Text("Style") }
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Try it on a sample").fontWeight(.semibold)
                    Spacer()
                    if let testMeta { Text(testMeta).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                    Button(testing ? "Testing…" : testOutput == nil ? "Run Test" : "Run Again") { testCleanup() }
                        .prominent()
                        .disabled(testing || hasUnsavedChanges || !inspectCredentials || !savedSettings.enabled || savedSettings.cleanup == .none)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("What you said → what gets typed")
                        Spacer()
                        if let testOutput {
                            Text("\(Self.sample.split(whereSeparator: \.isWhitespace).count) → \(testOutput.split(whereSeparator: \.isWhitespace).count) words").monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Group {
                        if let testOutput { InlineDiff(from: Self.sample, to: testOutput) }
                        else { Text(Self.sample).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                StatusRow(.waiting, Text("Slower than 4 s? I type what you said instead, and tell you in the bubble."))
            }
            .padding(.vertical, 6)
        } header: { Text("Try it") }
        Section {
            DisclosureGroup("Advanced request options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Send temperature", isOn: Binding(get: { settings.temperature != nil }, set: { enabled in
                        settings.temperature = enabled ? 0 : nil
                    }))
                    if settings.temperature != nil {
                        LabeledContent("Temperature (0–2)") {
                            TextField("Temperature", value: Binding(get: { settings.temperature ?? 0 }, set: { settings.temperature = $0 }), format: .number)
                                .labelsHidden().frame(width: 80)
                        }
                    }
                    Text("Extra options (JSON)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $settings.extraRequestJSON)
                        .font(.body.monospaced()).autocorrectionDisabled()
                        .frame(minHeight: 100, maxHeight: 160)
                        .accessibilityLabel("Extra request options JSON")
                    Text("For example {\"max_completion_tokens\": 1024}. Options override request defaults, and null leaves a field out. Model, messages and streaming are managed by gob.lin. Keep API keys in the API key field, not here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: settings.baseURL) { _, _ in apiKey = ""; message = nil; refreshKeyStatus() }
        .onChange(of: settings) { _, _ in message = nil }
        .task(id: ModelRequest(source: modelSource, refresh: refreshes)) { await loadModels(refresh: refreshes) }
        .onDisappear { testTask?.cancel(); testTask = nil; testing = false }
    }

    /// Fillers, a doubled word and missing punctuation, so the diff has something to show.
    static let sample = "um so i think we should uh ship the overlay fix tonight and and do onboarding tomorrow like the copy is basically done"

    private var savedOn: Bool { savedSettings.enabled && savedSettings.cleanup != .none }

    private var hasUnsavedChanges: Bool {
        settings != savedSettings || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Model list

    private struct ModelSource: Equatable {
        var provider: RewriteProvider
        var address: String
        var key: String
    }

    private struct ModelRequest: Equatable {
        var source: ModelSource
        var refresh: Int
    }

    private struct ModelListing {
        var source: ModelSource
        var models: [RewriteModelOption] = []
        var failure: Error?
    }

    /// What the list would be asked with: the typed key, else the saved one.
    private var modelSource: ModelSource {
        let draft = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = inspectCredentials && draft.isEmpty ? (try? RewriteKeyStore.load(for: settings, defaults: defaults)) ?? "" : ""
        return ModelSource(provider: settings.provider, address: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           key: draft.isEmpty ? saved : draft)
    }

    /// A list never shows under a provider, address or key it wasn't loaded for.
    private var shownListing: ModelListing? { listing.flatMap { $0.source == modelSource ? $0 : nil } }

    /// Loaded models the Suggested section doesn't already offer.
    private var listedModels: [RewriteModelOption] {
        let presets = Set(settings.provider.models.map(\.id))
        return (shownListing?.models ?? []).filter { !presets.contains($0.id) }
    }

    private var modelHost: String? { try? settings.endpoint().host() }

    /// Local and Custom go by their host, so the sentence names something real.
    private var modelSourceName: String {
        settings.provider == .local || settings.provider == .custom ? modelHost ?? "the server" : settings.provider.title
    }

    private var modelSuggestions: [RewriteModelOption] {
        let typed = settings.model.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        let all = settings.provider.models.map { RewriteModelOption(id: $0.id, name: $0.title) } + listedModels
        // ponytail: first 12 matches only; the menu beside the field holds the whole list.
        return Array(all.filter {
            $0.id != typed && ($0.id.localizedCaseInsensitiveContains(typed) || $0.name?.localizedCaseInsensitiveContains(typed) == true)
        }.prefix(12))
    }

    private func chooseModel(_ id: String) {
        if let preset = settings.provider.models.first(where: { $0.id == id }) { settings.selectModel(preset) }
        else { settings.model = id }
    }

    @ViewBuilder private var modelStatus: some View {
        let name = modelSourceName
        let tryAgain = Button("Try Again") { refreshes += 1 }
        if let listing = shownListing, let failure = listing.failure {
            switch failure as? RewriteFailure {
            case .httpStatus(401), .httpStatus(403):
                StatusRow(.problem, Text(listing.source.key.isEmpty ? "\(name) wants an API key before it lists models." : "\(name) didn't accept that key."))
            case .httpStatus(404):
                StatusRow(.problem, Text("\(name) doesn't list models at this address."))
            case .httpStatus(let status):
                StatusRow(.problem, Text("\(name) answered HTTP \(String(status)) when I asked for its models.")) { tryAgain }
            case .timeout:
                StatusRow(.waiting, Text("\(name) didn't send its models within 10 s.")) { tryAgain }
            case .transport:
                StatusRow(.problem, Text("I couldn't reach \(name).")) { tryAgain }
            case .invalidResponse:
                StatusRow(.problem, Text("\(name) sent a model list I couldn't read."))
            case .configuration(let reason):
                StatusRow(.problem, Text(reason))
            case nil:
                StatusRow(.problem, Text("I couldn't get models from \(name). \(failure.localizedDescription)")) { tryAgain }
            }
        } else if let listing = shownListing, !listing.models.isEmpty {
            let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty, !listing.models.contains(where: { $0.id == model }) {
                StatusRow(.waiting, Text("\(name) doesn't list \(Text(model).monospaced())\(listing.source.key.isEmpty ? "" : " for this key"). It might still work."))
            }
        }
    }

    /// Runs whenever the provider, address or key changes, and on Refresh. SwiftUI cancels the previous run.
    private func loadModels(refresh: Int) async {
        let source = modelSource
        let manual = refresh != handledRefreshes
        handledRefreshes = refresh
        loadingModels = false
        if listing?.source != source { listing = nil }
        guard inspectCredentials else { return }
        if !manual {
            let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(modelHost ?? "")
            guard modelHost != nil, local || !source.key.isEmpty else { return }
            // Typing in the address or key restarts this; wait for a pause before asking.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        loadingModels = true
        let snapshot = settings
        do {
            let models = try await RewriteModelCatalog().models(for: snapshot, apiKey: source.key)
            guard !Task.isCancelled else { return }
            listing = ModelListing(source: source, models: models)
        } catch {
            guard !Task.isCancelled else { return }
            listing = ModelListing(source: source, failure: error)
        }
        loadingModels = false
    }

    private func refreshKeyStatus() {
        guard inspectCredentials else { keySaved = false; return }
        do { keySaved = try !RewriteKeyStore.load(for: settings, defaults: defaults).isEmpty }
        catch { keySaved = false }
    }

    private func testCleanup() {
        guard !testing, !hasUnsavedChanges, inspectCredentials, savedSettings.enabled, savedSettings.cleanup != .none else { return }
        let snapshot = savedSettings
        testing = true
        message = nil
        testTask = Task { @MainActor in
            defer { testing = false; testTask = nil }
            do {
                let key = try RewriteKeyStore.load(for: snapshot, defaults: defaults)
                let start = ContinuousClock.now
                let result = await RewriteClient().rewrite(Self.sample, settings: snapshot, apiKey: key)
                try Task.checkCancellation()
                if let failure = result.failure { throw failure }
                guard result.wasRewritten else { throw RewriteFailure.invalidResponse }
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                testOutput = result.outputText
                testMeta = "\(snapshot.cleanup.title) · \(snapshot.model) · \(Int(milliseconds.rounded())) ms"
                failed = false
            } catch {
                guard !Task.isCancelled else { return }
                message = "\(snapshot.provider.title) didn't answer the test: \(error.localizedDescription)"
                failed = true
            }
        }
    }

    private func save() {
        do {
            let endpoint = try settings.endpoint()
            _ = try settings.extraRequestParameters()
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.enabled, settings.cleanup != .none {
                guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RewriteFailure.configuration("Enter a model before enabling AI cleanup.")
                }
                let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host ?? "")
                if !local, key.isEmpty {
                    guard inspectCredentials, try !RewriteKeyStore.load(for: settings, defaults: defaults).isEmpty else {
                        throw RewriteFailure.configuration("Enter an API key before enabling AI cleanup.")
                    }
                }
            }
            if !key.isEmpty, inspectCredentials { try RewriteKeyStore.save(key, for: settings, defaults: defaults) }
            try RewriteSettingsStore.save(settings, defaults: defaults)
            savedSettings = settings
            apiKey = ""
            refreshKeyStatus()
            message = "Settings saved."
            failed = false
            onSaved()
        } catch { show(error) }
    }

    private func show(_ error: Error) { message = error.localizedDescription; failed = true; onFailure(.settingsSaveFailed) }
}
