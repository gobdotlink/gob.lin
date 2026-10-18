import AppKit
import GoblinCore
import GoblinEngines
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case insights = "Insights", history = "History"
    case general = "General", audio = "Audio", model = "Model", dictionary = "Dictionary"
    case cleanup = "Cleanup", tone = "Tone", overlay = "Overlay", diagnostics = "Diagnostics", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .insights: "chart.bar.xaxis"
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
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SettingsSection.allCases) { item in
                        if item == .general { Divider().padding(.vertical, 10).padding(.horizontal, 6) }
                        SidebarRow(title: item.rawValue, selected: item == section, action: { model.settingsSelection = item }) {
                            Image(systemName: item.symbol)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 4)
            }
            .arrowKeySelection(SettingsSection.allCases, selection: $model.settingsSelection)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(model: model) }
            // The column width alone doesn't hold; the content's own width pins the split item.
            .frame(width: 200)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // The title is a toolbar item, so the toolbar stays and the sidebar runs up behind the traffic
            // lights. The toolbar draws no band, so the case reaches the top of the window.
            Group {
                switch section {
                case .history: HistoryView(model: model)
                case .insights:
                    InsightsView(history: model.history)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .leading)
                default:
                    Form { sectionContents }
                        .formStyle(PlateFormStyle())
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .caseBackground()
                .navigationTitle(section.rawValue)
                .toolbar(removing: .title)
                .toolbar { if section != .history { ToolbarTitle(title: section.rawValue) } }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // With the toolbar background hidden, scrolled rows would show through the title; the hard
        // edge cuts them off at the toolbar instead.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .frame(minWidth: 970, minHeight: 620)
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
        case .cleanup: RewriteSettingsView(defaults: model.defaults, inspectCredentials: model.servicesEnabled,
                                           onSaved: { model.reloadRewriteCredentials(); model.diagnostics.resolve(.settings) },
                                           onFailure: { model.showFailure($0) })
        case .tone: ToneSettingsView()
        case .history, .insights: EmptyView()
        case .overlay: OverlaySettingsView(overlay: model.overlay)
        case .diagnostics: DiagnosticsView(model: model.diagnostics)
        case .about: AboutSettingsView(updates: model.updates, history: model.history)
        }
    }
}

/// Sidebar foot: what gob.lin is doing, as a light and two short lines.
private struct StatusFooter: View {
    let model: AppModel
    @ObservedObject private var diagnostics: DiagnosticsModel
    @ObservedObject private var speechModels: SpeechModelService

    init(model: AppModel) {
        self.model = model
        _diagnostics = ObservedObject(wrappedValue: model.diagnostics)
        _speechModels = ObservedObject(wrappedValue: model.speechModels)
    }

