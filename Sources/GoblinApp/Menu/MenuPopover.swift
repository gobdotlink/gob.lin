import AppKit
import GoblinCore
import SwiftUI

/// The popover behind the menu-bar icon: everything used daily, one click deep.
/// Each module observes only the models it shows, so a meter tick or a hovered row redraws
/// that module rather than the whole popover.
struct MenuPopover: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            PopoverHeader(model: model)
            PopoverNotices(model: model)
            PopoverMicrophone(preview: model.audioPreview)
            HStack(spacing: 8) { PopoverCleanup(model: model); PopoverTone() }
            PopoverRecents(model: model)
            PopoverFooter(model: model)
        }
        .padding(8)
        .frame(width: 360)
        .onAppear { model.closePopover = { dismiss() } }
        .onDisappear { model.closePopover = nil }
    }
}

private extension DismissAction {
    /// Closes the popover and runs the action straight away: windows activate gob.lin themselves.
    func then(_ action: () -> Void) {
        callAsFunction()
        action()
    }
}

// MARK: Header

private struct PopoverHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var diagnostics: DiagnosticsModel
    @ObservedObject private var speechModels: SpeechModelService
    @ObservedObject private var hotkeys: HotkeyService
    // The ⋯ menu's titles and enabled states come from these two.
    @ObservedObject private var permissions: PermissionModel
    @ObservedObject private var updates: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _diagnostics = ObservedObject(wrappedValue: model.diagnostics)
        _speechModels = ObservedObject(wrappedValue: model.speechModels)
        _hotkeys = ObservedObject(wrappedValue: model.hotkeys)
        _permissions = ObservedObject(wrappedValue: model.permissions)
        _updates = ObservedObject(wrappedValue: model.updates)
    }

    var body: some View {
        let status = model.status
        return HStack(spacing: 10) {
            PixelSprite(sprite: diagnostics.hasWarning ? .side : .shut, scale: 1)
            VStack(alignment: .leading, spacing: 5) {
                GoblinWordmark(size: 24)
                HStack(spacing: 6) {
                    StatusLight(state: status.light, size: 7)
                    if status.light == .ready, model.mascotState == .idle {
                        Text("Ready · hold")
                        KeyCombo(label: hotkeys.shortcut == .fn ? "fn" : hotkeys.shortcut.label, small: true)
                        Text("to talk")
                    } else {
                        Text(model.mascotState == .recording ? "Listening…" : model.mascotState == .transcribing ? "Writing it out…"
                             : "\(status.title) · \(status.detail)")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
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
                    Text("gob.lin \(version) is ready").font(.system(size: 13, weight: .semibold))
                    Text("Restarting takes a second.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button("Restart") { updates.install() }
                    .prominent().disabled(updates.isBusy || !model.canInstallUpdate)
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

/// Always the same height: the meter shows flat until the button is held, so the popover never resizes.
private struct PopoverMicrophone: View {
    @ObservedObject var preview: AudioPreviewModel
    @AppStorage("audio.inputDeviceUID") private var deviceUID = ""
    @State private var levels = Array(repeating: 0.0, count: 28)
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                circle("mic", on: testing)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Menu {
                        Picker("Microphone", selection: $deviceUID) {
                            Text("Follow System Default").tag("")
                            ForEach(preview.devices) { Text($0.name).tag($0.uid) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        HStack(spacing: 4) {
                            Text(deviceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Microphone, \(deviceName)")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                }
                Spacer(minLength: 6)
                Text(testing ? "Testing" : "Hold to Test")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(testing ? .white : .primary)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(testing ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.quaternary), in: Capsule())
                    .contentShape(Capsule())
                    // The mic opens only while the button is held, so the system's orange dot stays honest.
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}) { pressing in
                        if pressing { startTest() } else { stopTest() }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Hold to test the microphone")
            }
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(testing && level > 0.02 ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.tertiary))
                        .frame(width: 3, height: 3 + (testing ? level : 0) * 22)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            .accessibilityHidden(true)
            Text(preview.silenceNotice ?? preview.error ?? (testing ? "Level only. Nothing is recorded or saved." : "Hold the button to check your mic. Nothing is saved."))
                .font(.system(size: 11)).foregroundStyle(preview.silenceNotice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(1)
        }
        .moduleBackground()
        .onAppear { preview.refresh() }
        .onChange(of: preview.level) { _, level in levels = Array((levels + [level]).suffix(28)) }
        .onDisappear { if testing { stopTest() } }
    }

    private var deviceName: String {
        preview.devices.first { $0.uid == deviceUID }?.name ?? (deviceUID.isEmpty ? "System Default" : "Saved microphone")
    }

    private func startTest() {
        guard !testing else { return }
        testing = true
        levels = Array(repeating: 0, count: levels.count)
        preview.start(uid: deviceUID)
    }

    private func stopTest() {
        testing = false
        preview.stop()
    }
}

// MARK: Cleanup and tone

/// The circle switches cleanup on or off; the rest of the tile opens the level menu.
private struct PopoverCleanup: View {
    /// Observed for refreshConfiguration, which announces saved cleanup settings.
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = RewriteSettingsStore.load(defaults: model.defaults)
        let on = settings.enabled && settings.cleanup != .none
        return HStack(spacing: 0) {
            Button { toggleCleanup(settings) } label: {
                circle("wand.and.stars", on: on)
                    .padding(.leading, 12).padding(.trailing, 10).frame(maxHeight: .infinity)
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
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cleanup").font(.system(size: 13, weight: .semibold))
                        ViewThatFits(in: .horizontal) {
                            Text(on ? "\(settings.cleanup.title) · \(settings.provider.title)" : "Off")
                            Text(on ? settings.cleanup.title : "Off")
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.trailing, 12).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .frame(height: 52)
        .moduleBackground(padded: false)
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

/// The whole tile opens the tone menu.
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
                circle("textformat", on: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tone").font(.system(size: 13, weight: .semibold))
                    Text(selected.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 52)
            .moduleBackground(padded: false)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(history.counts.total > 0 ? "Search \(history.counts.total.formatted()) dictations" : "Search dictations", text: $query)
                    .textFieldStyle(.plain).focused($searching)
                Text("⌘F").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .background { Button("Search") { searching = true }.keyboardShortcut("f").hidden() }
            .padding(.horizontal, 9).frame(height: 30)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 4)
            VStack(spacing: 2) {
                if recent.isEmpty {
                    Text(query.isEmpty ? "Your dictations show up here." : "Nothing matches “\(query)”.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, 4)
                }
                ForEach(recent) { entry in
                    RecentRow(entry: entry, open: { dismiss.then { model.openHistory(.all, focus: entry.id) } }, star: {
                        Task { await history.setStarred(!entry.starred, entry: entry); await reload() }
                    })
                }
            }
            .frame(height: 4 * 42, alignment: .top)
            menuItem("All History", chevron: true) { dismiss.then { model.openHistory() } }
            PopoverInsights(history: history) { dismiss.then { model.openSettings(.insights) } }
        }
        .moduleBackground()
        .task(id: RecentQuery(text: query, revision: history.revision)) { await reload() }
    }

    private func reload() async {
        recent = (try? await history.store?.entries(matching: query, limit: 4)) ?? []
    }
}

/// Local totals use retained history, independently of the recent-search query.
private struct PopoverInsights: View {
    @ObservedObject var history: HistoryModel
    let open: () -> Void
    @State private var insights: HistoryInsights?
    @State private var unavailable = false
    @State private var refreshID = UUID()

    private struct Request: Equatable { var revision: Int; var refresh: UUID }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(summary).font(.system(size: 13)).monospacedDigit()
                }
                Spacer(minLength: 4)
                if let insights {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(insights.days) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(GoblinBrand.moss.opacity(day.words > 0 ? 1 : 0.2))
                                .frame(width: 5, height: max(3, 22 * Double(day.words) / Double(max(1, insights.days.map(\.words).max() ?? 0))))
                        }
                    }
                    .frame(height: 22, alignment: .bottom)
                    .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 7)
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
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
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
        .font(.system(size: 13))
        .padding(.vertical, 5).padding(.horizontal, 4)
        .frame(height: 40)
        .background(hovered ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            menuItem("Paste Last Dictation", shortcut: "⌥⇧⌘V", action: paste)
                .disabled(!model.canPasteLastTranscript)
            menuItem("Settings…", shortcut: "⌘,") { dismiss.then { model.openSettings(.general) } }
        }
        .padding(.top, 2)
    }

    /// Hands focus back to the app the person was in first, so the paste lands there rather than in gob.lin.
    private func paste() {
        dismiss()
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.pasteLastTranscript() }
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
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small).padding(.top, 5)
        }
    }
}

@MainActor
private func circle(_ symbol: String, on: Bool) -> some View {
    Image(systemName: symbol).font(.system(size: 14))
        .foregroundStyle(on ? .white : .primary)
        .frame(width: 30, height: 30)
        .background(on ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.quaternary), in: Circle())
}

@MainActor
private func menuItem(_ title: String, shortcut: String? = nil, chevron: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
    }
    .buttonStyle(MenuRowStyle())
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? .primary : .tertiary)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

private extension View {
    /// A popover module: 14 pt plate inside the 22 pt panel, amber when it needs attention.
    func moduleBackground(attention: Bool = false, padded: Bool = true) -> some View {
        padding(.horizontal, padded ? 12 : 0).padding(.vertical, padded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(attention ? AnyShapeStyle(LightState.waiting.color.opacity(0.13)) : AnyShapeStyle(PopoverModule.fill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(attention ? LightState.waiting.color.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

private enum PopoverModule {
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

