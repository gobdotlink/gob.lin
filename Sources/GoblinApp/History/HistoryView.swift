import AppKit
import GoblinCore
import SwiftUI

/// Dictations and their detail, inside the shared app window.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: HistoryModel
    @State private var selectedID: UUID?
    @State private var deleteCandidate: HistoryEntry?
    @State private var showingRetention = false

    init(model: AppModel) {
        self.model = model
        _history = ObservedObject(wrappedValue: model.history)
    }

    private var selectedEntry: HistoryEntry? { history.entries.first { $0.id == selectedID } }

    var body: some View {
        entriesPane
            .toolbar {
                ToolbarTitle(title: "History", subtitle: subtitle, leading: 16)
                if let entry = selectedEntry {
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup {
                        Button(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.fill" : "star") {
                            Task { await history.setStarred(!entry.starred, entry: entry) }
                        }
                        Button("Copy", systemImage: "doc.on.doc") { copy(entry.finalText) }
                        Button("Delete", systemImage: "trash") { deleteCandidate = entry }
                    }
                }
            }
        .searchable(text: $history.searchText, placement: .toolbar, prompt: "Search dictations")
        // Scrolled rows stop at the toolbar rather than showing through the title (see Settings).
        .scrollEdgeEffectStyle(.hard, for: .top)
        .task(id: Query(search: history.searchText, filter: history.filter)) {
            await history.reload()
            await revealFocus()
        }
        .onChange(of: history.entries.map(\.id), initial: true) { _, ids in
            if selectedID.map({ ids.contains($0) }) != true { selectedID = ids.first }
        }
        .task(id: model.historyFocus) {
            guard model.historyFocus != nil else { return }
            await history.reload()
            await revealFocus()
        }
        .alert("Delete this dictation and its audio?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let entry = deleteCandidate { Task { await history.delete(entry) } }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
        .onDisappear { history.stopAudio() }
        .sheet(isPresented: $showingRetention) { HistoryRetentionView(model: history) }
    }

    private func revealFocus() async {
        guard let focus = model.historyFocus else { return }
        while model.historyFocus == focus, !Task.isCancelled {
            guard !history.isLoading else { return }
            if history.entries.contains(where: { $0.id == focus }) {
                selectedID = focus
                model.historyFocus = nil
                return
            }
            guard history.hasMore else { return }
            let count = history.entries.count
            await history.loadMore()
            guard history.entries.count > count else { return }
        }
    }

    private var title: String {
        switch history.filter {
        case .all: "All Dictations"
        case .starred: "Starred"
        case .withWarnings: "Warnings"
        case .application(let name): name
        }
    }

    private var subtitle: String {
        let counts = history.counts
        func dictations(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "dictation" : "dictations")" }
        switch history.filter {
        case .all:
            let minutes = Int((counts.totalSeconds / 60).rounded())
            return minutes > 0 ? "\(dictations(counts.total)) · \(minutes.formatted()) min of talking" : dictations(counts.total)
        case .starred: return dictations(counts.starred)
        case .withWarnings: return dictations(counts.withWarnings)
        case .application(let name): return dictations(counts.applications.first { $0.name == name }?.count ?? 0)
        }
    }

    private struct Query: Equatable {
        var search: String
        var filter: HistoryFilter
    }

    private var filters: some View {
        HStack {
            Menu {
                filterItem("All Dictations", .all, count: history.counts.total, symbol: "clock")
                filterItem("Starred", .starred, count: history.counts.starred, symbol: "star")
                filterItem("Warnings", .withWarnings, count: history.counts.withWarnings, symbol: "exclamationmark.triangle")
                if !history.counts.applications.isEmpty {
                    Divider()
                    ForEach(history.counts.applications) { app in
                        filterItem(app.name, .application(app.name), count: app.count, symbol: "app")
                    }
                }
            } label: {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Filter dictations: \(title)")
        }
        .padding(.horizontal, 16).frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func filterItem(_ title: String, _ filter: HistoryFilter, count: Int, symbol: String) -> some View {
        Button {
            history.filter = filter
        } label: {
            Label("\(title) · \(count.formatted())", systemImage: history.filter == filter ? "checkmark" : symbol)
        }
    }

    private var retentionFooter: some View {
        Button { showingRetention = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(retentionSummary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("Change…").font(.system(size: 11.5)).foregroundStyle(GoblinBrand.moss)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change history retention. Starred dictations are always kept.")
        .accessibilityLabel("History retention: \(retentionSummary). Change retention")
        .overlay(alignment: .top) { Divider() }
    }

    private var retentionSummary: String {
        let policy = history.retention
        var limits: [String] = []
        if let count = policy.maximumUnstarredCount { limits.append("Keep \(count.formatted()) unstarred") }
        if let days = policy.maximumAgeDays { limits.append("Delete after \(days.formatted()) \(days == 1 ? "day" : "days")") }
        return limits.isEmpty ? "Keeping all dictations" : limits.joined(separator: " · ")
    }

    // MARK: Entries

    private var entriesPane: some View {
        VStack(spacing: 0) {
            banners
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    filters
                    Group {
                        if history.entries.isEmpty, !history.isLoading {
                            if !history.searchText.isEmpty { ContentUnavailableView.search(text: history.searchText) }
                            else { ContentUnavailableView("Nothing here yet", systemImage: "tray") }
                        } else { entryList }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    retentionFooter
                }
                .frame(width: 330)
                Rectangle().fill(.primary.opacity(0.1)).frame(width: 1)
                Group {
                    if let entry = selectedEntry { EntryDetail(entry: entry, history: history).id(entry.id) }
                    else if history.counts.total == 0, !history.isLoading, history.searchText.isEmpty {
                        EmptyHistoryView(hotkeys: model.hotkeys)
                    } else { ContentUnavailableView("Pick a dictation", systemImage: "text.alignleft") }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(GoblinBrand.plate)
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if let error = history.errorMessage {
            Plate {
                StatusRow(.problem, Text(error)) {
                    Button("Dismiss") { history.errorMessage = nil }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        if !history.pending.isEmpty {
            Plate {
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(.waiting, Text("Not saved yet. Copy these, or try saving again before you quit.")) {
                        Button("Try Again") { Task { await history.retryPending() } }
                    }
                    ForEach(history.pending) { item in
                        HStack {
                            Text(item.entry.rawText).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { copy(item.entry.rawText) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
    }

    /// The selected row is a solid moss fill with white text, like a native list in an accent colour.
    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(dayGroups, id: \.day) { group in
                        Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            EntryRow(entry: entry, selected: entry.id == selectedID)
                                .overlay(alignment: .top) {
                                    // A rule under the text column, dropped beside the selected row.
                                    if index > 0, entry.id != selectedID, group.entries[index - 1].id != selectedID {
                                        Hairline().padding(.leading, 42)
                                    }
                                }
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = entry.id }
                                .contextMenu {
                                    Button("Copy") { copy(entry.finalText) }
                                    Button(entry.starred ? "Unstar" : "Star") { Task { await history.setStarred(!entry.starred, entry: entry) } }
                                    Button("Re-transcribe") { Task { await history.reprocess(entry, transcribe: true) } }
                                        .disabled(history.retranscribeAction == nil || entry.audioFilename == nil)
                                    Divider()
                                    Button("Delete…", role: .destructive) { deleteCandidate = entry }
                                }
                        }
                    }
                    if history.hasMore {
                        Button("Load Older Dictations") { Task { await history.loadMore() } }
                            .padding(16)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .arrowKeySelection(history.entries.map(\.id), selection: $selectedID)
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var dayGroups: [(day: Date, title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, title: String, entries: [HistoryEntry])] = []
        for entry in history.entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry); continue }
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month().day())
            groups.append((day, title, [entry]))
        }
        return groups
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct EntryRow: View {
    let entry: HistoryEntry
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleIdentifier: entry.targetBundleIdentifier, size: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.targetApplicationName ?? "Unknown app").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(entry.createdAt, format: .dateTime.hour().minute()).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(entry.finalText.isEmpty ? "Empty dictation" : entry.finalText)
                    .font(.system(size: 12.5)).lineLimit(2)
                    .foregroundStyle(entry.finalText.isEmpty ? .secondary : .primary).opacity(selected ? 1 : 0.86)
                HStack(spacing: 6) {
                    Text(Duration.seconds(entry.audioDuration.rounded()).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                    if entry.starred { Image(systemName: "star.fill").foregroundStyle(GoblinBrand.candle).accessibilityLabel("Starred") }
                    if entry.processingWarning != nil {
                        Label("Warning", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(GoblinBrand.candle))
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.top, 1)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .environment(\.colorScheme, selected ? .dark : environmentScheme)
        .background(selected ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @Environment(\.colorScheme) private var environmentScheme
}

private struct EntryDetail: View {
    let entry: HistoryEntry
    @ObservedObject var history: HistoryModel
    @State private var showRaw = true
    @State private var peaks: [Float] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    AppIcon(bundleIdentifier: entry.targetBundleIdentifier, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.targetApplicationName ?? "Unknown app").font(.system(size: 15, weight: .semibold))
                        Text("\(entry.createdAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute())) · \(seconds) seconds")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
                if let warning = entry.processingWarning {
                    StatusRow(.waiting, Text(warning)).padding(.top, 14)
                }
                Text(entry.finalText.isEmpty ? "No text" : entry.finalText)
                    .font(.system(size: 17)).lineSpacing(3).textSelection(.enabled)
                    .foregroundStyle(entry.finalText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                playback.padding(.top, 14)
                facts.padding(.top, 18)
                if entry.latencies.processingMilliseconds > 0 { latency.padding(.top, 18) }
                DisclosureGroup("What you said", isExpanded: $showRaw) {
                    Group {
                        if entry.rawText != entry.finalText, !entry.rawText.isEmpty { InlineDiff(from: entry.rawText, to: entry.finalText) }
                        else { Text(entry.rawText.isEmpty ? "No text" : entry.rawText) }
                    }
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .disclosureGroupStyle(RowDisclosureStyle())
                .padding(.top, 18)
                editObservation.padding(.top, 18)
                ViewThatFits(in: .horizontal) {
                    actions(entry).labelStyle(.titleAndIcon)
                    actions(entry).labelStyle(.iconOnly)
                }
                .padding(.top, 16)
            }
            .padding(28)
        }
    }

    /// What became of the pasted text, when the target could be watched.
    @ViewBuilder private var editObservation: some View {
        switch entry.editOutcome {
        case .edited:
            if let editedText = entry.editedText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After we transcribed — you edited").font(.system(size: 13, weight: .semibold))
                    InlineDiff(from: entry.finalText, to: editedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .rewritten:
            Text("You rewrote this after dictating.").font(.callout).foregroundStyle(.secondary)
        case .rejected:
            Text("You deleted this after dictating.").font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func actions(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            Button("Re-transcribe", systemImage: "arrow.clockwise") { Task { await history.reprocess(entry, transcribe: true) } }
                .disabled(history.retranscribeAction == nil || entry.audioFilename == nil)
                .help(history.retranscribeAction == nil ? "Available once the speech model is ready." : "Make a new dictation from the original recording.")
            Button("Rewrite", systemImage: "wand.and.stars") { Task { await history.reprocess(entry, transcribe: false) } }
                .disabled(history.rewriteAction == nil)
                .help(history.rewriteAction == nil ? "Turn on Cleanup to rewrite dictations." : "Save a cleaned-up copy as a new dictation. This one stays.")
        }
        .fixedSize()
    }

    /// Play button, the recording's waveform filling as it plays, and the time.
    private var playback: some View {
        let playing = history.playingEntryID == entry.id
        return HStack(spacing: 12) {
            Button { Task { await history.play(entry) } } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .offset(x: playing ? 0 : 1) // a triangle looks off-centre when centred by its box
                    .frame(width: 28, height: 28).background(GoblinBrand.moss, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(entry.audioFilename == nil)
            .accessibilityLabel(playing ? "Stop audio" : "Play audio")
            TimelineView(.periodic(from: .now, by: playing ? 0.05 : 60)) { _ in
                let progress = playing ? history.playbackProgress : 0
                HStack(spacing: 12) {
                HStack(spacing: 0) {
                    if peaks.isEmpty {
                        Text(entry.audioFilename == nil ? "No recording kept" : "Play the recording").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else {
                        ForEach(Array(peaks.enumerated()), id: \.offset) { index, peak in
                            Capsule().fill(Double(index) / Double(peaks.count) < progress ? AnyShapeStyle(GoblinBrand.mossText) : AnyShapeStyle(.tertiary))
                                .frame(width: 2, height: max(3, CGFloat(peak) * 26))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .onTapGesture { if entry.audioFilename != nil { Task { await history.play(entry) } } }
                Text("\(time(playing ? history.playbackProgress * entry.audioDuration : 0)) / \(time(entry.audioDuration))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
            }
        }
        .task { peaks = await history.waveform(for: entry) }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
    }

    private var seconds: String { entry.audioDuration.formatted(.number.precision(.fractionLength(0))) }

    private var facts: some View {
        HStack(spacing: 0) {
            fact("Words", entry.wordCount.formatted())
            Divider()
            fact("Tone", entry.tone.isEmpty ? "—" : entry.tone.capitalized)
            Divider()
            fact("Cleanup", entry.polished ? "Cleaned up" : "As spoken")
            Divider()
            fact("Speech model", entry.model.isEmpty ? "—" : entry.model.hasPrefix("parakeet-tdt-v3") ? "Parakeet v3" : entry.model)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GoblinBrand.caseBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var latency: some View {
        let timings = entry.latencies
        let transcribe = timings.trimMilliseconds + timings.asrMilliseconds
        let parts: [(String, Double, Color)] = [("Transcribe", transcribe, GoblinBrand.moss),
                                                ("Cleanup", timings.rewriteMilliseconds, GoblinBrand.moss.opacity(0.5)),
                                                ("Paste", timings.insertionMilliseconds, Color.secondary.opacity(0.5))]
        let total = timings.processingMilliseconds
        return VStack(alignment: .leading, spacing: 8) {
            Text("**\(ms(total))** \(entry.finalText.isEmpty ? "from key-up to finding nothing to type" : entry.targetApplicationName.map { "from key-up to text in \($0)" } ?? "from key-up to text")")
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(4, (geometry.size.width - 4) * part.1 / total))
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend(parts) }.fixedSize()
                VStack(alignment: .leading, spacing: 4) { legend(parts) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ parts: [(String, Double, Color)]) -> some View {
        ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 8, height: 8)
                Text("\(part.0) \(ms(part.1))")
            }
        }
    }

    private func ms(_ value: Double) -> String { "\(Int(value.rounded()).formatted()) ms" }
}

/// Asleep, still scowling. The first line is the joke; the second is the instruction.
struct EmptyHistoryView: View {
    @ObservedObject var hotkeys: HotkeyService

    private var shortcut: String { hotkeys.shortcut == .fn ? "fn" : hotkeys.shortcut.label }

    var body: some View {
        VStack(spacing: 0) {
            PixelSprite(sprite: .closed, scale: 2)
                .overlay(alignment: .topTrailing) { PixelSprite(sprite: .zz, scale: 2).offset(x: 22, y: -2) }
            Text("Nothing to snitch on yet.").font(.title3.weight(.semibold)).padding(.top, 18)
            Text("Hold \(shortcut) and say something. I'll keep the receipts.").foregroundStyle(.secondary).padding(.top, 4)
            Text("History stays on this Mac.").font(.caption).foregroundStyle(.tertiary).padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app's own icon, or a neutral tile when the app isn't installed.
struct AppIcon: View {
    let bundleIdentifier: String?
    var size: CGFloat = 20
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.quaternary)
                    .overlay(Image(systemName: "app").font(.system(size: size * 0.5)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var icon: NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let cached = Self.cache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleIdentifier] = image
        return image
    }
}
