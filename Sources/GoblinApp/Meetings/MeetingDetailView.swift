import AppKit
import GoblinMeetings
import SwiftUI

/// One meeting, as a document: its title, when and how long, a line with each voice, what waits on the person (voices
/// to name, words to check), then the notes. A bar under the page holds the player strip, the template and a field to
/// say what to change; the transcript opens beside the page. Every name, rewrite and spelling change can be undone.
struct MeetingDetailView: View {
    let meeting: StoredMeeting
    let store: MeetingStore
    @ObservedObject var notesModel: MeetingNotesModel
    /// Bumped by the page after a change elsewhere, so the detail reloads.
    let revision: Int
    /// What processing is doing right now: sorting out voices, or the speaker model's one-time download.
    var processingLine = MeetingCopy.processing(download: nil)
    /// Remember voices is on: names given here are learned, and Who's This? says so.
    var remembersVoices = false
    /// Everyone People knows, for completing names.
    var people: [String] = []
    /// Open Who's This? on the first voice without a name once the voices load, then say so with `onAskedWho`.
    var askWho = false
    var onAskedWho: () -> Void = {}
    /// The transcript beside the page; the toolbar toggles it too.
    @Binding var showsTranscript: Bool
    /// Adds spellings to the Dictionary; says what happened.
    var addToDictionary: ([String]) -> String? = { _ in nil }
    let onEdited: () -> Void

    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var player = MeetingPlayer()
    @State private var detail: MeetingDetail?
    @State private var lanes: [MeetingLane] = []
    @State private var naming: Naming?
    @State private var undo: Undo?
    @State private var failure: String?
    @State private var reloads = 0
    @State private var savedNotes: MeetingNotes?
    @State private var earlierNotes: [MeetingNotesHistory.Version] = []
    /// The title when the field got the keyboard: leaving it unchanged saves nothing.
    @State private var titleAtFocus: String?
    @State private var corrections: [MeetingNotes.SpellingFix] = []
    @State private var notesStale = false
    @State private var title = ""
    @State private var editingTemplates = false
    /// A moment to show in the transcript once it's open.
    @State private var transcriptFocus: MeetingTranscriptPanel.Focus?
    @FocusState private var titleFocused: Bool
    /// The last name change being saved. Each waits for the one before, so a voice renamed again before its first name
    /// is saved takes its Undo from the names that save left.
    @State private var saving: Task<Void, Never>?
    /// Counts name changes and Undos as they start. Only the latest one's save offers Undo: an older one's, restored
    /// after a newer save, would drop the newer name.
    @State private var edits = 0

    /// Who's This? or Rename, over the line of voices. With several voices to name it walks `queue` in order.
    struct Naming: Equatable {
        var lane: String
        var renaming = false
        var queue: [String] = []
        var index: Int { queue.firstIndex(of: lane) ?? 0 }
    }

    /// The moss line after a change: what changed, a second line when there's more to say, perhaps one more action,
    /// and Undo.
    struct Undo {
        var message: String
        var warning: String? = nil
        var action: String? = nil
        var onAction: (() -> Void)? = nil
        /// Nil for a line that only says what happened.
        var revert: (() -> Void)?
    }

    private var turns: [TranscriptTurn] { detail?.turns ?? [] }
    private var you: Set<String> { Set(lanes.filter(\.isYou).map(\.name)) }
    private var voiceColors: VoiceColors { VoiceColors(turns.map(\.speaker), you: you) }
    private var inPerson: Bool { meeting.kind == .inPerson }
    /// Voices waiting for a name, longest talker first: the order Who's This? walks them in.
    private var unnamed: [MeetingLane] {
        meeting.state == .ready ? lanes.filter(\.needsName).sorted { $0.talkSeconds > $1.talkSeconds } : []
    }

