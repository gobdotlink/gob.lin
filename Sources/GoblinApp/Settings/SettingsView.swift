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
        case .diagnostics: "exclamationmark.bubble"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                GoblinWordmark().fixedSize(horizontal: true, vertical: false).scaleEffect(0.72, anchor: .leading).frame(height: 70).padding(.horizontal, 18)
                List(SettingsSection.allCases, selection: $model.settingsSelection) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
                Text("LOCAL BY DEFAULT").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(18)
            }.background(GoblinBrand.background).navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch model.settingsSelection ?? .general {
                case .dictionary, .rewrite, .overlay, .diagnostics: sectionContents
                default: ScrollView { sectionContents }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GoblinBrand.surface)
        }
        .tint(GoblinBrand.accent).preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 620)
        .defaultAppStorage(model.defaults)
    }

    @ViewBuilder
    private var sectionContents: some View {
        switch model.settingsSelection ?? .general {
        case .general: GeneralSettingsView(model: model)
        case .audio: AudioSettingsView(permissions: model.permissions, preview: model.audioPreview)
        case .model:
            VStack(alignment: .leading, spacing: 18) {
                Text("Speech model").font(.largeTitle.bold())
                LabeledContent("Candidate", value: "Parakeet TDT v3")
                Label("Engine selection follows the benchmark", systemImage: "clock")
                Text("No speech model is downloaded or loaded yet. Dictation will become available after the speech-engine benchmark and audio-capture integration.")
                    .foregroundStyle(.secondary)
                Picker("Model", selection: .constant("Parakeet TDT v3")) { Text("Parakeet TDT v3").tag("Parakeet TDT v3") }.disabled(true)
            }.padding(28)
        case .dictionary: DictionarySettingsView(model: model.dictionary)
        case .rewrite: RewriteSettingsView(defaults: model.defaults, inspectKeychain: model.servicesEnabled,
                                               onSaved: { model.refreshConfiguration(); model.diagnostics.resolve(.settings) },
                                               onFailure: { model.showFailure($0) })
        case .tone: ToneSettingsView()
        case .history: HistorySettingsView(history: model.history)
        case .overlay: OverlaySettingsView(overlay: model.overlay)
        case .diagnostics: DiagnosticsView(model: model.diagnostics)
        case .about: AboutSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("feedbackSoundsEnabled") private var sounds = true
    @State private var loginEnabled = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General").font(.largeTitle.bold())
            Text("Your voice, wherever your cursor is.").foregroundStyle(.secondary)
            ShortcutRecorder(service: model.hotkeys)
            HStack {
                Button("Fn / Globe") { model.hotkeys.setShortcut(.fn) }
                Button("Right Option") { model.hotkeys.setShortcut(.rightOption) }
                Button("Option + Space") { model.hotkeys.setShortcut(.optionSpace) }
            }
            LabeledContent("Mode", value: "Hold to talk · tap to toggle")
            LabeledContent("Cancel", value: "Escape, while recording")
            Text("For Fn / Globe, set Keyboard → Press Globe key to → Do Nothing.").font(.callout).foregroundStyle(.secondary)
            Label(model.hotkeys.status, systemImage: model.hotkeys.secureInput ? "lock.trianglebadge.exclamationmark" : "keyboard")
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { value in
                Task { @MainActor in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try await SMAppService.mainApp.unregister() }
                        refreshLoginStatus()
                    } catch { refreshLoginStatus(error: error) }
                }
            })).disabled(!model.servicesEnabled)
            if let loginError { Text(loginError).foregroundStyle(.orange) }
            if SMAppService.mainApp.status == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
            Toggle("Feedback sounds", isOn: $sounds)
            Text("Sounds play with the dictation capture flow after the first microphone buffer.").font(.caption).foregroundStyle(.secondary)
            Toggle("Add a trailing space", isOn: Binding(get: { model.insertion.trailingSpace }, set: { model.insertion.trailingSpace = $0 }))
            Text("Paste last transcript: ⌘⌥⇧V").font(.callout).foregroundStyle(.secondary)
            Text(model.insertion.status).foregroundStyle(.secondary)
            if model.insertion.hasRecoveryClipboard { Button("Restore previous clipboard") { model.insertion.restorePreviousClipboard() }.disabled(model.insertion.busy) }
            Button("Permissions & onboarding…") { model.permissions.showOnboarding() }
        }.padding(28)
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }

    private func refreshLoginStatus(error: Error? = nil) {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginError = status == .requiresApproval ? "Allow gob.lin in Login Items to finish enabling launch at login." : error?.localizedDescription
    }
}

private struct HistorySettingsView: View {
    @ObservedObject var history: HistoryModel
    @State private var count: Int?
    @State private var days = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("History retention").font(.largeTitle.bold())
            Text("Raw text, final text and original audio stay recoverable. Starred dictations are always kept.").foregroundStyle(.secondary)
            Picker("Unstarred entries", selection: $count) {
                Text("Keep all").tag(Int?.none)
                Text("Keep none (starred only)").tag(Optional(0))
                ForEach([100, 500, 1000, 5000], id: \.self) { Text("Keep latest \($0)").tag(Optional($0)) }
                if let count, ![0, 100, 500, 1000, 5000].contains(count) { Text("Keep latest \(count)").tag(Optional(count)) }
            }
            Picker("Age", selection: $days) {
                Text("No age limit").tag(0)
                ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
            }
            Text("Applying a shorter policy deletes matching unstarred entries and their audio.").font(.callout).foregroundStyle(.secondary)
            Button("Apply retention") { Task { await history.saveRetention(HistoryRetention(maximumUnstarredCount: count, maximumAgeDays: days == 0 ? nil : days)) } }
            if let error = history.errorMessage { Text(error).foregroundStyle(.orange) }
        }.padding(28).onAppear { copyRetention() }
        .onChange(of: history.retention) { _, _ in copyRetention() }
    }

    private func copyRetention() {
        count = history.retention.maximumUnstarredCount
        days = history.retention.maximumAgeDays ?? 0
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GoblinWordmark()
            LabeledContent("Version", value: GoblinMetadata.version)
            Text("Native dictation for macOS. Local by default; cloud cleanup is optional.").foregroundStyle(.secondary)
            Button("Open data folder") {
                if let folder = try? HistoryStore.defaultDirectory() { NSWorkspace.shared.open(folder) }
            }
            Button("Open logs") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
            Text("Apache License 2.0 · Workbench and VT323: SIL Open Font License 1.1").font(.callout)
            if let directory = GoblinBrand.assetDirectory {
                Button("Project licence") { NSWorkspace.shared.open(directory.appendingPathComponent("Apache-LICENSE.txt")) }
                Button("Third-party notices") { NSWorkspace.shared.open(directory.appendingPathComponent("Third-party-notices.md")) }
                Button("Workbench licence") { NSWorkspace.shared.open(directory.appendingPathComponent("Workbench-OFL.txt")) }
                Button("VT323 licence") { NSWorkspace.shared.open(directory.appendingPathComponent("VT323-OFL.txt")) }
            }
        }.padding(28)
    }
}
