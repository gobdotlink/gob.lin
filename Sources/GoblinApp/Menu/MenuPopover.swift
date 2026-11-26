import AppKit
import GoblinCore
import SwiftUI

/// The popover behind the menu-bar icon: everything used daily, one click deep.
/// Top to bottom: what's happening, what you said, what you recorded, then the settings.
/// Each module observes only the models it shows, so a meter tick or a hovered row redraws
/// that module rather than the whole popover.
struct MenuPopover: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var eyes = GoblinEyes()

    var body: some View {
        VStack(spacing: 8) {
            PopoverHeader(model: model, eyes: eyes)
            PopoverNotices(model: model)
            PopoverMeeting(meetings: model.meetings)
            PopoverReadyMeeting(model: model)
            PopoverRecents(model: model)
            PopoverMeetingsList(model: model)
            VStack(spacing: 2) {
                PopoverMicrophone(preview: model.audioPreview, microphones: model.microphones) { dismiss.then { model.openSettings(.audio) } }
                PopoverCleanup(model: model)
                PopoverTone()
            }
            .padding(.horizontal, PopoverModule.inset - PopoverModule.bleed).padding(.vertical, 6)
            .moduleBackground(padded: false)
            PopoverFooter(model: model)
        }
        .padding(8)
        .frame(width: 360)
        // The gaps between modules count too, so the eyes don't snap back between rows.
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .global, perform: eyes.follow)
        .onAppear { model.closePopover = { dismiss() } }
        .onDisappear {
            model.closePopover = nil
            eyes.gaze = .ahead
        }
    }
}

extension DismissAction {
    /// Closes the popover and runs the action straight away: windows activate gob.lin themselves.
    func then(_ action: () -> Void) {
        callAsFunction()
        action()
    }
}

// MARK: Header