    var body: some View {
        // Once per redraw for the cast, the strip and the transcript, which redraw as playback moves.
        let colors = voiceColors
        return GeometryReader { geometry in
            // Beside the page while the notes keep a readable width; on a narrower window it floats over the page's edge.
            let beside = geometry.size.width - MeetingTranscriptPanel.width >= 380
            // One panel, always in the same place, so resizing across the two layouts keeps its search and scroll.
            HStack(spacing: 0) {
                document(colors)
                if showsTranscript, beside { Color.clear.frame(width: MeetingTranscriptPanel.width) }
            }
            .overlay(alignment: .trailing) {
                if showsTranscript {
                    transcriptPanel(colors)
                        .shadow(color: .black.opacity(beside ? 0 : 0.18), radius: 16, x: -4)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsTranscript)
        // The meeting's state too: processing that finishes in the background brings the transcript and voices.
        .task(id: "\(revision)-\(reloads)-\(meeting.state.rawValue)-\(notesModel.writing.contains(meeting.id))") {
            await load()
            if askWho {
                if !unnamed.isEmpty { who(nil) }
                if !lanes.isEmpty { onAskedWho() }
            }
        }
        .onDisappear { player.stop() }
        // Names, suggestions and marks changed elsewhere (learning voices, People) show here without reopening.
        .onReceive(NotificationCenter.default.publisher(for: .meetingsEdited)) { _ in reloads += 1 }
        // Asked again while this meeting is already showing.
        .onChange(of: askWho) { _, asked in
            guard asked, !unnamed.isEmpty else { return }
            who(nil)
            onAskedWho()
        }
        .sheet(isPresented: $editingTemplates) { NotesTemplatesSheet(model: notesModel) { editingTemplates = false } }
    }

    private func document(_ colors: VoiceColors) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    page(colors)
                        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 28)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
                .onChange(of: naming?.lane) { _, lane in
                    if lane != nil { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("cast", anchor: .top) } }
                }
            }
            if meeting.state != .recording, detail != nil {
                MeetingAskBar(meeting: meeting, notes: savedNotes, model: notesModel,
                              strip: MeetingPlayerStrip(duration: meeting.duration, lanes: lanes, marks: detail?.marks ?? [], colors: colors,
                                                        player: player,
                                                        audioDeleted: detail.map { $0.microphoneAudio == nil && $0.systemAudio == nil } ?? false),
                              onWrite: write, onEditTemplates: { editingTemplates = true })
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transcriptPanel(_ colors: VoiceColors) -> some View {
        MeetingTranscriptPanel(turns: turns, marks: detail?.marks ?? [], colors: colors, unnamed: Set(lanes.filter(\.needsName).map(\.name)),
                               you: you, finished: detail != nil && meeting.state == .ready,
                               player: player, summary: transcriptLine, focus: $transcriptFocus,
                               onName: { who($0) }, onCorrect: correct, onPutBack: putBack,
                               onCopy: { try? await store.markdown(meeting.id) }, onClose: { showsTranscript = false })
    }

    // MARK: Page

    private func page(_ colors: VoiceColors) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !lanes.isEmpty { cast(colors).padding(.top, 12).id("cast") }
            // While notes are written, the line's buttons wait: an Undo then would be overwritten by the write.
            if let undo { MeetingChangeLine(undo).disabled(notesModel.writing.contains(meeting.id)).padding(.top, 14) }
            notices
            MeetingNeedsYou(meeting: meeting, notes: savedNotes, turns: turns, unnamed: unnamed, model: notesModel, player: player,
                            onWho: { who(nil) }, addToDictionary: addToDictionary) {
                reloads += 1
                onEdited()
            }
            // Once loaded, so a meeting with notes doesn't flash its empty state for a moment.
            if detail != nil, meeting.state != .recording {
                MeetingNotesSection(meeting: meeting, notes: savedNotes, stale: notesStale, names: detail?.speakerNames ?? [:],
                                    typedNotes: detail?.typedNotes, earlier: earlierNotes, unnamed: Set(lanes.filter(\.needsName).map(\.name)),
                                    model: notesModel, player: player,
                                    onName: { who($0) }, onMoment: { showMoment($0) }, onDone: tick, onRestore: restoreNotes,
                                    onWrite: {
                                        // After a failure, Try Again asks for what failed; otherwise it's a plain write.
                                        let failed = notesModel.failures[meeting.id] != nil ? notesModel.failedRequests[meeting.id] : nil
                                        write(template: failed?.template, ask: failed?.ask)
                                    })
                    .padding(.top, 26)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain).font(.hero).lineLimit(1...3)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .onChange(of: titleFocused) { _, focused in
                    if focused { titleAtFocus = title } else { saveTitle() }
                }
                .accessibilityLabel("Meeting title")
                .help("Click to rename the meeting")
            Text(subtitle).font(.status).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.title) { _, now in if !titleFocused { title = now } }
    }

    private var subtitle: String {
        let when = meeting.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)) + " at "
            + meeting.startedAt.formatted(.dateTime.hour().minute())
        return [when, MeetingTimeline.length(meeting.duration), MeetingsView.sourceName(meeting)].joined(separator: " · ")
    }

    /// One name per voice, each with its colour and talk time and its own menu; then the participants nobody heard.
    private func cast(_ colors: VoiceColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRows(spacing: 4) {
                ForEach(lanes) { lane in
                    CastName(lane: lane, color: lane.isYou ? GoblinBrand.mossText : colors(lane.name) ?? .secondary,
                             guessed: detail?.namedFromVoice.contains(lane.name) ?? false,
                             offersWho: !(detail?.voiceSuggestions[lane.name] ?? []).isEmpty,
                             others: lanes.filter { $0.id != lane.id },
                             onWho: { who(lane.name) }, onRename: { naming = Naming(lane: lane.name, renaming: true) },
                             onMerge: { merge(lane, into: $0) }, onConfirm: { confirm(lane) },
                             onPlay: { if let first = lane.stretches.first { player.play(first.start...first.end, track: first.track) } },
                             hasAudio: player.hasAudio)
                }
            }
            .popover(isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), arrowEdge: .bottom) {
                namingView
            }
            let unheard = SpeakerSuggestions.unmatched(lanes: lanes, participants: detail?.participants ?? MeetingParticipants())
            if !inPerson, !unheard.isEmpty {
                Text("Also on the call: " + ListFormatter.localizedString(byJoining: unheard)).font(.meta).foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
    }

    @ViewBuilder private var namingView: some View {
        if let naming, let lane = lanes.first(where: { $0.name == naming.lane }) {
            WhoIsThisView(meeting: meeting, lane: lane, lanes: lanes, turns: turns,
                          participants: detail?.participants ?? MeetingParticipants(),
                          voiceSuggestions: detail?.voiceSuggestions[lane.name] ?? [], people: people, remembersVoices: remembersVoices,
                          renaming: naming.renaming,
                          position: naming.queue.count > 1 ? (naming.index, naming.queue.count) : nil,
                          player: player,
                          onName: { name in named(lane, name) },
                          onSkip: { advance(after: lane.name) },
                          onShowInTranscript: { clip in showMoment(clip.start, line: clip.id, play: false) },
                          onClose: { self.naming = nil })
        }
    }

    @ViewBuilder private var notices: some View {
        let badges = MeetingBadge.badges(meeting)
        Group {
            if let failure {
                notice { StatusRow(.problem, Text(failure)) { Button("Dismiss") { self.failure = nil } } }
            }
            switch meeting.state {
            case .recording:
                notice { StatusRow(.waiting, Text("Still recording. The named transcript comes when it stops.")) }
            case .processing, .interrupted:
                notice { StatusRow(.waiting, Text(processingLine)) { ProgressView().controlSize(.small) } }
            case .failed:
                notice {
                    StatusRow(.problem, Text("I kept the recording, but couldn't finish the transcript: \(meeting.failure ?? "unknown error")")) {
                        Button("Try Again") { retry() }
                    }
                }
            case .ready: EmptyView()
            }
            if meeting.state == .ready, let cleared = detail?.report?.namesCleared, !cleared.isEmpty {
                notice {
                    StatusRow(.waiting, Text(cleared.count == 1
                        ? "I sorted the voices out again and couldn't tell which one was \(cleared[0]), so that name is gone."
                        : "I sorted the voices out again and couldn't match \(cleared.count) names, so they're gone."))
                }
            }
            if badges.contains(.stoppedEarly), let sentence = MeetingBadge.stoppedEarlySentence(meeting) {
                notice {
                    Label(sentence, systemImage: meeting.stopReason == "sleep" ? "moon.zzz" : "stop.circle")
                        .font(.status).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            .padding(.top, 14)
    }

    /// How many lines, and how long the audio is kept.
    private var transcriptLine: String? {
        guard detail != nil else { return nil }
        let lines = turns.isEmpty ? nil : turns.count == 1 ? "1 line" : "\(turns.count) lines"
        let audio: String
        if !meeting.hasAudio { audio = "audio deleted" }
        else if meeting.starred { audio = "audio kept while starred" }
        else {
            let until = (meeting.endedAt ?? meeting.startedAt).addingTimeInterval(MeetingStore.audioRetention)
            audio = "audio until " + until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return [lines, audio].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Loading

    private func load() async {
        guard let next = try? await store.detail(meeting.id) else { return }
        let notes = try? await store.notes(meeting.id)
        let stale = (try? await store.notesAreStale(meeting.id)) ?? false
        let earlier = (try? await store.earlierNotes(meeting.id)) ?? []
        let fixes = (try? await store.corrections(meeting.id)) ?? []
        if detail?.microphoneAudio != next.microphoneAudio || detail?.systemAudio != next.systemAudio || detail == nil {
            player.load(microphone: next.microphoneAudio, system: next.systemAudio)
        }
        let first = detail == nil
        // All at once, so the page knows whether there are notes before it draws them.
        detail = next
        lanes = MeetingTimeline.lanes(next.turns, kind: meeting.kind)
        savedNotes = notes
        notesStale = stale
        earlierNotes = earlier
        corrections = fixes
        // A meeting that can't get notes opens on its transcript, the one thing to read, unless the person has chosen.
        if first, notes == nil, meeting.state == .ready, notesModel.settings == nil, !next.turns.isEmpty,
           UserDefaults.standard.object(forKey: MeetingsView.showsTranscriptKey) == nil { showsTranscript = true }
        // Named meanwhile (learning voices in the background): move on to the next voice still waiting, if any.
        if let asking = naming, !lanes.contains(where: { $0.name == asking.lane }) { advance(after: asking.lane) }
    }

    // MARK: Names

    /// Who's This?, on `name`, or on the first voice waiting; with more than one waiting, it walks through them all.
    private func who(_ name: String?) {
        let waiting = unnamed.map(\.name)
        guard let start = name ?? waiting.first else { return }
        let queue = [start] + waiting.filter { $0 != start }
        naming = Naming(lane: start, queue: lanes.first { $0.name == start }?.needsName == true ? queue : [start])
    }

    /// The next voice in the walk, or the end of it.
    private func advance(after name: String) {
        guard let current = naming else { return }
        let rest = current.queue.drop { $0 != name }.dropFirst()
        if let next = rest.first(where: { candidate in lanes.contains { $0.name == candidate && $0.needsName } }) {
            naming?.lane = next
        } else {
            naming = nil
        }
    }

    private func named(_ lane: MeetingLane, _ name: String) {
        let wasRenaming = naming?.renaming ?? false
        if wasRenaming { naming = nil } else { advance(after: lane.name) }
        rename(lane, to: name)
    }

    private func rename(_ lane: MeetingLane, to name: String) {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != lane.name else { return }
        // "sam" typed for another voice when a voice is already "Sam" joins that voice under its spelling; names are
        // matched exactly, so the typed spelling would leave two.
        let other = lanes.first { $0.id != lane.id && $0.name.caseInsensitiveCompare(typed) == .orderedSame }
        let trimmed = other?.name ?? typed
        guard trimmed != lane.name else { return }
        if let other { return merge(lane, into: other) }
        change(lane.needsName ? "Named \(lane.name) \(trimmed)." : "Renamed \(lane.name) to \(trimmed).",
               action: lane.needsName ? "Name \(lane.name) \(trimmed)" : "Rename \(lane.name)", showing: [lane.name: trimmed]) {
            try await store.renameSpeaker(meeting.id, from: lane.name, to: trimmed)
        }
    }

    /// Two voices become one. When someone on the call has no voice yet, the line saying so offers to name the merged
    /// voice after them instead: two voices the diarizer kept apart are more likely that person than the same one twice.
    private func merge(_ lane: MeetingLane, into other: MeetingLane) {
        // A voice heard beside you didn't come through the call, so it isn't anyone the call listed.
        let unmatched = inPerson || lane.isOnMicrophoneOnly ? []
            : SpeakerSuggestions.unmatched(lanes: lanes, participants: detail?.participants ?? MeetingParticipants())
        let missing = unmatched.count == 1 ? unmatched[0] : nil
        let warning = unmatched.isEmpty ? nil
            : "\(ListFormatter.localizedString(byJoining: unmatched)) \(unmatched.count == 1 ? "doesn't" : "don't") have a voice yet."
        change("\(lane.name) is now part of \(other.name).", warning: warning, action: "Merge \(lane.name)",
               offer: missing.map { name in ("Name \(lane.name) \(name) Instead", { before in split(lane.name, as: name, before: before) }) },
               showing: [lane.name: other.name]) {
            try await store.renameSpeaker(meeting.id, from: lane.name, to: other.name)
        }
    }

    /// A guess from People is right: it stops reading as one.
    private func confirm(_ lane: MeetingLane) {
        Task {
            do { try await store.confirmVoice(meeting.id, name: lane.name) } catch { failure = error.localizedDescription }
            reloads += 1
        }
    }

    /// Saves a name change with Undo on the page and in the Edit menu. `renamed` (shown name → new name) shows at once;
    /// the reload after saving replaces it, or puts the old names back if saving failed.
    private func change(_ message: String, warning: String? = nil, action: String, offer: (String, ([String: String]) -> Void)? = nil,
                        showing renamed: [String: String] = [:], _ edit: @escaping () async throws -> [TranscriptTurn]) {
        show(renamed)
        // The last change's Undo goes as this one starts: restoring its names after this save would drop this name.
        undo = nil
        edits += 1
        let number = edits
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                let before = try await store.speakerNames(meeting.id)
                _ = try await edit()
                // Every save goes on the Edit menu's stack, in the order they were saved; only the latest gets the line.
                registerUndo(action) { restoreNames(before) }
                if number == edits {
                    undo = Undo(message: message, warning: warning, action: offer?.0, onAction: offer.map { offer in { offer.1(before) } }) {
                        restoreNames(before)
                    }
                }
                failure = nil
            } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    /// The names, voices and transcript under the new names before they're saved, so a name given takes at once.
    private func show(_ renamed: [String: String]) {
        guard !renamed.isEmpty, var shown = detail else { return }
        for index in shown.turns.indices {
            if let name = renamed[shown.turns[index].speaker] { shown.turns[index].speaker = name }
        }
        detail = shown
        lanes = MeetingTimeline.lanes(shown.turns, kind: meeting.kind)
    }

    /// Undoes a merge, then names the voice that was merged in after the person who had no voice.
    private func split(_ lane: String, as name: String, before: [String: String]) {
        undo = nil
        change(MeetingTimeline.isUnnamed(lane) ? "Named \(lane) \(name)." : "Renamed \(lane) to \(name).", action: "Name \(lane) \(name)") {
            _ = try await store.setSpeakerNames(meeting.id, before)
            return try await store.renameSpeaker(meeting.id, from: lane, to: name)
        }
    }

    private func restoreNames(_ names: [String: String]) {
        undo = nil
        edits += 1
        let previous = saving
        saving = Task {
            await previous?.value
            do { _ = try await store.setSpeakerNames(meeting.id, names) } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    private func registerUndo(_ name: String, _ revert: @escaping () -> Void) {
        undoManager?.registerUndo(withTarget: notesModel) { _ in Task { @MainActor in revert() } }
        undoManager?.setActionName(name)
    }

    private func retry() {
        Task {
            do { _ = try await store.process(meeting.id) } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    private func saveTitle() {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Left as it was: nothing to save, and a title written meanwhile (by the notes) shows.
        guard typed != titleAtFocus?.trimmingCharacters(in: .whitespacesAndNewlines) else { title = meeting.title; return }
        guard typed != meeting.title else { return }
        Task {
            do { try await store.rename(meeting.id, title: typed) } catch { failure = error.localizedDescription }
            if typed.isEmpty { title = meeting.title }
            onEdited()
        }
    }

    // MARK: Notes

    /// Writes the notes, or rewrites them with a template or an ask on top of the one they follow.
    private func write(template: NotesTemplate?, ask: String?) {
        guard var settings = notesModel.settings else { return }
        settings.template = template ?? savedNotes?.written.template ?? notesModel.template
        settings.ask = ask
        let rewriting = savedNotes != nil
        // The notes being replaced, known by when they were written: the kept version with that date is the one to go
        // back to, whatever else writes meanwhile.
        let replacing = savedNotes?.written.createdAt
        let id = meeting.id
        notesModel.write(id, override: settings) { wrote in
            reloads += 1
            onEdited()
            // Only a write that saved notes says so and can be undone: one skipped or cancelled changed nothing.
            guard wrote, rewriting else { return }
            Task {
                guard let previous = try? await store.earlierNotes(id).first(where: { $0.notes.written.createdAt == replacing })?.id else { return }
                let message = ask.map { "Rewrote the notes: “\($0)”." } ?? "Rewrote the notes with the \(settings.template.name) template."
                undo = Undo(message: message, action: ask == nil ? nil : "Save as Template…",
                            onAction: ask.map { asked in { saveTemplate(asked, from: settings.template) } }) { restoreNotes(previous) }
                registerUndo("Rewrite Notes") { restoreNotes(previous) }
            }
        }
    }

    /// A rewrite that worked, kept: the template it followed with the ask added to its instructions.
    private func saveTemplate(_ ask: String, from base: NotesTemplate) {
        let name = ask.count > 32 ? String(ask.prefix(32)).trimmingCharacters(in: .whitespaces) + "…" : ask
        notesModel.saveTemplate(NotesTemplate(name: name, detail: "From \(meeting.title): “\(ask)”",
                                              instructions: base.instructions + "\n\nAlso: " + ask))
        undo = Undo(message: "Saved “\(name)” as a template. It's in the template menu now.", revert: nil)
    }

    private func restoreNotes(_ version: String) {
        // A rewrite still running would land on top of whatever is restored. Edit › Undo already took the action off
        // its stack, so it goes back on, to try again once the write is done.
        guard !notesModel.writing.contains(meeting.id) else {
            registerUndo("Rewrite Notes") { restoreNotes(version) }
            return
        }
        undo = nil
        Task {
            do { try await store.restoreNotes(meeting.id, version: version) } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    private func tick(_ index: Int, _ done: Bool) {
        guard let item = savedNotes?.actionItems[index] else { return }
        // At once on the page; the save follows, then the notes as saved.
        savedNotes?.actionItems[index].done = done ? true : nil
        Task {
            do { try await store.setActionItemDone(meeting.id, item: index, shown: item, done: done) } catch { failure = error.localizedDescription }
            reloads += 1
        }
    }

    /// A time in the notes or a clip: play from it and show it in the transcript.
    /// Both sides of the call play, so a reply on the other track is heard too.
    /// `line` is the exact line to show, when known (a clip); otherwise the line being said at that moment.
    private func showMoment(_ at: Double, line: UUID? = nil, play: Bool = true) {
        showsTranscript = true
        transcriptFocus = MeetingTranscriptPanel.Focus(at: at, line: line)
        if play, player.hasAudio { player.play(max(0, at - 1)...(at + 30)) }
    }

    // MARK: Spelling

    private func correct(_ heard: String, _ meant: String, _ toDictionary: Bool) async -> Bool {
        let lines = CorrectSpellingView.changedLines(heard: heard, meant: meant, in: turns)
        let previous: MeetingNotes.SpellingFix?
        do {
            previous = try await store.correctSpelling(meeting.id, heard: heard, meant: meant)
        } catch {
            failure = error.localizedDescription
            return false
        }
        let dictionary = toDictionary ? addToDictionary([meant]) : nil
        // Undo puts back exactly what was there: an earlier correction of the same words, or nothing.
        let revert = { restoreCorrection(heard, to: previous) }
        undo = Undo(message: "Corrected “\(heard)” to \(meant) in \(lines == 1 ? "1 line" : "\(lines) lines").", warning: dictionary, revert: revert)
        registerUndo("Correct “\(heard)”", revert)
        reloads += 1
        onEdited()
        return true
    }

    private func restoreCorrection(_ heard: String, to previous: MeetingNotes.SpellingFix?) {
        undo = nil
        Task {
            do { try await store.restoreCorrection(meeting.id, heard: heard, to: previous) } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    /// A respelled word back as heard: the person's own correction is turned down (so nothing respells it again), the
    /// notes' fix is put back. Undo, on the page and in the Edit menu, makes it again.
    private func putBack(_ fix: TranscriptTurn.Respelling) {
        let own = corrections.contains { $0.isActive && $0.heard.caseInsensitiveCompare(fix.heard) == .orderedSame }
        Task {
            do {
                if own { try await store.putBackCorrection(meeting.id, heard: fix.heard) }
                else { try await notesModel.dismissFix(meeting.id, heard: fix.heard) }
            } catch {
                failure = error.localizedDescription
                return
            }
            let again = {
                Task {
                    if own { _ = try? await store.correctSpelling(meeting.id, heard: fix.heard, meant: fix.meant) }
                    else { try? await notesModel.applyFix(meeting.id, heard: fix.heard) }
                    undo = nil
                    reloads += 1
                    onEdited()
                }
                return
            }
            undo = Undo(message: "Put back “\(fix.heard)” as heard.", revert: again)
            registerUndo("Put Back “\(fix.heard)”", again)
            reloads += 1
            onEdited()
        }
    }
}

/// A voice in the line under the title: its colour, name and talk time. One that needs a name has a dashed ring and
/// Who's This?; one I named from People has an open ring and asks to be confirmed in its menu.
struct CastName: View {
    let lane: MeetingLane
    let color: Color
    /// I named this voice because it sounded like someone in People, and nobody has said I'm right yet.
    var guessed = false
    /// A voice with a stand-in name ("Them") that sounds like someone: its menu offers Who's This? too.
    var offersWho = false
    let others: [MeetingLane]
    let onWho: () -> Void
    let onRename: () -> Void
    let onMerge: (MeetingLane) -> Void
    let onConfirm: () -> Void
    let onPlay: () -> Void
    var hasAudio = true

    @State private var hovering = false

    var body: some View {
        Group {
            if lane.needsName {
                Button(action: onWho) { face }
                    .buttonStyle(.plain)
                    .help("Who's This?")
                    .accessibilityLabel("\(lane.name), no name yet, \(MeetingTimeline.length(lane.talkSeconds)). Who's This?")
            } else {
                Menu {
                    if guessed {
                        Button("Yes, That's \(SpeakerSuggestions.firstName(lane.name))", action: onConfirm)
                        Button("No, Rename…", action: onRename)
                        Divider()
                    } else if offersWho {
                        Button("Who's This?…", action: onWho)
                    }
                    if !guessed { Button("Rename…", action: onRename) }
                    if !others.isEmpty {
                        Section("Merge Into") {
                            ForEach(others) { other in Button(other.name) { onMerge(other) } }
                        }
                    }
                    Divider()
                    Button("Play Their Voice", action: onPlay).disabled(!hasAudio || lane.stretches.isEmpty)
                } label: { face }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(guessed ? "I named this voice because it sounded like \(lane.name) in People. Am I right?" : "")
                .accessibilityLabel("\(lane.name), \(MeetingTimeline.length(lane.talkSeconds))\(guessed ? ", my guess from People" : "")")
            }
        }
        .onHover { hovering = $0 }
    }

    private var face: some View {
        HStack(spacing: 5) {
            dot
            Text(lane.name).font(.status.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            Text(MeetingTimeline.length(lane.talkSeconds)).font(.meta).foregroundStyle(.secondary).monospacedDigit()
            if lane.needsName {
                Text("Who's This?").font(.meta.weight(.medium)).foregroundStyle(GoblinBrand.mossText)
            } else if guessed {
                Text("guessed").font(.meta).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var dot: some View {
        if lane.needsName {
            Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5])).frame(width: 9, height: 9)
        } else if guessed {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
        } else {
            Circle().fill(color).frame(width: 9, height: 9)
        }
    }
}

/// Two letters in a circle. Decorative: the name beside it is read instead.
struct Initials: View {
    let name: String
    var unnamed = false
    var size: CGFloat = 20
    /// The voice's colour in this meeting (`VoiceColors`); grey where there's no meeting to colour it by.
    var color: Color?

    var body: some View {
        Text(unnamed ? "?" : Self.letters(name))
            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(color == nil ? .white : VoiceColors.onColor)
            .frame(width: size, height: size)
            .background(AnyShapeStyle(color ?? Color.secondary.opacity(0.7)), in: Circle())
            .accessibilityHidden(true)
    }

    static func letters(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// One person's words in the Sidekick's live captions, laid out like Messages: yours on the right in a moss tint,
/// everyone else's on the left in grey under their name in their voice colour.
struct TranscriptBubble: View {
    let text: String
    let isYou: Bool
    /// Shown above the bubble when the speaker changes; never for you, whose side already says it.
    var name: String?
    var nameColor: Color?
    var time: String?
    /// A live line whose voice isn't placed yet: quieter, with a dashed edge, until it's placed.
    var pending = false
    /// The words can be selected and copied.
    var selectable = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.transcriptBubble, style: .continuous)
        VStack(alignment: isYou ? .trailing : .leading, spacing: 3) {
            if name != nil || time != nil {
                HStack(spacing: 6) {
                    if let name { Text(name).fontWeight(.semibold).foregroundStyle(nameColor ?? Color.secondary) }
                    if let time { Text(time).monospacedDigit().foregroundStyle(.secondary) }
                }
                .font(.meta)
                .padding(.horizontal, 2)
            }
            Group {
                let words = Text(text).font(.transcript).lineSpacing(3).foregroundStyle(pending ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if selectable { words.textSelection(.enabled) } else { words }
            }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(isYou ? GoblinBrand.yourBubble : GoblinBrand.theirBubble, in: shape)
                .overlay { if pending { shape.strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])) } }
        }
        // A bubble never runs the full width, so the two sides stay apart.
        .padding(isYou ? .leading : .trailing, 40)
        .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
    }
}

/// Lays children left to right and wraps them onto new rows.
struct FlowRows: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// The moss line after a change: what changed, a second sentence when there's more to say, one more action when
/// there's a better way out, and Undo.
struct MeetingChangeLine: View {
    let message: String
    var warning: String? = nil
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    var onUndo: (() -> Void)?

    init(message: String, warning: String? = nil, action: String? = nil, onAction: (() -> Void)? = nil, onUndo: (() -> Void)? = nil) {
        self.message = message
        self.warning = warning
        self.action = action
        self.onAction = onAction
        self.onUndo = onUndo
    }

    init(_ undo: MeetingDetailView.Undo) {
        self.init(message: undo.message, warning: undo.warning, action: undo.action, onAction: undo.onAction, onUndo: undo.revert)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.status.weight(.semibold)).foregroundStyle(GoblinBrand.mossText).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.status)
                if let warning {
                    Text(warning).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let action, let onAction { Button(action, action: onAction).font(.status) }
            if let onUndo { Button("Undo", action: onUndo).font(.status) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(GoblinBrand.selection, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// An icon-only copy button for part of a page: the copy glyph, then a check for a moment once it's copied.
struct CopyIconButton: View {
    let title: String
    let text: () async -> String?
    @State private var copied = false

    var body: some View {
        Button {
            Task {
                guard let text = await text() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            IconButtonLabel(symbol: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(copied ? "Copied" : title)
    }
}
