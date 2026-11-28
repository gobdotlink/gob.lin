import AppKit
import GoblinCore
import GoblinMeetings
import SwiftUI

/// The store's meeting summary, as the list and the meeting's page show it.
typealias StoredMeeting = GoblinMeetings.MeetingSummary

/// Meetings in the Settings window, under History: a list grouped by day beside the selected meeting.
struct MeetingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var meetings: MeetingsController
    @State private var list: [StoredMeeting] = []
    @State private var loaded = false
    @State private var selectedID: String?
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var audioBytes = 0
    @State private var revision = 0
    @State private var copied = false
    @State private var deleting: Deletion?
    /// Why the last delete didn't go through, until it's dismissed.
    @State private var editFailure: String?
    /// The transcript beside the selected meeting, remembered like an inspector.
    @AppStorage(MeetingsView.showsTranscriptKey) private var showsTranscript = false
    static let showsTranscriptKey = "meetings.showsTranscript"

    enum Filter: Hashable { case all, needsNames, source(String) }
    enum Deletion: Identifiable { case audio(StoredMeeting), meeting(StoredMeeting), notes(StoredMeeting)
        var id: String {
            switch self {
            case .audio(let m): "audio-" + m.id
            case .meeting(let m): "meeting-" + m.id
            case .notes(let m): "notes-" + m.id
            }
        }
    }

    init(model: AppModel) {
        self.model = model
        _meetings = ObservedObject(wrappedValue: model.meetings)
    }

    private var store: MeetingStore { meetings.library.store }
    private var selected: StoredMeeting? { list.first { $0.id == selectedID } }

    private var shown: [StoredMeeting] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return list.filter { meeting in
            switch filter {
            case .all: break
            case .needsNames: if !MeetingBadge.badges(meeting).contains(.needsNames) { return false }
            case .source(let source): if Self.sourceName(meeting) != source { return false }
            }
            guard !query.isEmpty else { return true }
            return ([meeting.title, Self.sourceName(meeting)] + meeting.speakers + meeting.participants)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        content
            .toolbar {
                ToolbarTitle(title: "Meetings", subtitle: subtitle, leading: 16)
                if let meeting = selected, list.contains(where: { $0.id == meeting.id }) {
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup {
                        Button(showsTranscript ? "Hide Transcript" : "Show Transcript", systemImage: "sidebar.right") { showsTranscript.toggle() }
                            .keyboardShortcut("t", modifiers: [.command, .option])
                            .help(showsTranscript ? "Hide Transcript (⌥⌘T)" : "Show Transcript (⌥⌘T)")
                        Menu(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            Button("Copy Notes") { copy(meeting, .notes) }
                            Button("Copy Transcript") { copy(meeting, .transcript) }.disabled(meeting.speakers.isEmpty)
                            Button("Copy All as Markdown") { copy(meeting, .all) }
                        }
                        .menuIndicator(.hidden)
                        .disabled(meeting.state != .ready && meeting.state != .failed)
                        .help("Copy the notes, the transcript, or both as Markdown")
                        Menu("Delete", systemImage: "trash") {
                            // A rewrite still running would write the notes again once it lands.
                            Button("Delete Notes…") { deleting = .notes(meeting) }.disabled(meetings.notes.writing.contains(meeting.id))
                            Button("Delete Audio Only…") { deleting = .audio(meeting) }.disabled(!meeting.hasAudio)
                            Button("Delete Meeting…", role: .destructive) { deleting = .meeting(meeting) }
                        }
                        // A menu with its chevron gets a glass of its own; without it, it shares the copy button's, as History's buttons do.
                        .menuIndicator(.hidden)
                        .disabled(meeting.state == .recording || meeting.state == .processing)
                        .help("Delete the audio, or the whole meeting")
                    }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
            .scrollEdgeEffectStyle(.hard, for: .top)
            .task(id: ListKey(meetings: meetings.meetings, revision: revision)) { await reload() }
            .onChange(of: meetings.focusedMeetingID, initial: true) { _, focus in
                if let focus { selectedID = focus; meetings.focusedMeetingID = nil; revision += 1 }
            }
            // Seeing the meeting the popover's ready card is about is opening it.
            .onChange(of: selectedID) { _, id in
                if let id, id == meetings.unopenedMeetingID { meetings.dismissUnopened() }
            }
            // A meeting that finishes while it's the one on show has been seen.
            .onChange(of: meetings.unopenedMeetingID) { _, id in
                if let id, id == selectedID { meetings.dismissUnopened() }
            }
            .onChange(of: list.map(\.id)) { _, ids in
                if selectedID.map({ ids.contains($0) }) != true { selectedID = shown.first?.id }
            }
            .alert("I couldn't delete that", isPresented: Binding(get: { editFailure != nil }, set: { if !$0 { editFailure = nil } })) {
                Button("OK") { editFailure = nil }
            } message: {
                Text(editFailure ?? "")
            }
            .alert(deletionTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { deletion in
                switch deletion {
                case .audio(let meeting): Button("Delete Audio", role: .destructive) { edit { try await store.deleteAudio(meeting.id) } }
                case .meeting(let meeting): Button("Delete Meeting", role: .destructive) { edit { try await store.delete(meeting.id) } }
                case .notes(let meeting): Button("Delete Notes", role: .destructive) {
                    guard !meetings.notes.writing.contains(meeting.id) else { deleting = nil; return }
                    edit { try await meetings.notes.deleteNotes(meeting.id) }
                }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { deletion in
                switch deletion {
                case .audio: Text("I'll keep the transcript, names and marks, but you won't be able to play it.")
                case .meeting: Text("This removes its transcript, names, marks and audio from this Mac.")
                case .notes: Text("I'll keep the transcript, names and marks. You can write new notes any time.")
                }
            }
    }

    private struct ListKey: Equatable {
        var meetings: [MeetingSummary]
        var revision: Int
    }

    @ViewBuilder private var content: some View {
        if loaded, list.isEmpty {
            EmptyMeetingsView(enabled: meetings.enabled)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    filters
                    Group {
                        if shown.isEmpty, loaded {
                            if !search.isEmpty { ContentUnavailableView.search(text: search) }
                            else { Text(filter == .needsNames ? "Every voice has a name." : "I haven't recorded any of those yet.").font(.status).foregroundStyle(.secondary) }
                        } else { meetingList }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    storageFooter
                }
                .frame(width: 330)
                Rectangle().fill(.primary.opacity(0.1)).frame(width: 1)
                Group {
                    if let meeting = selected {
                        MeetingDetailView(meeting: meeting, store: store, notesModel: meetings.notes, revision: revision,
                                          processingLine: meetings.processingLine, remembersVoices: meetings.rememberVoices,
                                          people: meetings.people.map(\.name),
                                          askWho: meetings.askWhoMeetingID == meeting.id, onAskedWho: { meetings.askWhoMeetingID = nil },
                                          showsTranscript: $showsTranscript, addToDictionary: addToDictionary) {
                            revision += 1
                            // The popover and the status menu read the controller's list: their voices-to-name counts too.
                            meetings.refreshList()
                            NotificationCenter.default.post(name: .meetingsEdited, object: nil)
                        }
                        .id(meeting.id)
                    } else {
                        ContentUnavailableView("Pick a meeting", systemImage: "person.2.wave.2")
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(GoblinBrand.plate)
            }
        }
    }

    private var subtitle: String {
        let total = list.reduce(0) { $0 + $1.duration }
        let count = "\(list.count.formatted()) \(list.count == 1 ? "meeting" : "meetings")"
        return total >= 60 ? "\(count) · \(MeetingTimeline.length(total))" : count
    }

    private var filterTitle: String {
        switch filter {
        case .all: "All Meetings"
        case .needsNames: "Needs Names"
        case .source(let source): source
        }
    }

    private var sources: [(String, Int)] {
        var counts: [String: Int] = [:]
        for meeting in list { counts[Self.sourceName(meeting), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    }

    private var filters: some View {
        Menu {
            filterItem("All Meetings", .all, count: list.count, symbol: "person.2.wave.2")
            filterItem("Needs Names", .needsNames, count: list.filter { MeetingBadge.badges($0).contains(.needsNames) }.count,
                       symbol: "person.crop.circle.badge.questionmark")
            if sources.count > 1 {
                Divider()
                ForEach(sources, id: \.0) { source, count in filterItem(source, .source(source), count: count, symbol: "app") }
            }
        } label: {
            HStack {
                Text(filterTitle).font(.row.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Filter meetings: \(filterTitle)")
        .padding(.horizontal, 16).frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func filterItem(_ title: String, _ value: Filter, count: Int, symbol: String) -> some View {
        Button { filter = value } label: {
            Label("\(title) · \(count.formatted())", systemImage: filter == value ? "checkmark" : symbol)
        }
    }

    private var storageFooter: some View {
        Button { model.settingsSelection = .meetingRecording } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Audio kept 1 week · \(ByteCountFormatter.string(fromByteCount: Int64(audioBytes), countStyle: .file))")
                    .font(.meta).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                Text("Change…").font(.meta).foregroundStyle(GoblinBrand.mossText)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio kept 1 week. Open Meeting Recording settings")
        .overlay(alignment: .top) { Divider() }
    }

    private var meetingList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(MeetingDay.groups(shown)) { group in
                        Text(group.title).font(.meta.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                        ForEach(Array(group.meetings.enumerated()), id: \.element.id) { index, meeting in
                            MeetingRow(meeting: meeting, selected: meeting.id == selectedID)
                                .overlay(alignment: .top) {
                                    if index > 0, meeting.id != selectedID, group.meetings[index - 1].id != selectedID {
                                        Hairline().padding(.leading, 42)
                                    }
                                }
                                .id(meeting.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = meeting.id }
                                .accessibilityAction { selectedID = meeting.id }
                                .contextMenu {
                                    Button("Copy All") { copy(meeting) }.disabled(meeting.state != .ready)
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.directory]) }
                                    Divider()
                                    // As the toolbar's Delete: the store refuses either while the meeting is busy.
                                    let busy = meeting.state == .recording || meeting.state == .processing
                                    Button("Delete Audio Only…") { deleting = .audio(meeting) }.disabled(busy || !meeting.hasAudio)
                                    Button("Delete Meeting…", role: .destructive) { deleting = .meeting(meeting) }.disabled(busy)
                                }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .arrowKeySelection(shown.map(\.id), selection: $selectedID)
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var deletionTitle: String {
        switch deleting {
        case .audio(let meeting): "Delete the audio for \(meeting.title)?"
        case .meeting(let meeting): "Delete \(meeting.title)?"
        case .notes(let meeting): "Delete the notes for \(meeting.title)?"
        case nil: ""
        }
    }

    /// Names fixed in a meeting, into the Dictionary for every app, so dictation and later meetings spell them right.
    /// Says what happened: added, already there, or why it couldn't be.
    private func addToDictionary(_ spellings: [String]) -> String? {
        let dictionary = model.dictionary
        var added: [String] = [], known: [String] = [], refused: [String] = []
        var reason: String?
        for spelling in spellings {
            guard let clean = MeetingCorrections.normalized(spelling) else { continue }
            if dictionary.entries.contains(where: { $0.spelling.caseInsensitiveCompare(clean) == .orderedSame }) { known.append(clean); continue }
            // One that clashes with another entry doesn't stop the rest.
            if dictionary.put(DictionaryEntry(spelling: clean)) { added.append(clean) } else { refused.append(clean); reason = dictionary.error }
        }
        let joined = { (names: [String]) in ListFormatter.localizedString(byJoining: names) }
        var sentences: [String] = []
        if !added.isEmpty { sentences.append("Added \(joined(added)) to the Dictionary.") }
        if !known.isEmpty { sentences.append("\(joined(known)) \(known.count == 1 ? "was" : "were") already there.") }
        if !refused.isEmpty { sentences.append("I couldn't add \(joined(refused))" + (reason.map { ": \($0)" } ?? ".")) }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private func reload() async {
        let next = await store.list()
        audioBytes = await store.audioBytes()
        if next != list { list = next }
        if selectedID == nil || !next.contains(where: { $0.id == selectedID }) { selectedID = shown.first?.id }
        loaded = true
    }

    private func edit(_ change: @escaping () async throws -> Void) {
        deleting = nil
        Task {
            do { try await change() } catch { editFailure = error.localizedDescription }
            revision += 1
            meetings.refreshList()
            NotificationCenter.default.post(name: .meetingsEdited, object: nil)
        }
    }

    enum CopyPart { case notes, transcript, all }

    private func copy(_ meeting: StoredMeeting, _ part: CopyPart = .all) {
        Task {
            let markdown: String? = switch part {
            case .all: try? await store.fullMarkdown(meeting.id)
            // Nothing is copied, and nothing says Copied, when there are no lines.
            case .transcript: try? await store.transcriptMarkdown(meeting.id)
            case .notes: try? await store.notesMarkdown(meeting.id)
            }
            guard let markdown else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            copied = true
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }

    /// What the meeting was recorded from, as the list and the header say it.
    static func sourceName(_ meeting: StoredMeeting) -> String {
        meeting.kind == .inPerson ? "In person" : meeting.source.isEmpty ? "Call" : meeting.source
    }
}

/// App icon, title, time, who spoke, length, and the states that need a look.
private struct MeetingRow: View {
    let meeting: StoredMeeting
    var selected = false

    var body: some View {
        let badges = MeetingBadge.badges(meeting)
        HStack(alignment: .top, spacing: 10) {
            MeetingIcon(meeting: meeting, size: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(meeting.title).font(.status.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(meeting.startedAt, format: .dateTime.hour().minute()).font(.status).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(preview).font(.status).lineLimit(2).foregroundStyle(.primary).opacity(selected ? 1 : 0.86)
                HStack(spacing: 6) {
                    Text(MeetingTimeline.length(meeting.duration)).monospacedDigit()
                    Text("·")
                    Text(MeetingsView.sourceName(meeting))
                    ForEach(badges, id: \.self) { badge in
                        switch badge {
                        case .needsNames:
                            let count = meeting.speakers.filter(MeetingTimeline.isUnnamed).count
                            HStack(spacing: 4) { StatusLight(state: .waiting); Text(count == 1 ? "1 voice to name" : "\(count) voices to name") }
                        case .failed:
                            HStack(spacing: 4) { StatusLight(state: .problem); Text(badge.title) }
                        case .recording, .processing:
                            HStack(spacing: 4) { StatusLight(state: .waiting); Text(badge.title) }
                        case .stoppedEarly, .noAudio:
                            Text("· " + badge.title)
                        }
                    }
                }
                .font(.meta).foregroundStyle(.secondary).lineLimit(1).padding(.top, 1)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(selected ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }

    private var preview: String {
        let names = meeting.speakers.filter { $0 != MeetingPostProcessor.microphoneLabel }
        if !names.isEmpty { return names.joined(separator: ", ") }
        switch meeting.state {
        case .recording: return "Recording now."
        case .processing, .interrupted: return "Sorting out who said what…"
        default:
            if !meeting.participants.isEmpty { return meeting.participants.joined(separator: ", ") }
            return meeting.speakers.isEmpty ? "Nobody said anything I could make out." : "Only you spoke."
        }
    }
}

/// The call app's icon, or the people-in-a-room glyph for a conversation recorded from the mic alone.
struct MeetingIcon: View {
    let meeting: StoredMeeting
    var size: CGFloat = 20

    var body: some View {
        if meeting.kind == .inPerson {
            glyph("figure.stand.line.dotted.figure.stand")
        } else if let bundle = CallApp.known.first(where: { $0.name == meeting.source })?.bundleIDs.first,
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
            AppIcon(bundleIdentifier: bundle, size: size)
        } else {
            glyph("video")
        }
    }

    private func glyph(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.quaternary)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.secondary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// No meetings yet: a rare surface, so the full goblin, asleep.
struct EmptyMeetingsView: View {
    var enabled = true

    var body: some View {
        VStack(spacing: 0) {
            PixelSprite(sprite: .closed, scale: 2)
                .overlay(alignment: .topTrailing) { PixelSprite(sprite: .zz, scale: 2).offset(x: 22, y: -2) }
            Text("No calls on tape yet.").font(.cardTitle).padding(.top, 18)
            Text(enabled ? "When Zoom, Meet or FaceTime picks up your mic, I'll ask before I record anything."
                         : "Turn on Meetings in General, and I'll ask before I record your next call.")
                .foregroundStyle(.secondary).frame(maxWidth: 380).padding(.top, 4)
            Text("Or record a conversation in the room from the menu bar. Meetings stay on this Mac.")
                .font(.meta).foregroundStyle(.secondary).frame(maxWidth: 380).padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