private struct PopoverHeader: View {
    @ObservedObject var model: AppModel
    let eyes: GoblinEyes
    @ObservedObject private var diagnostics: DiagnosticsModel
    @ObservedObject private var speechModels: SpeechModelService
    @ObservedObject private var hotkeys: HotkeyService
    @ObservedObject private var dictionary: DictionaryModel
    // The ⋯ menu's titles and enabled states come from these two.
    @ObservedObject private var permissions: PermissionModel
    @ObservedObject private var updates: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, eyes: GoblinEyes) {
        self.model = model
        self.eyes = eyes
        _diagnostics = ObservedObject(wrappedValue: model.diagnostics)
        _speechModels = ObservedObject(wrappedValue: model.speechModels)
        _hotkeys = ObservedObject(wrappedValue: model.hotkeys)
        _dictionary = ObservedObject(wrappedValue: model.dictionary)
        _permissions = ObservedObject(wrappedValue: model.permissions)
        _updates = ObservedObject(wrappedValue: model.updates)
    }

    var body: some View {
        let status = model.status
        return HStack(spacing: 10) {
            if diagnostics.hasWarning { PixelSprite(sprite: .side, scale: 1) } else { GazingGoblin(eyes: eyes) }
            VStack(alignment: .leading, spacing: 5) {
                GoblinWordmark(size: 24)
                HStack(spacing: 6) {
                    StatusLight(state: status.light, size: 7)
                    if status.light == .ready, model.mascotState == .idle {
                        Text("Ready · hold")
                        KeyCombo(label: hotkeys.shortcut == .fn ? "fn" : hotkeys.shortcut.label, small: true)
                        Text("to talk")
                    } else {
                        // One line: the detail drops off before the sentence wraps under the wordmark.
                        ViewThatFits(in: .horizontal) {
                            Text(model.mascotState == .recording ? "Listening…" : model.mascotState == .transcribing ? "Writing it out…"
                                 : "\(status.title) · \(status.detail)")
                            Text(status.title)
                        }
                        .lineLimit(1).help(status.detail)
                    }
                }
                .font(.status).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                if dictionary.suggestsTerms, !dictionary.suggestions.isEmpty {
                    let count = dictionary.suggestions.count
                    Button("\(count) new \(count == 1 ? "word" : "words")\(dictionary.suggestionPlace.map { " for \($0.name)" } ?? "")") {
                        dismiss.then { model.openSettings(.dictionary) }
                    }
                    .buttonStyle(.plain).font(.status).foregroundStyle(GoblinBrand.mossText).contentShape(.rect)
                }
            }
            Spacer(minLength: 6)
            Menu {
                ForEach(Array(model.moreMenu.enumerated()), id: \.offset) { index, section in
                    if index > 0 { Divider() }
                    ForEach(section, id: \.title) { command in
                        Button(command.title) { dismiss.then(command.perform) }
                            .keyboardShortcut(command.shortcut).disabled(!command.enabled)
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28).background(.quaternary, in: Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 2)
    }
}

// MARK: Notices

/// Problems, the clipboard recovery notice and a waiting update: only there when needed.
private struct PopoverNotices: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var diagnostics: DiagnosticsModel
    @ObservedObject private var insertion: TextInsertionService
    @ObservedObject private var updates: UpdateChecker
    @ObservedObject private var history: HistoryModel
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _diagnostics = ObservedObject(wrappedValue: model.diagnostics)
        _insertion = ObservedObject(wrappedValue: model.insertion)
        _updates = ObservedObject(wrappedValue: model.updates)
        // Pending saves block installing an update.
        _history = ObservedObject(wrappedValue: model.history)
    }

    var body: some View {
        ForEach(diagnostics.warnings, id: \.area) { problem($0) }
        if insertion.hasRecoveryClipboard {
            moduleRow(symbol: "doc.on.clipboard", attention: true, title: "Your last dictation is on the clipboard",
                      detail: "What you'd copied before is kept.") {
                Button("Restore Previous Clipboard") { insertion.restorePreviousClipboard() }.disabled(insertion.busy)
            }
            .moduleBackground(attention: true)
        }
        if let version = updates.availableVersion {
            HStack(spacing: 10) {
                circle("arrow.down.circle", on: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("gob.lin \(version) is ready").font(.row.weight(.semibold))
                    Text("Restarting takes a second.").font(.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button("Restart") { updates.install() }
                    .prominent().buttonBorderShape(.capsule).disabled(updates.isBusy || !model.canInstallUpdate)
            }
            .moduleBackground()
        }
    }

    private func problem(_ failure: DiagnosticFailure) -> some View {
        moduleRow(symbol: symbol(for: failure.area), attention: true, title: failure.plainWords.title, detail: failure.plainWords.detail) {
            if let fix = model.fix(for: failure) { Button(fix.title) { dismiss.then(fix.action) } }
        }
        .moduleBackground(attention: true)
    }

    private func symbol(for area: DiagnosticArea) -> String {
        switch area {
        case .microphone: "mic.slash"
        case .permissions: "hand.raised"
        case .hotkeys: "keyboard"
        case .secureInput: "lock"
        case .model: "cpu"
        case .rewrite: "wand.and.stars"
        case .insertion: "text.cursor"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .trimming, .settings, .application: "exclamationmark.triangle"
        }
    }
}

// MARK: Microphone

/// One row: the microphone in use opens the picker, and Hold to Test swaps its name for the level while held.
/// A line appears under it only while there is something to say about the mic.
private struct PopoverMicrophone: View {
    @ObservedObject var preview: AudioPreviewModel
    @ObservedObject var microphones: MicrophonesModel
    let editRanking: () -> Void
    @State private var levels = Array(repeating: 0.0, count: 16)
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    // In ranked order, the line included; picking one moves it above everything connected now.
                    Picker("Microphone", selection: Binding(get: { selection }, set: { microphones.pick($0) })) {
                        ForEach(microphones.ranking.entries) { entry in
                            if entry.isSystemDefault {
                                Text("Follow System Default").tag("")
                            } else if let device = microphones.device(entry.uid), device.kind != .virtual {
                                Text(device.silencedByLid ? "\(device.name) · Lid Closed" : device.name).tag(device.uid)
                                    .disabled(device.silencedByLid)
                            }
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    let others = ranked.filter { $0.kind == .virtual }
                    if !others.isEmpty {
                        Menu("Other Devices") {
                            ForEach(others) { device in Button(device.name) { microphones.pick(device.uid) } }
                        }
                    }
                    Divider()
                    Button("Edit Ranking…", action: editRanking)
                } label: {
                    HStack(spacing: 10) {
                        circle("mic", on: testing, size: SettingRow.circle)
                        Text("Microphone").fixedSize()
                        // A muted or zero-volume mic has no level to show, and the warning under the row doesn't name it.
                        if testing, preview.silenceNotice == nil { meter } else { settingValue(deviceName) }
                    }
                    .padding(.leading, PopoverModule.bleed).frame(maxHeight: .infinity).contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Microphone, \(deviceName)")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                // As wide as its longer title, so the row doesn't shift when the test starts.
                Text("Hold to Test").hidden().overlay { Text(testing ? "Testing" : "Hold to Test") }
                    .font(.status.weight(.semibold))
                    .foregroundStyle(testing ? .white : .primary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(testing ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.quaternary), in: Capsule())
                    .contentShape(Capsule())
                    // The mic opens only while the button is held, so the system's orange dot stays honest.
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}) { pressing in
                        if pressing { startTest() } else { stopTest() }
                    }
                    .help("Hold to check your mic. Nothing is recorded or saved.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Hold to test the microphone")
                    .accessibilityValue(testing ? "Level only. Nothing is recorded or saved." : "")
            }
            .padding(.trailing, PopoverModule.bleed).frame(height: SettingRow.height)
            if let line = preview.silenceNotice ?? preview.error ?? standIn {
                Text(line).font(.meta).lineLimit(1)
                    .foregroundStyle(preview.silenceNotice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .padding(.leading, PopoverModule.bleed + SettingRow.circle + 10).padding(.trailing, PopoverModule.bleed).padding(.bottom, 7)
            }
        }
        .modifier(SettingRow())
        .onChange(of: preview.level) { _, level in levels = Array((levels + [level]).suffix(levels.count)) }
        // A microphone arriving or leaving mid-test moves the test with it.
        .onChange(of: microphones.choice) { if testing { preview.start(ranking: microphones.ranking) } }
        .onDisappear { if testing { stopTest() } }
    }

    private var meter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(level > 0.02 ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.tertiary))
                    .frame(width: 3, height: 3 + level * 17)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing).frame(height: 20)
        .accessibilityHidden(true)
    }

    private var deviceName: String { microphones.inUse?.name ?? "No Microphone" }

    private var ranked: [InputDevice] { microphones.ranking.entries.compactMap { microphones.device($0.uid) } }

    private var selection: String {
        guard let choice = microphones.choice else { return "" }
        return choice.viaSystemDefault ? "" : choice.uid
    }

    /// Why the microphone in use isn't the favourite, so a stand-in is never a mystery.
    /// During a test the line names the mic instead, because the level has taken the name's place.
    private var standIn: String? {
        guard let passed = microphones.passedOver else { return nil }
        if testing { return "Testing \(deviceName)." }
        return passed.lidClosed ? "Using this while the lid is closed." : "Using this until \(passed.entry.name) connects."
    }

    private func startTest() {
        guard !testing else { return }
        testing = true
        levels = Array(repeating: 0, count: levels.count)
        preview.start(ranking: microphones.ranking)
    }

    private func stopTest() {
        testing = false
        preview.stop()
    }
}

