import AppKit
import GoblinCore
import SwiftUI

/// The popover behind the menu-bar icon: everything used daily, one click deep.
struct MenuPopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audio.inputDeviceUID") private var deviceUID = ""
    @AppStorage(DictationTone.preferenceKey) private var toneRaw = DictationTone.formal.rawValue
    @State private var query = ""
    @State private var recent: [HistoryEntry] = []
    @State private var levels = Array(repeating: 0.0, count: 28)
    @State private var testing = false
    @State private var hovered: UUID?
    @State private var height: CGFloat = 0
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            header
            ForEach(model.diagnostics.warnings, id: \.area) { problem($0) }
            if model.insertion.hasRecoveryClipboard {
                module(attention: true) {
                    moduleRow(symbol: "doc.on.clipboard", attention: true, title: "Your last dictation is on the clipboard",
                              detail: "What you'd copied before is kept.") {
                        Button("Restore Previous Clipboard") { model.insertion.restorePreviousClipboard() }.disabled(model.insertion.busy)
                    }
                }
            }
            if let version = model.updates.availableVersion {
                module {
                    HStack(spacing: 10) {
                        circle("arrow.down.circle", on: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("gob.lin \(version) is ready").font(.system(size: 13, weight: .semibold))
                            Text("Restarting takes a second.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button("Restart") { model.updates.install() }
                            .prominent().disabled(model.updates.isBusy || !model.canInstallUpdate)
                    }
                }
            }
            microphone
            HStack(spacing: 8) { cleanup; tone }
            recents
            VStack(spacing: 0) {
                menuItem("Paste Last Dictation", shortcut: "⌥⇧⌘V") { close { model.pasteLastTranscript() } }
                    .disabled(!model.canPasteLastTranscript)
                menuItem("Settings…", shortcut: "⌘,") { close { model.openSettings(.general) } }
            }
            .padding(.top, 2)
        }
        .padding(8)
        .frame(width: 360)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .background(PopoverWindowFit(height: height))
        .task(id: RecentQuery(text: query, revision: model.history.revision)) {
            recent = (try? await model.history.store?.entries(matching: query, limit: 4)) ?? []
        }
        .onChange(of: model.audioPreview.level) { _, level in levels = Array((levels + [level]).suffix(28)) }
        .onAppear { model.closePopover = { dismiss() } }
        .onDisappear { model.closePopover = nil; if testing { stopTest() } }
    }

    private struct RecentQuery: Equatable { var text: String; var revision: Int }

    // MARK: Header

    private var header: some View {
        let status = model.status
        return HStack(spacing: 10) {
            PixelSprite(sprite: model.diagnostics.hasWarning ? .side : .shut, scale: 0.5)
            VStack(alignment: .leading, spacing: 5) {
                GoblinWordmark(size: 16)
                HStack(spacing: 6) {
                    StatusLight(state: status.light, size: 7)
                    if status.light == .ready, model.mascotState == .idle {
                        Text("Ready · hold")
                        KeyCombo(label: model.hotkeys.shortcut == .fn ? "fn" : model.hotkeys.shortcut.label, small: true)
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
                        Button(command.title) { close(command.perform) }
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

    // MARK: Problems

    private func problem(_ failure: DiagnosticFailure) -> some View {
        module(attention: true) {
            moduleRow(symbol: symbol(for: failure.area), attention: true, title: failure.plainWords.title, detail: failure.plainWords.detail) {
                if let fix = model.fix(for: failure) { Button(fix.title) { close(fix.action) } }
            }
        }
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

    // MARK: Microphone

    /// Always the same height: the meter shows flat until the button is held, so the popover never resizes.
    private var microphone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                circle("mic", on: testing)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Menu {
                        Picker("Microphone", selection: $deviceUID) {
                            Text("Follow System Default").tag("")
                            ForEach(model.audioPreview.devices) { Text($0.name).tag($0.uid) }
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
            Text(model.audioPreview.error ?? (testing ? "Level only. Nothing is recorded or saved." : "Hold the button to check your mic. Nothing is saved."))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .moduleBackground()
        .onAppear { model.audioPreview.refresh() }
    }

    private var deviceName: String {
        model.audioPreview.devices.first { $0.uid == deviceUID }?.name ?? (deviceUID.isEmpty ? "System Default" : "Saved microphone")
    }

    private func startTest() {
        guard !testing else { return }
        testing = true
        levels = Array(repeating: 0, count: levels.count)
        model.audioPreview.start(uid: deviceUID)
    }

    private func stopTest() {
        testing = false
        model.audioPreview.stop()
    }

    // MARK: Cleanup and tone

    /// The circle switches cleanup on or off; the rest of the tile opens the level menu.
    private var cleanup: some View {
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
                Button("Cleanup Settings…") { close { model.openSettings(.cleanup) } }
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
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains((try? settings.endpoint())?.host ?? "")
        let hasKey = local || (model.servicesEnabled && (try? RewriteKeyStore.load(for: settings, defaults: model.defaults))?.isEmpty == false)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasKey else {
            close { model.openSettings(.cleanup) }
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

    /// The whole tile opens the tone menu.
    private var tone: some View {
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

    // MARK: Recents

    /// Four rows' worth of space whatever the search finds, so typing never resizes the popover.
    private var recents: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.history.counts.total > 0 ? "Search \(model.history.counts.total.formatted()) dictations" : "Search dictations", text: $query)
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
                ForEach(recent) { entry in recentRow(entry) }
            }
            .frame(height: 4 * 42, alignment: .top)
            menuItem("All History", chevron: true) { close { model.openHistory() } }
            menuItem("Insights", chevron: true) { close { model.openHistory(.insights) } }
        }
        .moduleBackground()
    }

    /// Click a row to open it in History; hover shows copy and star.
    private func recentRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleIdentifier: entry.targetBundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.finalText.isEmpty ? "Empty dictation" : entry.finalText).lineLimit(1)
                Text("\(entry.targetApplicationName ?? "Unknown app") · \(entry.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered == entry.id {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                Button(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.fill" : "star") {
                    Task { await model.history.setStarred(!entry.starred, entry: entry); recent = (try? await model.history.store?.entries(matching: query, limit: 4)) ?? [] }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if entry.starred {
                Image(systemName: "star.fill").foregroundStyle(GoblinBrand.candle).accessibilityLabel("Starred")
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 5).padding(.horizontal, 4)
        .frame(height: 40)
        .background(hovered == entry.id ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .onTapGesture { close { model.openHistory(.all, focus: entry.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close { model.openHistory(.all, focus: entry.id) } }
    }

    // MARK: Pieces

    private func module<Content: View>(attention: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content().moduleBackground(attention: attention)
    }

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

    private func circle(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 14))
            .foregroundStyle(on ? .white : .primary)
            .frame(width: 30, height: 30)
            .background(on ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.quaternary), in: Circle())
    }

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

    /// Closes the popover and hands focus back to the app the person was in, so a paste lands
    /// there rather than in gob.lin. New windows activate gob.lin again themselves.
    private func close(_ action: @escaping () -> Void) {
        dismiss()
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action() }
    }
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
private struct PopoverWindowFit: NSViewRepresentable {
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

