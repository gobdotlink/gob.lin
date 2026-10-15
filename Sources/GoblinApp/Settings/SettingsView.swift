import AppKit
import GoblinCore
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", audio = "Audio", model = "Model", dictionary = "Dictionary"
    case cleanup = "Cleanup", tone = "Tone", history = "History", overlay = "Overlay", diagnostics = "Diagnostics", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "mic"
        case .model: "cpu"
        case .dictionary: "character.book.closed"
        case .cleanup: "wand.and.stars"
        case .tone: "textformat"
        case .history: "clock"
        case .overlay: "rectangle.bottomhalf.inset.filled"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var speechModels: SpeechModelService? = nil

    private var section: SettingsSection { model.settingsSelection ?? .general }

    var body: some View {
        // The sidebar is always there: no toggle, and no collapsing in narrow windows.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $model.settingsSelection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(status: model.status) }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // The page title lives in the toolbar row, level with the traffic lights; the toolbar
            // draws no band of its own, so the case runs to the top of the window.
            Form { sectionContents }
                .formStyle(PlateFormStyle())
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .caseBackground()
                .navigationTitle(section.rawValue)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // Grouped Forms center a ~700pt column in wider windows; capping the width keeps every
        // page on the same margins (System Settings is fixed-width too).
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
        case .cleanup: RewriteSettingsView(defaults: model.defaults, inspectKeychain: model.servicesEnabled,
                                           onSaved: { model.reloadRewriteCredentials(); model.diagnostics.resolve(.settings) },
                                           onFailure: { model.showFailure($0) })
        case .tone: ToneSettingsView()
        case .history: HistorySettingsView(model: model.history, open: { model.openHistory($0) })
        case .overlay: OverlaySettingsView(overlay: model.overlay)
        case .diagnostics: DiagnosticsView(model: model.diagnostics)
        case .about: AboutSettingsView(updates: model.updates, history: model.history)
        }
    }
}

