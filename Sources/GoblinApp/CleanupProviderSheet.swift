import GoblinCore
import SwiftUI

/// Why these settings can't run cleanup yet, or nil when they can.
func cleanupSetupProblem(_ settings: RewriteSettings, hasKey: Bool) -> String? {
    if settings.provider.runsOnDevice { return OnDeviceCleanup.availability.problem }
    let endpoint: URL
    do { endpoint = try settings.endpoint() } catch { return error.localizedDescription }
    if settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a model before turning on AI cleanup." }
    if !hasKey, !isLocalHost(endpoint.host) { return "Add an API key before turning on AI cleanup." }
    return nil
}

func isLocalHost(_ host: String?) -> Bool { ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host ?? "") }

/// Service, address, model, reasoning and key, edited together and applied on Save.
struct CleanupProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: RewriteSettings
    private let defaults: UserDefaults
    private let inspectCredentials: Bool
    /// Opened from the AI cleanup switch: Save also turns cleanup on.
    private let turnOn: Bool
    private let onSave: (RewriteSettings) -> Void
    private let onFailure: (DiagnosticFailure) -> Void
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var removeKey = false
    @State private var message: String?
    /// The provider's model list, with the provider, address and key it was loaded for.
    @State private var listing: ModelListing?
    @State private var loadingModels = false
    @State private var refreshes = 0
    @FocusState private var modelFieldFocused: Bool
    @State private var handledRefreshes = 0

    init(settings: RewriteSettings, defaults: UserDefaults, inspectCredentials: Bool, turnOn: Bool,
         onSave: @escaping (RewriteSettings) -> Void, onFailure: @escaping (DiagnosticFailure) -> Void) {
        _settings = State(initialValue: settings)
        self.defaults = defaults; self.inspectCredentials = inspectCredentials
        self.turnOn = turnOn; self.onSave = onSave; self.onFailure = onFailure
    }

    private static let fieldWidth: CGFloat = 290

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Service") {
                        Picker("Service", selection: Binding(get: { settings.provider }, set: { provider in
                            settings.selectProvider(provider)
                            // Never carry a draft credential to a different provider, even with the same URL.
                            apiKey = ""; refreshKeyStatus()
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
                    if !settings.provider.hasFixedAddress {
                        LabeledContent("Address") {
                            TextField("Address", text: $settings.baseURL, prompt: Text("https://…"))
                                .labelsHidden().font(.body.monospaced()).autocorrectionDisabled().frame(width: Self.fieldWidth)
                        }
                    }
                    if settings.provider.runsOnDevice {
                        if let problem = OnDeviceCleanup.availability.problem {
                            StatusRow(.waiting, Text(problem))
                        } else {
                            StatusRow(.ready, Text("Ready on this Mac. Cleanup runs offline and sends nothing anywhere."))
                        }
                    } else {
                    LabeledContent("Model") { modelField.frame(width: Self.fieldWidth) }
                    LabeledContent {
                        Picker("Reasoning", selection: $settings.reasoning) {
                            ForEach(RewriteReasoning.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    } label: {
                        Text("Reasoning")
                        Text("Off is fastest. Cleanup rarely needs more.")
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            SecureField("API key", text: $apiKey, prompt: Text(keySaved ? "••••••••••••" : "Paste a key"))
                                .labelsHidden().font(.body.monospaced())
                            if keySaved { Button("Remove") { keySaved = false; removeKey = true; apiKey = "" } }
                        }
                        .frame(width: Self.fieldWidth)
                    } label: {
                        Text("API key")
                        Label(keySaved ? "Saved in gob.lin preferences" : "Stored unencrypted in gob.lin preferences", systemImage: "key")
                    }
                    modelStatus
                    }
                } header: { Text("Cleanup provider") } footer: {
                    Text(settings.provider.detail)
                }
                if !settings.provider.runsOnDevice {
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
                }
            }
            .formStyle(PlateFormStyle())
            .padding(.top, 14)
            .frame(height: 450)
            HStack(spacing: 8) {
                if let message { StatusRow(.problem, Text(message)) }
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(turnOn ? "Save and Turn On" : "Save") { save() }.prominent().keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
        .frame(width: 680)
        .background(GoblinBrand.caseBackground)
        .onAppear { refreshKeyStatus() }
        .onChange(of: settings.baseURL) { _, _ in apiKey = ""; refreshKeyStatus() }
        .onChange(of: settings) { _, _ in message = nil }
        .onChange(of: apiKey) { _, _ in message = nil }
        .task(id: ModelRequest(source: modelSource, refresh: refreshes)) { await loadModels(refresh: refreshes) }
    }

    private var modelField: some View {
        HStack(spacing: 8) {
            TextField("Model", text: Binding(get: { settings.model }, set: { typed in
                // A completion or paste that lands on a preset counts as choosing it; a keystroke doesn't.
                if abs(typed.count - settings.model.count) > 1, settings.provider.models.contains(where: { $0.id == typed }) {
                    chooseModel(typed)
                } else { settings.model = typed }
            }), prompt: Text("model-id"))
                .labelsHidden().font(.body.monospaced()).autocorrectionDisabled()
                .focused($modelFieldFocused)
                .textInputSuggestions {
                    ForEach(modelSuggestions) { option in
                        Text("\(Text(option.id).monospaced())  \(Text(option.name ?? "").foregroundStyle(.secondary))")
                            .textInputCompletion(option.id)
                    }
                }
            Menu {
                if !settings.provider.models.isEmpty {
                    Section("Suggested") {
                        ForEach(settings.provider.models) { preset in
                            Button { chooseModel(preset.id) } label: { Text(preset.title); Text(preset.id) }
                        }
                    }
                }
                if !listedModels.isEmpty {
                    Section("From \(modelSourceName)") {
                        // Router lists run to hundreds of vendor/model ids, so long lists nest by vendor.
                        if listedModels.count > 40 {
                            ForEach(vendorMenus, id: \.vendor) { group in
                                Menu(group.vendor) { ForEach(group.models) { modelButton($0, vendor: group.vendor) } }
                            }
                            ForEach(listedModels.filter { !$0.id.contains("/") }) { modelButton($0) }
                        } else {
                            ForEach(listedModels) { modelButton($0) }
                        }
                    }
                }
            } label: {
                Label("Choose Model", systemImage: "chevron.down").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden).fixedSize()
            .help("Suggested models, then the models \(modelSourceName) offers this key")
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
        let saved = inspectCredentials && draft.isEmpty && keySaved ? (try? RewriteKeyStore.load(for: settings, defaults: defaults)) ?? "" : ""
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

    private var vendorMenus: [(vendor: String, models: [RewriteModelOption])] {
        Dictionary(grouping: listedModels.filter { $0.id.contains("/") }) { String($0.id.prefix { $0 != "/" }) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    private func modelButton(_ option: RewriteModelOption, vendor: String? = nil) -> some View {
        Button { chooseModel(option.id) } label: {
            Text(option.name ?? vendor.map { String(option.id.dropFirst($0.count + 1)) } ?? option.id)
            if option.name != nil || vendor != nil { Text(option.id) }
        }
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
        } else if let listing = shownListing, listing.models.isEmpty {
            StatusRow(.waiting, Text("\(name) didn't list any chat models. You can still type a model ID."))
        } else if let listing = shownListing {
            let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let forKey = listing.source.key.isEmpty ? "" : " for this key"
            if !model.isEmpty, listing.models.contains(where: { $0.id == model }) {
                StatusRow(.ready, Text("\(name) lists \(Text(model).monospaced())\(forKey)."))
            } else if !modelFieldFocused, !model.isEmpty {
                // Wait until editing ends: a half-typed id is never listed.
                StatusRow(.waiting, Text("\(name) doesn't list \(Text(model).monospaced())\(forKey). It might still work."))
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
        guard inspectCredentials, !source.provider.runsOnDevice else { return }
        if !manual {
            guard modelHost != nil, isLocalHost(modelHost) || !source.key.isEmpty else { return }
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
        removeKey = false
        guard inspectCredentials else { keySaved = false; return }
        do { keySaved = try !RewriteKeyStore.load(for: settings, defaults: defaults).isEmpty }
        catch { keySaved = false }
    }

    private func save() {
        do {
            var next = settings
            if turnOn { next.enabled = true }
            if !next.provider.runsOnDevice { _ = try next.endpoint() }
            _ = try next.extraRequestParameters()
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if next.enabled, let problem = cleanupSetupProblem(next, hasKey: !key.isEmpty || keySaved) {
                throw RewriteFailure.configuration(problem)
            }
            if inspectCredentials, !next.provider.runsOnDevice, !key.isEmpty || removeKey { try RewriteKeyStore.save(key, for: next, defaults: defaults) }
            try RewriteSettingsStore.save(next, defaults: defaults)
            if next.provider.runsOnDevice { OnDeviceCleanup.prewarm() }
            onSave(next)
            dismiss()
        } catch { message = error.localizedDescription; onFailure(.settingsSaveFailed) }
    }
}
