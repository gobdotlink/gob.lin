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
    @State private var testOutput: String?
    @State private var testMeta: String?

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
                    ForEach(RewriteProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            LabeledContent("Address") {
                TextField("Address", text: $settings.baseURL, prompt: Text("https://…"))
                    .labelsHidden().font(.body.monospaced()).autocorrectionDisabled().frame(width: 300)
            }
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    TextField("Model", text: $settings.model, prompt: Text("model-id"))
                        .labelsHidden().font(.body.monospaced()).autocorrectionDisabled().frame(width: 190)
                    if !settings.provider.models.isEmpty {
                        Menu("Suggested") {
                            ForEach(settings.provider.models) { preset in
                                Button(preset.title) { settings.selectModel(preset); message = nil }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text(keySaved ? "••••••••••••" : "Paste a key"))
                        .labelsHidden().font(.body.monospaced()).frame(width: 190)
                    if keySaved {
                        Button("Remove") {
                            do {
                                try RewriteKeychain.delete(for: settings)
                                keySaved = false; apiKey = ""; message = "API key removed."; failed = false
                                onSaved()
                            }
                            catch { show(error) }
                        }
                    }
                }
            } label: {
                Text("API key")
                Label(keySaved ? "Saved in your Keychain" : "Kept only in your Keychain", systemImage: "lock")
            }
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
                        .disabled(testing || hasUnsavedChanges || !inspectKeychain || !savedSettings.enabled || savedSettings.cleanup == .none)
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
                    Text("For example {\"max_completion_tokens\": 1024}. Options override request defaults, and null leaves a field out. Model, messages and streaming are managed by gob.lin. Keep API keys in the Keychain field, not here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: settings.baseURL) { _, _ in apiKey = ""; message = nil; refreshKeyStatus() }
        .onChange(of: settings) { _, _ in message = nil }
        .onDisappear { testTask?.cancel(); testTask = nil; testing = false }
    }

    /// Fillers, a doubled word and missing punctuation, so the diff has something to show.
    static let sample = "um so i think we should uh ship the overlay fix tonight and and do onboarding tomorrow like the copy is basically done"

    private var savedOn: Bool { savedSettings.enabled && savedSettings.cleanup != .none }

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
