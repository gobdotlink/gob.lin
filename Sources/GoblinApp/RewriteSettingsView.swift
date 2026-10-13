import GoblinCore
import SwiftUI

struct RewriteSettingsView: View {
    @State private var settings: RewriteSettings
    private let defaults: UserDefaults
    private let inspectKeychain: Bool
    private let onSaved: () -> Void
    private let onFailure: (DiagnosticFailure) -> Void
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var message: String?
    @State private var failed = false

    init(defaults: UserDefaults = .standard, inspectKeychain: Bool = true, onSaved: @escaping () -> Void = {},
         onFailure: @escaping (DiagnosticFailure) -> Void = { _ in }) {
        self.defaults = defaults; self.inspectKeychain = inspectKeychain
        self.onSaved = onSaved; self.onFailure = onFailure
        _settings = State(initialValue: RewriteSettingsStore.load(defaults: defaults))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI cleanup", isOn: $settings.enabled)
                Text("Off by default. When enabled, dictated text and your preferred spellings are sent to the provider you choose.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("AI cleanup") }
            Section("OpenAI-compatible provider") {
                TextField("Base URL", text: $settings.baseURL)
                    .autocorrectionDisabled()
                TextField("Model", text: $settings.model)
                    .autocorrectionDisabled()
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
            }
            Section("Cleanup level") {
                Picker("Cleanup", selection: $settings.cleanup) {
                    ForEach(RewriteCleanup.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("None skips the provider. Light keeps your wording; Medium also fixes minor grammar and accidental repetition.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("One predefined prompt treats the transcript as data. Requests use temperature 0 and share a four-second deadline. If cleanup fails, gob.lin pastes raw text and shows “polish failed — pasted raw”.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let message { Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary) }
                    Spacer()
                    Button("Save settings") { save() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshKeyStatus() }
        .onChange(of: settings.baseURL) { _, _ in apiKey = ""; message = nil; refreshKeyStatus() }
    }

    private func refreshKeyStatus() {
        guard inspectKeychain else { keySaved = false; return }
        do { keySaved = try RewriteKeychain.containsKey(for: settings) }
        catch { keySaved = false }
    }

    private func save() {
        do {
            let endpoint = try settings.endpoint()
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
            apiKey = ""
            refreshKeyStatus()
            message = "Settings saved."
            failed = false
            onSaved()
        } catch { show(error) }
    }

    private func show(_ error: Error) { message = error.localizedDescription; failed = true; onFailure(.settingsSaveFailed) }
}