// MARK: Cleanup and tone

/// The circle switches cleanup on or off; the rest of the row opens the level menu.
private struct PopoverCleanup: View {
    /// Observed for refreshConfiguration, which announces saved cleanup settings.
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = RewriteSettingsStore.load(defaults: model.defaults)
        let on = settings.enabled && settings.cleanup != .none
        return HStack(spacing: 0) {
            Button { toggleCleanup(settings) } label: {
                circle("wand.and.stars", on: on, size: SettingRow.circle)
                    .padding(.leading, PopoverModule.bleed).padding(.trailing, 10).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(on ? "Turn cleanup off" : "Turn cleanup on")
            Menu {
                Picker("Level", selection: Binding(get: { settings.cleanup }, set: { level in
                    var changed = settings
                    changed.cleanup = level
                    save(changed)
                })) {
                    ForEach(RewriteCleanup.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
                Divider()
                Button("Cleanup Settings…") { dismiss.then { model.openSettings(.cleanup) } }
            } label: {
                HStack(spacing: 10) {
                    Text("Cleanup").fixedSize()
                    settingValue(on ? "\(settings.cleanup.title) · \(settings.provider.title)" : "Off")
                }
                .padding(.trailing, PopoverModule.bleed).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .frame(height: SettingRow.height)
        .modifier(SettingRow())
    }

    private func toggleCleanup(_ settings: RewriteSettings) {
        var changed = settings
        if settings.enabled && settings.cleanup != .none { changed.enabled = false; save(changed); return }
        // Turning it on needs a model and, for remote providers, a saved key; Settings explains what's missing.
        let local = (settings.provider.runsOnDevice && OnDeviceCleanup.availability == .available) || ["localhost", "127.0.0.1", "[::1]", "::1"].contains((try? settings.endpoint())?.host ?? "")
        let hasKey = local || (model.servicesEnabled && (try? RewriteKeyStore.load(for: settings, defaults: model.defaults))?.isEmpty == false)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasKey else {
            dismiss.then { model.openSettings(.cleanup) }
            return
        }
        changed.enabled = true
        if changed.cleanup == .none { changed.cleanup = .light }
        save(changed)
    }

    private func save(_ settings: RewriteSettings) {
        do {
            try RewriteSettingsStore.save(settings, defaults: model.defaults)
            model.reloadRewriteCredentials()
        } catch { model.showFailure(.settingsSaveFailed) }
    }
}

/// The whole row opens the tone menu.
private struct PopoverTone: View {
    @AppStorage(DictationTone.preferenceKey) private var toneRaw = DictationTone.formal.rawValue

    var body: some View {
        let selected = DictationTone(rawValue: toneRaw) ?? .formal
        return Menu {
            Picker("Tone", selection: $toneRaw) {
                ForEach(DictationTone.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 10) {
                circle("textformat", on: false, size: SettingRow.circle)
                Text("Tone").fixedSize()
                settingValue(selected.title)
            }
            .padding(.horizontal, PopoverModule.bleed).frame(height: SettingRow.height)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .modifier(SettingRow())
    }
}

// MARK: Recents

/// Four rows' worth of space whatever the search finds, so typing never resizes the popover.
private struct PopoverRecents: View {
    let model: AppModel
    @ObservedObject private var history: HistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recent: [HistoryEntry] = []
    @FocusState private var searching: Bool

    init(model: AppModel) {
        self.model = model
        _history = ObservedObject(wrappedValue: model.history)
    }

    private struct RecentQuery: Equatable { var text: String; var revision: Int }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                CapsHeader("Dictations")
                Spacer(minLength: 8)
                PasteLastButton(model: model)
            }
            .padding(.horizontal, PopoverModule.bleed).frame(height: PopoverModule.header).padding(.bottom, 2)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(history.counts.total > 0 ? "Search \(history.counts.total.formatted()) dictations" : "Search dictations", text: $query)
                    .textFieldStyle(.plain).focused($searching)
                Text("⌘F").font(.meta).foregroundStyle(.tertiary)
            }
            .background { Button("Search") { searching = true }.keyboardShortcut("f").hidden() }
            .padding(.horizontal, 9).frame(height: 30)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.horizontal, PopoverModule.bleed).padding(.bottom, 4)
            VStack(spacing: 2) {
                if recent.isEmpty {
                    Text(query.isEmpty ? "Your dictations show up here." : "Nothing matches “\(query)”.")
                        .font(.status).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, PopoverModule.bleed)
                }
                ForEach(recent) { entry in
                    RecentRow(entry: entry, open: { dismiss.then { model.openHistory(.all, focus: entry.id) } }, star: {
                        Task { await history.setStarred(!entry.starred, entry: entry); await reload() }
                    })
                }
            }
            .frame(height: 4 * 42, alignment: .top)
            menuItem("All History", chevron: true, inset: PopoverModule.bleed) { dismiss.then { model.openHistory() } }
        }
        // Every row's words start 12 pt in, like the other modules; hover fills bleed 6 pt past them.
        .padding(.horizontal, PopoverModule.inset - PopoverModule.bleed).padding(.top, 6).padding(.bottom, 8)
        .moduleBackground(padded: false)
        .task(id: RecentQuery(text: query, revision: history.revision)) { await reload() }
    }

