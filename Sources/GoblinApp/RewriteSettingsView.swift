import GoblinCore
import SwiftUI

struct RewriteSettingsView: View {
    @State private var settings: RewriteSettings
    @State private var savedSettings: RewriteSettings
    private let defaults: UserDefaults
    private let inspectKeychain: Bool
    private let onSaved: () -> Void
    private let onFailure: (DiagnosticFailure) -> Void
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var message: String?
    @State private var failed = false
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, inspectKeychain: Bool = true, onSaved: @escaping () -> Void = {},
         onFailure: @escaping (DiagnosticFailure) -> Void = { _ in }) {
        self.defaults = defaults; self.inspectKeychain = inspectKeychain
        self.onSaved = onSaved; self.onFailure = onFailure
        let saved = RewriteSettingsStore.load(defaults: defaults)
        _settings = State(initialValue: saved)
        _savedSettings = State(initialValue: saved)
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                Text("Enable AI cleanup")
                Text("Off by default. When enabled, dictated text and your preferred spellings are sent to the provider you choose.")
            }
            .tint(GoblinBrand.tint)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(savedSettings.enabled && savedSettings.cleanup != .none ? "AI cleanup is currently on." : "AI cleanup is currently off.")
                    if hasUnsavedChanges {
                        Text("Unsaved changes — save to apply them to dictation.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(testing ? "Testing…" : "Test cleanup") { testCleanup() }
                    .disabled(testing || hasUnsavedChanges || !inspectKeychain || !savedSettings.enabled || savedSettings.cleanup == .none)
                Button("Save settings") { save() }
                    .buttonStyle(.borderedProminent).tint(GoblinBrand.tint)
                    .disabled(testing || !hasUnsavedChanges)
            }
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .red : .secondary)
            }
        } header: { Text("AI cleanup") } footer: {
            Text("Provider, key and cleanup changes take effect after you save. Test cleanup sends a short sample sentence using your saved settings.")
        }
        Section {
            Picker("Provider", selection: Binding(get: { settings.provider }, set: { provider in
                settings.selectProvider(provider)
                // Never carry a draft credential to a different provider, even with the same URL.
                apiKey = ""; message = nil; refreshKeyStatus()
            })) {
                ForEach(RewriteProvider.allCases) { Text($0.title).tag($0) }
            }
            TextField("Base URL", text: $settings.baseURL)
                .autocorrectionDisabled()
            TextField("Model", text: $settings.model)
                .autocorrectionDisabled()
            if !settings.provider.models.isEmpty {
                LabeledContent("Quick picks") {
                    HStack {
                        ForEach(settings.provider.models) { preset in
                            Button(preset.title) { settings.selectModel(preset); message = nil }
                                .help("Use \(preset.id) with \(preset.reasoning.title.lowercased()) reasoning.")
                        }
                    }
                }
            }
            SecureField(keySaved ? "API key — saved in Keychain" : "API key", text: $apiKey)
            HStack {
                Text(keySaved ? "A key is saved for this endpoint." : "Keys are stored only in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if keySaved {
                    Button("Remove key", role: .destructive) {
                        do { try RewriteKeychain.delete(for: settings); keySaved = false; apiKey = ""; message = "API key removed."; failed = false }
                        catch { show(error) }
                    }
                }
            }
        } header: { Text("Provider · OpenAI-compatible") } footer: {
            Text(settings.provider.detail + " Base URL and model remain editable. Each provider remembers its configuration when you save.")
        }
        Section {
            Picker("Cleanup level", selection: $settings.cleanup) {
                ForEach(RewriteCleanup.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).tint(GoblinBrand.tint)
            Text(settings.cleanup.detail).font(.caption).foregroundStyle(.secondary)
            Picker("Reasoning", selection: $settings.reasoning) {
                ForEach(RewriteReasoning.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("All cleanup presets preserve slang, swearing and intentional repetition. Off requests no reasoning and never falls back to reasoning on. Support depends on the model. Automatic may fall back to Low or the provider default.")
        }
        Section {
            DisclosureGroup("Advanced request options") {
                Toggle("Send temperature", isOn: Binding(get: { settings.temperature != nil }, set: { enabled in
                    settings.temperature = enabled ? 0 : nil
                }))
                .tint(GoblinBrand.tint)
                if settings.temperature != nil {
                    TextField("Temperature (0–2)", value: Binding(get: { settings.temperature ?? 0 }, set: { settings.temperature = $0 }), format: .number)
                }
                Text("Extra options (JSON)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $settings.extraRequestJSON)
                    .font(.body.monospaced()).autocorrectionDisabled()
                    .frame(minHeight: 100, maxHeight: 160)
                    .accessibilityLabel("Extra request options JSON")
                Text("For example: {\"max_completion_tokens\": 1024}. Options override request defaults; null omits a field. Choose Provider default for custom reasoning parameters. Model, messages and streaming are managed by gob.lin. These options are stored in preferences; keep API keys in the Keychain field.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("One predefined prompt treats the transcript as data. Temperature defaults to 0; requests share a four-second deadline. If cleanup fails, gob.lin pastes raw text and shows “polish failed — pasted raw”.")
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: settings.baseURL) { _, _ in apiKey = ""; message = nil; refreshKeyStatus() }
        .onChange(of: settings) { _, _ in message = nil }
        .onDisappear { testTask?.cancel(); testTask = nil; testing = false }
    }

    private var hasUnsavedChanges: Bool {
        settings != savedSettings || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshKeyStatus() {
        guard inspectKeychain else { keySaved = false; return }
        do { keySaved = try RewriteKeychain.containsKey(for: settings) }
        catch { keySaved = false }
    }

    private func testCleanup() {
        guard !testing, !hasUnsavedChanges, inspectKeychain, savedSettings.enabled, savedSettings.cleanup != .none else { return }
        let snapshot = savedSettings
        testing = true
        message = nil
        testTask = Task { @MainActor in
            defer { testing = false; testTask = nil }
            do {
                let key = try RewriteKeychain.load(for: snapshot)
                let start = ContinuousClock.now
                let result = await RewriteClient().rewrite("i will send the report tomorrow morning", settings: snapshot, apiKey: key)
                try Task.checkCancellation()
                if let failure = result.failure { throw failure }
                guard result.wasRewritten else { throw RewriteFailure.invalidResponse }
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                message = "\(snapshot.provider.title) test succeeded in \(seconds.formatted(.number.precision(.fractionLength(2)))) s: \(result.outputText)"
                failed = false
            } catch {
                guard !Task.isCancelled else { return }
                message = "\(snapshot.provider.title) test failed: \(error.localizedDescription)"
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
                    guard inspectKeychain, try RewriteKeychain.containsKey(for: settings) else {
                        throw RewriteFailure.configuration("Enter an API key before enabling AI cleanup.")
                    }
                }
            }
            if !key.isEmpty, inspectKeychain { try RewriteKeychain.save(key, for: settings) }
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
