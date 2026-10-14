import AppKit
import GoblinCore
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", audio = "Audio", model = "Model", dictionary = "Dictionary"
    case rewrite = "Post-processing", tone = "Tone", history = "History", overlay = "Overlay", diagnostics = "Diagnostics", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "mic"
        case .model: "cpu"
        case .dictionary: "character.book.closed"
        case .rewrite: "wand.and.stars"
        case .tone: "textformat"
        case .history: "clock"
        case .overlay: "rectangle.on.rectangle"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
    var comment: String {
        switch self {
        case .general: "your voice, wherever your cursor is"
        case .audio: "pick a mic, check the levels"
        case .model: "speech recognition, on this Mac"
        case .dictionary: "names and jargon, spelled your way"
        case .rewrite: "optional AI cleanup, off by default"
        case .tone: "how your dictation reads"
        case .history: "raw text, final text and audio"
        case .overlay: "the goblin that listens"
        case .diagnostics: "what gob.lin needs, what broke"
        case .about: "local by default"
        }
    }
    @MainActor var header: PaneHeader<EmptyView> { PaneHeader(title: rawValue, comment: comment) }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var speechModels: SpeechModelService? = nil

    private var section: SettingsSection { model.settingsSelection ?? .general }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.settingsSelection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                GoblinWordmark(size: 28).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(GoblinBrand.accent).frame(width: 6, height: 6)
                    Text("local by default").lineLimit(1)
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if section == .history {
                    HistoryView(model: model.history)
                } else {
                    // One header and one Form for every page: identical margins, grouping and scrolling.
                    if section != .about { section.header }
                    Form { sectionContents }
                    .formStyle(.grouped).scrollContentBackground(.hidden)
                    .id(section)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GoblinBrand.background)
            .navigationTitle(section.rawValue)
            .toolbar(removing: .title)
        }
        .preferredColorScheme(.dark)
        // Grouped Forms center a ~700pt column in wider windows; capping the width keeps every
        // page, Forms and History alike, on the same 20pt margins (System Settings is fixed-width too).
        .frame(minWidth: 820, maxWidth: 960, minHeight: 620)
        .defaultAppStorage(model.defaults)
    }

    @ViewBuilder
    private var sectionContents: some View {
        switch section {
        case .general: GeneralSettingsView(model: model)
        case .audio: AudioSettingsView(permissions: model.permissions, preview: model.audioPreview)
        case .model:
            if let speechModels { ModelSettingsView(service: speechModels) }
            else { Section { Text("The speech model service is not connected.").foregroundStyle(.secondary) } }
        case .dictionary: DictionarySettingsView(model: model.dictionary)
        case .rewrite: RewriteSettingsView(defaults: model.defaults, inspectKeychain: model.servicesEnabled,
                                               onSaved: { model.reloadRewriteCredentials(); model.diagnostics.resolve(.settings) },
                                               onFailure: { model.showFailure($0) })
        case .tone: ToneSettingsView()
        case .history: EmptyView()
        case .overlay: OverlaySettingsView(overlay: model.overlay)
        case .diagnostics: DiagnosticsView(model: model.diagnostics)
        case .about: AboutSettingsView(updates: model.updates)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("feedbackSoundsEnabled") private var sounds = true
    @AppStorage("audio.pauseMediaWhileDictating") private var pauseMedia = false
    @State private var loginEnabled = false
    @State private var loginError: String?

    var body: some View {
        Section {
            LabeledContent("Dictation shortcut") { ShortcutRecorder(service: model.hotkeys) }
            LabeledContent("Presets") {
                HStack {
                    Button("Fn / Globe") { model.hotkeys.setShortcut(.fn) }
                    Button("Right Option") { model.hotkeys.setShortcut(.rightOption) }
                    Button("Option + Space") { model.hotkeys.setShortcut(.optionSpace) }
                }
            }
            LabeledContent("Mode", value: "Hold to talk · tap to toggle")
            LabeledContent("Cancel") {
                HStack(spacing: 8) { Text("while recording").foregroundStyle(.secondary); KeyCap("esc") }
            }
            Label(model.hotkeys.status, systemImage: model.hotkeys.secureInput ? "lock.trianglebadge.exclamationmark" : "keyboard")
                .foregroundStyle(model.hotkeys.secureInput ? .orange : .secondary)
        } header: { Text("Shortcut") } footer: {
            Text("For Fn / Globe, set System Settings → Keyboard → “Press Globe key to” → Do Nothing.")
        }
        Section("Behavior") {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { value in
                Task { @MainActor in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try await SMAppService.mainApp.unregister() }
                        refreshLoginStatus()
                    } catch { refreshLoginStatus(error: error) }
                }
            })).disabled(!model.servicesEnabled).tint(GoblinBrand.tint)
            if let loginError { Text(loginError).foregroundStyle(.orange) }
            if SMAppService.mainApp.status == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
            Toggle(isOn: $sounds) {
                Text("Feedback sounds")
                Text("Plays once the microphone is actually capturing.")
            }
            .tint(GoblinBrand.tint)
            Toggle(isOn: $pauseMedia) {
                Text("Pause media while dictating")
                Text("Resumes the same player after capture, unless you change playback.")
            }
            .tint(GoblinBrand.tint)
            Toggle("Add a trailing space", isOn: Binding(get: { model.insertion.trailingSpace }, set: { model.insertion.trailingSpace = $0 })).tint(GoblinBrand.tint)
        }
        Section("Text insertion") {
            LabeledContent("Paste last transcript") { KeyCombo(label: "⌘⌥⇧V") }
            LabeledContent("Status") { Text(model.insertion.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            if model.insertion.hasRecoveryClipboard {
                LabeledContent("Clipboard") {
                    Button("Restore previous clipboard") { model.insertion.restorePreviousClipboard() }.disabled(model.insertion.busy)
                }
            }
            LabeledContent("Permissions") { Button("Permissions & onboarding…") { model.permissions.showOnboarding() } }
        }
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }

    private func refreshLoginStatus(error: Error? = nil) {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginError = status == .requiresApproval ? "Allow gob.lin in Login Items to finish enabling launch at login." : error?.localizedDescription
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        Section {
            HStack(spacing: 20) {
                Image(nsImage: GoblinBrand.sprite("goblin-shut")).resizable().interpolation(.none)
                    .frame(width: 128, height: 128).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    GoblinWordmark(size: 44)
                    Text("Native dictation for macOS. Local by default; cloud cleanup is optional.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            LabeledContent("Version") { Text(updates.currentVersion).font(.body.monospaced()).textSelection(.enabled) }
        }
        UpdateSettingsView(updates: updates)
        Section("Data") {
            LabeledContent("Dictations and audio") {
                Button("Open data folder") {
                    if let folder = try? HistoryStore.defaultDirectory() { NSWorkspace.shared.open(folder) }
                }
            }
            LabeledContent("Logs") {
                Button("Open Console") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
            }
        }
        Section {
            if let directory = GoblinBrand.assetDirectory {
                licence("Project licence", "Apache License 2.0", directory.appendingPathComponent("Apache-LICENSE.txt"))
                licence("Third-party notices", "Bundled components", directory.appendingPathComponent("Third-party-notices.md"))
                licence("Workbench", "SIL Open Font License 1.1", directory.appendingPathComponent("Workbench-OFL.txt"))
                licence("VT323", "SIL Open Font License 1.1", directory.appendingPathComponent("VT323-OFL.txt"))
            } else {
                Text("Apache License 2.0 · Workbench and VT323: SIL Open Font License 1.1")
            }
        } header: { Text("Licences") }
    }

    private func licence(_ title: String, _ detail: String, _ url: URL) -> some View {
        LabeledContent {
            Button("View") { NSWorkspace.shared.open(url) }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