    private func reload() async {
        recent = (try? await history.store?.entries(matching: query, limit: 4)) ?? []
    }
}

/// The last dictation again, beside the list it comes from. The shortcut works from anywhere.
private struct PasteLastButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(action: paste) {
            HStack(spacing: 5) {
                Text("Paste Last Dictation")
                    .foregroundStyle(model.canPasteLastTranscript ? AnyShapeStyle(GoblinBrand.mossText) : AnyShapeStyle(.tertiary))
                Text("⌥⇧⌘V").foregroundStyle(.tertiary)
            }
            .font(.status).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!model.canPasteLastTranscript)
    }

    /// Hands focus back to the app the person was in first, so the paste lands there rather than in gob.lin.
    private func paste() {
        dismiss()
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.pasteLastTranscript() }
    }
}

/// One footer row. Local totals use retained history, independently of the recent-search query.
private struct PopoverInsights: View {
    @ObservedObject var history: HistoryModel
    let open: () -> Void
    @State private var insights: HistoryInsights?
    @State private var unavailable = false
    @State private var refreshID = UUID()

    private struct Request: Equatable { var revision: Int; var refresh: UUID }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text("Insights")
                Spacer(minLength: 4)
                Text(summary).font(.status).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if let insights {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(insights.days) { day in
                            RoundedRectangle(cornerRadius: Radius.tiny)
                                .fill(GoblinBrand.moss.opacity(day.words > 0 ? 1 : 0.2))
                                .frame(width: 4, height: max(3, 14 * Double(day.words) / Double(max(1, insights.days.map(\.words).max() ?? 0))))
                        }
                    }
                    .frame(height: 14, alignment: .bottom)
                    .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PopoverModule.inset).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel("Insights")
        .accessibilityValue(summary)
        .help("Open Insights · activity over the last seven days")
        .task(id: Request(revision: history.revision, refresh: refreshID)) {
            do {
                guard let store = history.store else { throw HistoryError.database("History is unavailable") }
                let now = Date(), calendar = Calendar.current
                let firstChartDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!)
                let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
                let result = try await store.insights(now: now, week: now, calendar: calendar, since: min(firstChartDay, weekStart))
                try Task.checkCancellation()
                insights = result
                unavailable = false
            } catch {
                guard !Task.isCancelled else { return }
                insights = nil
                unavailable = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refreshID = UUID() }
    }

    private var summary: String {
        if let insights { return "\(insights.weekWords.formatted()) words this week" }
        return unavailable ? "Insights unavailable" : "Loading insights…"
    }
}