/// Sidebar foot: what gob.lin is doing, as a light and two short lines.
private struct StatusFooter: View {
    let status: AppStatus

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusLight(state: status.light).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title).font(.system(size: 12, weight: .medium))
                Text(status.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("feedbackSoundsEnabled") private var sounds = true
    @AppStorage("audio.pauseMediaWhileDictating") private var pauseMedia = false
    @State private var loginEnabled = false
    @State private var loginError: String?

    private var hotkeys: HotkeyService { model.hotkeys }

    var body: some View {
        Section {
            HStack(spacing: 16) {
                BigKeyCap(label: keycapLabel, globe: hotkeys.shortcut == .fn, light: keyLight)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hotkeys.shortcut == .fn ? "fn / Globe" : hotkeys.shortcut.label).font(.system(size: 15, weight: .semibold))
                    Text("Hold to talk, let go to type. Tap once to keep listening hands-free, and tap again to finish.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ShortcutRecorder(service: hotkeys, showsCurrent: false)
            }
            .padding(.vertical, 6)
            LabeledContent("Quick picks") {
                Picker("Quick picks", selection: Binding(get: { hotkeys.shortcut }, set: { hotkeys.setShortcut($0) })) {
                    Text("fn / Globe").tag(HotkeyShortcut.fn)
                    Text("Right ⌥").tag(HotkeyShortcut.rightOption)
                    Text("⌥ Space").tag(HotkeyShortcut.optionSpace)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(GoblinBrand.moss)
            }
            LabeledContent("Cancel a take") { KeyCap("esc") }
            StatusRow(keyLight, Text(keyStatus))
        } header: { CapsHeader("Talk key") }
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: { value in
                Task { @MainActor in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try await SMAppService.mainApp.unregister() }
                        refreshLoginStatus()
                    } catch { refreshLoginStatus(error: error) }
                }
            })).disabled(!model.servicesEnabled)
            if let loginError {
                StatusRow(.waiting, Text(loginError)) {
                    if SMAppService.mainApp.status == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                }
            }
            Toggle(isOn: $sounds) {
                Text("Click sounds")
                Text("A soft tick once the mic is really listening, and another when it stops.")
            }
            Toggle(isOn: $pauseMedia) {
                Text("Pause media while dictating")
                Text("Picks up where it left off when you're done, unless you changed what's playing.")
            }
            Toggle(isOn: Binding(get: { model.insertion.trailingSpace }, set: { model.insertion.trailingSpace = $0 })) {
                Text("Add a space after each take")
                Text("So the next one doesn't run into this one.")
            }
        } header: { CapsHeader("Behaviour") }
        Section {
            LabeledContent("Paste last dictation again") { KeyCombo(label: "⌥⇧⌘V") }
            StatusRow(insertionLight, Text(model.insertion.status))
            if model.insertion.hasRecoveryClipboard {
                StatusRow(.waiting, Text("Your last dictation is on the clipboard.")) {
                    Button("Restore Previous Clipboard") { model.insertion.restorePreviousClipboard() }.disabled(model.insertion.busy)
                }
            }
            StatusRow(model.permissions.snapshot.ready ? .ready : .waiting,
                      Text("**Permissions** · Microphone, Accessibility")) {
                Button("Open Setup…") { model.permissions.showOnboarding() }
            }
        } header: { CapsHeader("Typing it in") }
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }

    private var keycapLabel: String {
        switch hotkeys.shortcut {
        case .fn: "fn"
        case .rightOption: "⌥"
        default: hotkeys.shortcut.label
        }
    }

    private var keyLight: LightState {
        if hotkeys.secureInput || hotkeys.status == "Waiting for permissions" { return .waiting }
        if hotkeys.status.hasPrefix("Shortcut unavailable") || hotkeys.status.hasPrefix("Choose") { return .problem }
        return .ready
    }

    private var keyStatus: String {
        guard hotkeys.shortcut == .fn, keyLight == .ready else { return hotkeys.status + "." }
        return hotkeys.status + ". Set the Globe key to Do Nothing in Keyboard settings, so I hear it first."
    }

    private var insertionLight: LightState {
        if case .failure = model.insertion.outcome { return .waiting }
        return .ready
    }

    private func refreshLoginStatus(error: Error? = nil) {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginError = status == .requiresApproval ? "Allow gob.lin in Login Items to finish turning this on." : error?.localizedDescription
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var history: HistoryModel
    @State private var totalWords: Int?

    var body: some View {
        Section {
            VStack(spacing: 0) {
                PixelSprite(sprite: .shut, scale: 2)
                GoblinWordmark(size: 48).padding(.top, 10)
                Text("Version \(updates.currentVersion)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .textSelection(.enabled).padding(.top, 8)
                GoblinTagline(size: 22, cursor: true).padding(.top, 14)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        Section {
            Text("Lives in your menu bar. Listens only while you hold the key. Turns speech into text on this Mac, and only sends text out if you turn on Cleanup. Has strong opinions about “um”.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                stat(totalWords.map { $0.formatted() } ?? "—", "words yapped")
                stat(history.counts.total.formatted(), "dictations")
                stat("0 s", "of audio uploaded, ever")
            }
        }
        Section {
            LabeledContent("Recognition", value: "Parakeet TDT v3, on this Mac")
            LabeledContent("Runs on", value: "Core ML")
            LabeledContent("Languages", value: "25 European languages")
            LabeledContent("Network", value: "Not needed. Cleanup is opt-in.")
        } header: { CapsHeader("Specs") }
        UpdateSettingsView(updates: updates)
        Section {
            LabeledContent("Dictations and audio") {
                Button("Open Data Folder") {
                    if let folder = try? HistoryStore.defaultDirectory() { NSWorkspace.shared.open(folder) }
                }
            }
            LabeledContent("Logs") {
                Button("Open Console") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
            }
        } header: { CapsHeader("Data") }
        Section {
            if let directory = GoblinBrand.assetDirectory {
                licence("Project licence", "Apache License 2.0", directory.appendingPathComponent("Apache-LICENSE.txt"))
                licence("Third-party notices", "Bundled components", directory.appendingPathComponent("Third-party-notices.md"))
                licence("Workbench", "SIL Open Font License 1.1", directory.appendingPathComponent("Workbench-OFL.txt"))
                licence("VT323", "SIL Open Font License 1.1", directory.appendingPathComponent("VT323-OFL.txt"))
            } else {
                Text("Apache License 2.0 · Workbench and VT323: SIL Open Font License 1.1")
            }
        } header: { CapsHeader("Licences") }
        .task(id: history.revision) {
            totalWords = try? await history.store?.insights().totalWords
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