    var body: some View {
        let status = model.status
        return HStack(alignment: .top, spacing: 9) {
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
    let model: AppModel
    @ObservedObject private var hotkeys: HotkeyService
    @ObservedObject private var insertion: TextInsertionService
    @ObservedObject private var permissions: PermissionModel
    @AppStorage("feedbackSoundsEnabled") private var sounds = true
    @AppStorage("audio.pauseMediaWhileDictating") private var pauseMedia = false
    /// The last status read, so a reopened page shows it straight away.
    @MainActor private static var loginStatus: SMAppService.Status?
    @State private var loginStatus = GeneralSettingsView.loginStatus
    @State private var loginError: String?

    init(model: AppModel) {
        self.model = model
        _hotkeys = ObservedObject(wrappedValue: model.hotkeys)
        _insertion = ObservedObject(wrappedValue: model.insertion)
        _permissions = ObservedObject(wrappedValue: model.permissions)
    }

    var body: some View {
        Section {
            // Three or more caps get their own row instead of squeezing the text.
            let stacked = hotkeys.shortcut.keys.count > 2
            VStack(alignment: .leading, spacing: 14) {
                if stacked { TalkKeyCaps(shortcut: hotkeys.shortcut, light: keyLight) }
                HStack(spacing: 16) {
                    if !stacked { TalkKeyCaps(shortcut: hotkeys.shortcut, light: keyLight) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hotkeys.shortcut.title).font(.system(size: 15, weight: .semibold))
                        Text("Hold to talk, let go to type. Tap once to keep listening hands-free, and tap again to finish.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    ShortcutRecorder(service: hotkeys, showsCurrent: false)
                }
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
            Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled }, set: { value in
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
                    if loginStatus == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
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
            Toggle(isOn: $insertion.trailingSpace) {
                Text("Add a space after each take")
                Text("So the next one doesn't run into this one.")
            }
            Toggle(isOn: $insertion.watchEdits) {
                Text("Watch edits after paste")
                Text("Watch for 30 seconds and show corrections in History. Secure fields and password managers are excluded.")
            }
        } header: { CapsHeader("Behaviour") }
        Section {
            Picker("Insert dictation into", selection: $insertion.destination) {
                Text("Current text field").tag(DictationDestination.currentField)
                Text("Where I started").tag(DictationDestination.originalField)
            }
            .pickerStyle(.menu)
            Text(insertion.destination == .currentField
                 ? "Paste where your cursor is when the transcript is ready."
                 : "Insert where you started dictation, even after switching apps. If it can't land there, it stays ready for manual paste.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent { KeyCombo(label: "⌥⇧⌘V") } label: {
                Text("Paste last dictation again")
                Text("Choose a text field and use this shortcut to paste your last transcript again.")
            }
            StatusRow(insertionLight, Text(insertion.status))
            if insertion.hasRecoveryClipboard {
                StatusRow(.waiting, Text("Your last dictation is on the clipboard.")) {
                    Button("Restore Previous Clipboard") { insertion.restorePreviousClipboard() }.disabled(insertion.busy)
                }
            }
            StatusRow(permissions.snapshot.ready ? .ready : .waiting,
                      Text("**Permissions** · Microphone, Accessibility")) {
                Button("Open Setup…") { permissions.showOnboarding() }
            }
        } header: { CapsHeader("Typing it in") }
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
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
        if case .failure = insertion.outcome { return .waiting }
        return .ready
    }

    private func refreshLoginStatus(error: Error? = nil) {
        Task {
            // A round trip to the service manager: off the main thread, so Settings opens without waiting.
            let status = await Task.detached { SMAppService.mainApp.status }.value
            Self.loginStatus = status
            loginStatus = status
            loginError = status == .requiresApproval ? "Allow gob.lin in Login Items to finish turning this on." : error?.localizedDescription
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var history: HistoryModel
    @State private var totalWords: Int?
    @State private var modelSize: String?

    var body: some View {
        Section {
            VStack(spacing: 0) {
                PixelSprite(sprite: .shut, scale: 2)
                GoblinWordmark(size: 48).padding(.top, 10)
                Text(versionLine).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .textSelection(.enabled).padding(.top, 8)
                GoblinTagline(size: 22, cursor: true).padding(.top, 14)
            }
            .frame(maxWidth: .infinity).padding(.top, 4)
        }
        .containerValue(\.plateless, true)
        Section {
            // Equal-height panels, like the two columns of a grid.
            HStack(alignment: .top, spacing: 12) {
                Plate(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Lives in your menu bar. Listens only while you hold the key. Turns speech into text on this Mac, and only sends text out if you turn on Cleanup. Has strong opinions about “um”.")
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        Hairline().padding(.top, 14)
                        HStack(alignment: .top) {
                            stat(totalWords.map { $0.formatted() } ?? "—", "words yapped")
                            stat(history.counts.total.formatted(), "dictations")
                            stat("0 s", "audio uploaded")
                        }
                        .padding(.top, 12)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                Plate(padding: 0) {
                    VStack(spacing: 0) {
                        spec("Recognition", "Parakeet TDT v3, on this Mac")
                        Hairline()
                        spec("Runs on", "Core ML")
                        Hairline()
                        spec("Model size", modelSize ?? "—")
                        Hairline()
                        spec("Languages", "25 European languages")
                        Hairline()
                        spec("Network", "Not needed. Cleanup is opt-in.")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .task(id: history.revision) { totalWords = try? await history.store?.insights().totalWords }
            .task { modelSize = await Self.modelSize() }
        }
        .containerValue(\.plateless, true)
        Section {
            HStack(spacing: 8) {
                Button("Check for Updates…") { updates.check() }.disabled(updates.isBusy)
                Menu("Licences") {
                    if let directory = GoblinBrand.assetDirectory {
                        Button("gob.lin · Apache License 2.0") { NSWorkspace.shared.open(directory.appendingPathComponent("Apache-LICENSE.txt")) }
                        Button("Third-Party Notices") { NSWorkspace.shared.open(directory.appendingPathComponent("Third-party-notices.md")) }
                        Button("Workbench · SIL Open Font License 1.1") { NSWorkspace.shared.open(directory.appendingPathComponent("Workbench-OFL.txt")) }
                        Button("VT323 · SIL Open Font License 1.1") { NSWorkspace.shared.open(directory.appendingPathComponent("VT323-OFL.txt")) }
                    }
                }
                .menuIndicator(.hidden).fixedSize()
                Button("Data Folder", systemImage: "folder") {
                    if let folder = try? HistoryStore.defaultDirectory() { NSWorkspace.shared.open(folder) }
                }
                Spacer()
                Text("Apache 2.0 · fonts under OFL 1.1").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .containerValue(\.plateless, true)
        // Only when there's something to do: an update to install, a failure, or a token to save.
        UpdateSettingsView(updates: updates)
    }

    private var versionLine: String {
        let version = "Version \(updates.currentVersion)"
        switch updates.phase {
        case .upToDate: return version + " · up to date"
        case .checking: return version + " · checking…"
        case .available(let next): return version + " · v\(next) is out"
        default: return version
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 8)
    }

    /// The downloaded model's size on disk, measured rather than quoted.
    private static func modelSize() async -> String? {
        await Task.detached(priority: .utility) { measure(ParakeetSpeechEngine.defaultModelDirectory) }.value
    }

    nonisolated private static func measure(_ directory: URL) -> String? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var bytes: Int64 = 0
        while let file = files.nextObject() as? URL {
            bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return bytes > 0 ? "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