/// Click a row to open it in History; hover shows copy and star.
private struct RecentRow: View {
    let entry: HistoryEntry
    let open: () -> Void
    let star: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundleIdentifier: entry.targetBundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.finalText.isEmpty ? "Empty dictation" : entry.finalText).lineLimit(1)
                Text("\(entry.targetApplicationName ?? "Unknown app") · \(entry.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                Button(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.fill" : "star", action: star)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if entry.starred {
                Image(systemName: "star.fill").foregroundStyle(GoblinBrand.candle).accessibilityLabel("Starred")
            }
        }
        .font(.row)
        .padding(.vertical, 5).padding(.horizontal, PopoverModule.bleed)
        .frame(height: 40)
        .background(hovered ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }
}

// MARK: Footer

private struct PopoverFooter: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PopoverInsights(history: model.history) { dismiss.then { model.openSettings(.insights) } }
            menuItem("Settings…", shortcut: "⌘,") { dismiss.then { model.openSettings(.general) } }
        }
        .padding(.top, 2)
    }
}

// MARK: Pieces

@MainActor
private func moduleRow<Action: View>(symbol: String, attention: Bool, title: String, detail: String,
                                     @ViewBuilder action: () -> Action) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbol).font(.system(size: 14))
            .foregroundStyle(attention ? LightState.waiting.color : .primary)
            .frame(width: 30, height: 30)
            .background(attention ? AnyShapeStyle(LightState.waiting.color.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Circle())
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.row.weight(.semibold))
            Text(detail).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small).buttonBorderShape(.capsule).padding(.top, 5)
        }
    }
}

@MainActor
func circle(_ symbol: String, on: Bool, size: CGFloat = 30) -> some View {
    Image(systemName: symbol).font(.system(size: size < 30 ? 11 : 14))
        .foregroundStyle(on ? .white : .primary)
        .frame(width: size, height: size)
        .background(on ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.quaternary), in: Circle())
}

/// What a settings row is set to, with the chevron that says it opens a menu.
@MainActor
private func settingValue(_ text: String) -> some View {
    HStack(spacing: 4) {
        Text(text).font(.status).foregroundStyle(.secondary).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }
    // Takes the row's spare width, so a long name truncates only when it has to.
    .frame(maxWidth: .infinity, alignment: .trailing)
}

/// A row of the settings module: it takes the list rows' hover fill. Each row pads its own controls by the bleed, so
/// their click targets reach the fill's edges and its words line up with the list rows above.
private struct SettingRow: ViewModifier {
    static let height: CGFloat = 36
    /// The icon size of the dictation and meeting rows.
    static let circle: CGFloat = 24
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.font(.row)
            .background(hovered ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .onHover { hovered = $0 }
    }
}

@MainActor
func menuItem(_ title: String, shortcut: String? = nil, chevron: Bool = false, inset: CGFloat = PopoverModule.inset,
                      action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, inset).frame(height: 28).contentShape(Rectangle())
    }
    .buttonStyle(MenuRowStyle())
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? .primary : .tertiary)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// A popover module: 14 pt plate inside the 22 pt panel, amber when it needs attention.
    func moduleBackground(attention: Bool = false, padded: Bool = true) -> some View {
        padding(.horizontal, padded ? PopoverModule.inset : 0).padding(.vertical, padded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(attention ? AnyShapeStyle(LightState.waiting.color.opacity(0.13)) : AnyShapeStyle(PopoverModule.fill),
                        in: RoundedRectangle(cornerRadius: Radius.module, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.module, style: .continuous)
                .strokeBorder(attention ? LightState.waiting.color.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

enum PopoverModule {
    /// Where a module's words start, from its edge.
    static let inset: CGFloat = 12
    /// How far a row's hover fill reaches past its words.
    static let bleed: CGFloat = 6
    /// The line that names a list, with the list's own action at its end.
    static let header: CGFloat = 24
    /// Light glass in light mode, a faint lift in dark: modules sit on the panel rather than sinking into it.
    static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 1, alpha: 0.62)
    })
}

/// The menu-bar window grows with its content but never shrinks, so anything that disappears
/// (a warning, the clipboard notice) left the old, taller frame outlined behind the popover.
/// This keeps the window exactly as tall as the content, its top edge under the menu bar.
struct PopoverWindowFit: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> Fitter { Fitter() }
    func updateNSView(_ view: Fitter, context: Context) { view.height = height }

    final class Fitter: NSView {
        var height: CGFloat = 0 { didSet { if height != oldValue { fit() } } }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map {
                // The system resizes the window when it opens or the content grows; fit after it.
                NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: $0, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fit() }
                }
            }
            fit()
        }

        private func fit() {
            guard let window, height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) >= 1 else { return }
            let fitted = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: fitted), display: true)
        }
    }
}

