import AppKit
import GoblinMeetings
import SwiftUI

/// One meeting: who was there, what needs the person (voices to name, misheard names), a timeline with a lane per
/// voice and the marks above it, then a switch between the notes, the named transcript and what the person typed.
/// Names change through `MeetingStore.renameSpeaker`, each with Undo.
struct MeetingDetailView: View {
    let meeting: StoredMeeting
    let store: MeetingStore
    @ObservedObject var notesModel: MeetingNotesModel
    /// Bumped by the page after a change elsewhere, so the detail reloads.
    let revision: Int
    /// What processing is doing right now: sorting out voices, or the speaker model's one-time download.
    var processingLine = MeetingCopy.processing(download: nil)
    /// Remember voices is on: names given here are learned, and Who's this? says so.
    var remembersVoices = false
    /// Open Who's this? on the first voice without a name once the voices load, then say so with `onAskedWho`.
    var askWho = false
    var onAskedWho: () -> Void = {}
    let onEdited: () -> Void

    @StateObject private var player = MeetingPlayer()
    @State private var detail: MeetingDetail?
    @State private var lanes: [MeetingLane] = []
    @State private var who: MeetingLane?
    @State private var renaming: MeetingLane?
    @State private var newName = ""
    @State private var undo: Undo?
    @State private var failure: String?
    @State private var reloads = 0
    @State private var savedNotes: MeetingNotes?
    @State private var notesStale = false
    /// The tab picked by hand. Until then: Notes once there are notes or they're being written, else Transcript.
    @State private var pickedTab: Tab?

    enum Tab: Hashable { case notes, transcript, typed }

    struct Undo: Equatable {
        var message: String
        var names: [String: String]
        /// After a merge while someone on the call had no voice: who, and the merged voice's name before, so
        /// "That's Sam" can split it back out under their name.
        var missing: String? = nil
        var mergedFrom: String? = nil
        var warning: String? = nil
    }

    private var turns: [TranscriptTurn] { detail?.turns ?? [] }
    private var voiceColors: VoiceColors { VoiceColors(turns.map(\.speaker), you: Set(lanes.filter(\.isYou).map(\.name))) }
    private var inPerson: Bool { meeting.kind == .inPerson }

    var body: some View {
        // Once per redraw for the chips, the timeline and the transcript, which redraw as playback moves.
        let colors = voiceColors
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !lanes.isEmpty { people(colors).padding(.top, 14) }
                if let undo { undoBar(undo).padding(.top, 12) }
                notices
                MeetingNeedsYou(meeting: meeting, notes: savedNotes, unnamed: meeting.state == .ready ? lanes.filter(\.needsName) : [],
                                model: notesModel, onWho: { who = $0 }) {
                    reloads += 1
                    onEdited()
                }
                // Without voices (nothing transcribed, or processing failed) the kept audio can still be played.
                if !lanes.isEmpty || (meeting.state != .recording && player.hasAudio) {
                    MeetingTimelineView(meeting: meeting, lanes: lanes, marks: detail?.marks ?? [], colors: colors, player: player,
                                        audioDeleted: detail.map { $0.microphoneAudio == nil && $0.systemAudio == nil } ?? false,
                                        onName: { who = $0 }, onRename: startRename, onMerge: merge)
                        .padding(.top, 16)
                }
                // Once loaded, so a meeting with notes doesn't open on its transcript for a moment.
                if detail != nil {
                    Group {
                        switch tab {
                        case .notes: notes
                        case .transcript: transcript(colors)
                        case .typed: yourNotes(detail?.typedNotes ?? "")
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .padding(28)
        }
        // The meeting's state too: processing that finishes in the background brings the transcript and voices.
        .task(id: "\(revision)-\(reloads)-\(meeting.state.rawValue)-\(notesModel.writing.contains(meeting.id))") {
            await load()
            if askWho, let lane = lanes.first(where: \.needsName) {
                who = lane
                onAskedWho()
            } else if askWho, !lanes.isEmpty {
                onAskedWho()
            }
        }
        .onDisappear { player.stop() }
        // Names, suggestions and marks changed elsewhere (learning voices, People) show here without reopening.
        .onReceive(NotificationCenter.default.publisher(for: .meetingsEdited)) { _ in reloads += 1 }
        // Asked again while this meeting is already showing.
        .onChange(of: askWho) { _, asked in
            guard asked, let lane = lanes.first(where: \.needsName) else { return }
            who = lane
            onAskedWho()
        }
        .sheet(item: $who) { lane in
            WhoIsThisSheet(meeting: meeting, lane: lane, lanes: lanes, turns: turns,
                           participants: detail?.participants ?? MeetingParticipants(),
                           voiceSuggestions: detail?.voiceSuggestions[lane.name] ?? [], remembersVoices: remembersVoices, player: player,
                           onName: { name in who = nil; rename(lane, to: name) }, onClose: { who = nil })
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let lane = renaming { rename(lane, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Every line of this voice takes the new name.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            MeetingIcon(meeting: meeting, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.cardTitle).lineLimit(2)
                Text(subtitle).font(.meta).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let when = meeting.startedAt.formatted(.dateTime.weekday(.wide).month().day()) + " at "
            + meeting.startedAt.formatted(.dateTime.hour().minute())
        return [when, MeetingTimeline.length(meeting.duration), MeetingsView.sourceName(meeting)].joined(separator: " · ")
    }

    /// One chip per voice, then the rest of the participant list.
    private func people(_ colors: VoiceColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRows(spacing: 6) {
                ForEach(lanes) { lane in
                    SpeakerChip(lane: lane, others: lanes.filter { $0.id != lane.id },
                                namedFromVoice: detail?.namedFromVoice.contains(lane.name) ?? false,
                                offersWho: !(detail?.voiceSuggestions[lane.name] ?? []).isEmpty, color: colors(lane.name),
                                onName: { who = lane },
                                onRename: { startRename(lane) }, onMerge: { merge(lane, into: $0) })
                }
            }
            let unheard = SpeakerSuggestions.unmatched(lanes: lanes, participants: detail?.participants ?? MeetingParticipants())
            if !inPerson, !unheard.isEmpty {
                Text("Also in the call: " + unheard.joined(separator: ", ")).font(.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func undoBar(_ undo: Undo) -> some View {
        MeetingChangeLine(message: undo.message, warning: undo.warning, missing: undo.mergedFrom == nil ? nil : undo.missing,
                          onSplit: { if let lane = undo.mergedFrom, let missing = undo.missing { split(undo, lane: lane, as: missing) } },
                          onUndo: { restore(undo) })
    }

    @ViewBuilder private var notices: some View {
        let badges = MeetingBadge.badges(meeting)
        Group {
            if let failure {
                notice { StatusRow(.problem, Text(failure)) }
            }
            switch meeting.state {
            case .recording:
                notice { StatusRow(.waiting, Text("Still recording. The named transcript comes when it stops.")) }
            case .processing, .interrupted:
                notice { StatusRow(.waiting, Text(processingLine)) }
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
            .background(GoblinBrand.caseBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .padding(.top, 12)
    }

    // MARK: Tabs

    private var tab: Tab {
        if let pickedTab, pickedTab != .typed || detail?.typedNotes != nil { return pickedTab }
        return savedNotes != nil || notesModel.writing.contains(meeting.id) ? .notes : .transcript
    }

    private var tabs: some View {
        Picker("Show", selection: Binding(get: { tab }, set: { pickedTab = $0 })) {
            Text("Notes").tag(Tab.notes)
            Text("Transcript").tag(Tab.transcript)
            if detail?.typedNotes != nil { Text("Your notes").tag(Tab.typed) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .tint(GoblinBrand.moss)
    }

    // MARK: Transcript

    private func transcript(_ colors: VoiceColors) -> some View {
        let you = Set(lanes.filter(\.isYou).map(\.name))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                tabs
                Spacer(minLength: 8)
                if let line = transcriptLine { Text(line).font(.meta).foregroundStyle(.secondary).lineLimit(1) }
                if !turns.isEmpty {
                    CopyIconButton(title: "Copy Transcript") { try? await store.markdown(meeting.id) }
                }
            }
            if let savedNotes, meeting.state == .ready {
                MeetingFixedNamesLine(meetingID: meeting.id, notes: savedNotes, model: notesModel) {
                    reloads += 1
                    onEdited()
                }
            }
            if turns.isEmpty {
                Text(detail == nil ? " " : meeting.state == .ready ? "Nobody said anything I could make out." : "The transcript comes once I've sorted out who said what.")
                    .font(.status).foregroundStyle(.secondary).padding(.leading, 6)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    switch row {
                    case .turn(let turn, let showsName): turnRow(turn, showsName: showsName, colors: colors, you: you)
                    case .mark(let mark, _): markRow(mark)
                    }
                }
            }
        }
    }

    private enum Row {
        /// `showsName` when the speaker changed since the row before.
        case turn(TranscriptTurn, showsName: Bool), mark(MeetingMark, Int)
        var id: String {
            switch self {
            case .turn(let turn, _): turn.id.uuidString
            case .mark(let mark, let index): "mark-\(index)-\(mark.t)"
            }
        }
    }

    /// Turns with each mark placed before the first turn that starts after it.
    private var rows: [Row] {
        var marks = (detail?.marks ?? []).enumerated().map { ($0.element, $0.offset) }[...]
        var rows: [Row] = []
        for turn in turns {
            while let next = marks.first, next.0.t <= turn.start { rows.append(.mark(next.0, next.1)); marks.removeFirst() }
            let previous: String? = if case .turn(let last, _) = rows.last { last.speaker } else { nil }
            rows.append(.turn(turn, showsName: previous != turn.speaker))
        }
        rows += marks.map { .mark($0.0, $0.1) }
        return rows
    }

    private func turnRow(_ turn: TranscriptTurn, showsName: Bool, colors: VoiceColors, you: Set<String>) -> some View {
        let isYou = you.contains(turn.speaker)
        // The line under the playhead, while anything plays.
        let current = player.playing && player.time >= turn.start - 0.1 && player.time <= turn.end + 0.1
        return Button { if player.hasAudio { player.play(turn.start...turn.end, track: turn.track) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MeetingTimeline.clock(turn.start)).font(.meta).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                TranscriptBubble(text: turn.text, isYou: isYou, name: showsName && !isYou ? turn.speaker : nil,
                                 nameColor: colors(turn.speaker), selectable: true)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(current ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.speaker) at \(MeetingTimeline.clock(turn.start)): \(turn.text)")
        .accessibilityHint(player.hasAudio ? "Plays this line" : "")
    }

    private func markRow(_ mark: MeetingMark) -> some View {
        HStack(spacing: 8) {
            Text(MeetingTimeline.clock(mark.t)).font(.meta).monospacedDigit().frame(width: 44, alignment: .leading)
            Label(mark.label ?? "Marked", systemImage: "flag.fill").font(.status)
        }
        .foregroundStyle(GoblinBrand.candle)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mark at \(MeetingTimeline.clock(mark.t)): \(mark.label ?? "no label")")
    }

    /// How many lines, and how long the audio is kept.
    private var transcriptLine: String? {
        let lines = turns.isEmpty ? nil : turns.count == 1 ? "1 line" : "\(turns.count) lines"
        let parts = [lines, audioKeptLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var audioKeptLine: String? {
        guard detail != nil else { return nil }
        guard meeting.hasAudio else { return "audio deleted" }
        if meeting.starred { return "audio kept while starred" }
        let until = (meeting.endedAt ?? meeting.startedAt).addingTimeInterval(MeetingStore.audioRetention)
        return "audio kept until " + until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var notes: some View {
        MeetingNotesSection(meeting: meeting, notes: savedNotes, stale: notesStale, names: detail?.speakerNames ?? [:],
                            typedNotes: detail?.typedNotes, model: notesModel, player: player, tabs: AnyView(tabs)) {
            reloads += 1
            onEdited()
        }
    }

    /// What the person typed in the Sidekick during the call, as typed.
    private func yourNotes(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                tabs
                Spacer(minLength: 8)
                CopyIconButton(title: "Copy Your Notes") { text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Plate {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.row).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    // MARK: Loading and editing

    private func load() async {
        guard let next = try? await store.detail(meeting.id) else { return }
        let notes = try? await store.notes(meeting.id)
        let stale = (try? await store.notesAreStale(meeting.id)) ?? false
        if detail?.microphoneAudio != next.microphoneAudio || detail?.systemAudio != next.systemAudio || detail == nil {
            player.load(microphone: next.microphoneAudio, system: next.systemAudio)
        }
        // All at once, so the page picks its first tab knowing whether there are notes.
        detail = next
        lanes = MeetingTimeline.lanes(next.turns, kind: meeting.kind)
        savedNotes = notes
        notesStale = stale
        // Named meanwhile (learning voices in the background): Who's this? for a voice that's gone would name nothing.
        if let asking = who, !lanes.contains(where: { $0.name == asking.name && $0.needsName == asking.needsName }) { who = nil }
    }

    private func startRename(_ lane: MeetingLane) {
        newName = lane.needsName ? "" : lane.name
        renaming = lane
    }

    private func rename(_ lane: MeetingLane, to name: String) {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != lane.name else { return }
        // "sam" typed for another voice when a lane is already "Sam" joins that lane under its spelling; names are
        // matched exactly, so the typed spelling would leave two lanes.
        let other = lanes.first { $0.id != lane.id && $0.name.caseInsensitiveCompare(typed) == .orderedSame }
        let trimmed = other?.name ?? typed
        guard trimmed != lane.name else { return }
        if let other { return merge(lane, into: other) }
        change(lane.needsName ? "Named \(lane.name) \(trimmed)." : "Renamed \(lane.name) to \(trimmed).") {
            try await store.renameSpeaker(meeting.id, from: lane.name, to: trimmed)
        }
    }

    /// Two voices become one. When someone on the call has no voice yet, the line saying so offers them instead:
    /// two voices the diarizer kept apart are more likely that person than the same one twice.
    private func merge(_ lane: MeetingLane, into other: MeetingLane) {
        // A voice heard beside you didn't come through the call, so it isn't anyone the call listed.
        let unmatched = inPerson || lane.isOnMicrophoneOnly ? []
            : SpeakerSuggestions.unmatched(lanes: lanes, participants: detail?.participants ?? MeetingParticipants())
        let warning = SpeakerSuggestions.mergeWarning(unmatched: unmatched)
        change("Merged \(lane.name) into \(other.name).", missing: unmatched.count == 1 ? unmatched[0] : nil,
               mergedFrom: warning == nil ? nil : lane.name, warning: warning) {
            try await store.renameSpeaker(meeting.id, from: lane.name, to: other.name)
        }
    }

    private func change(_ message: String, missing: String? = nil, mergedFrom: String? = nil, warning: String? = nil,
                        _ edit: @escaping () async throws -> [TranscriptTurn]) {
        Task {
            do {
                let before = try await store.speakerNames(meeting.id)
                _ = try await edit()
                undo = Undo(message: message, names: before, missing: missing, mergedFrom: mergedFrom, warning: warning)
                failure = nil
            } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }

    /// Undoes a merge and names the voice that was merged in after the person who had no voice.
    private func split(_ undo: Undo, lane: String, as name: String) {
        self.undo = nil
        change(MeetingTimeline.isUnnamed(lane) ? "Named \(lane) \(name)." : "Renamed \(lane) to \(name).") {
            _ = try await store.setSpeakerNames(meeting.id, undo.names)
            return try await store.renameSpeaker(meeting.id, from: lane, to: name)
        }
    }

    private func restore(_ undo: Undo) {
        Task {
            do { _ = try await store.setSpeakerNames(meeting.id, undo.names) } catch { failure = error.localizedDescription }
            self.undo = nil
            reloads += 1
            onEdited()
        }
    }

    private func retry() {
        Task {
            do { _ = try await store.process(meeting.id) } catch { failure = error.localizedDescription }
            reloads += 1
            onEdited()
        }
    }
}

/// A voice, by name and talk time. Unnamed voices are amber and open "Who's this?"; named ones open Rename and Merge.
struct SpeakerChip: View {
    let lane: MeetingLane
    let others: [MeetingLane]
    /// I named this voice because it sounded like someone in People.
    var namedFromVoice = false
    /// A voice with a stand-in name ("Them") that sounds like someone: its menu offers Who's This? too.
    var offersWho = false
    var color: Color?
    let onName: () -> Void
    let onRename: () -> Void
    let onMerge: (MeetingLane) -> Void

    var body: some View {
        Group {
            if lane.needsName {
                Button(action: onName) { face }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lane.name), no name yet. Who's this?")
            } else {
                Menu {
                    if offersWho { Button("Who's This?…", action: onName) }
                    Button("Rename…", action: onRename)
                    if !others.isEmpty {
                        Section("Merge Into") {
                            ForEach(others) { other in Button(other.name) { onMerge(other) } }
                        }
                    }
                } label: { face }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(namedFromVoice ? "I knew this voice from People. Rename it if I got it wrong." : "")
                .accessibilityLabel("\(lane.name), talked \(MeetingTimeline.length(lane.talkSeconds))\(namedFromVoice ? ", named from their voice" : "")")
            }
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            Initials(name: lane.name, unnamed: lane.needsName, color: color)
            Text(lane.name).font(.status.weight(.medium)).lineLimit(1)
            if namedFromVoice {
                Image(systemName: "waveform").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(lane.needsName ? "Who's this?" : MeetingTimeline.length(lane.talkSeconds))
                .font(.meta).foregroundStyle(lane.needsName ? AnyShapeStyle(GoblinBrand.candle) : AnyShapeStyle(.secondary)).monospacedDigit()
        }
        .padding(.leading, 3).padding(.trailing, 9).frame(height: 26)
        .background(lane.needsName ? AnyShapeStyle(LightState.waiting.color.opacity(0.14)) : AnyShapeStyle(GoblinBrand.caseBackground.opacity(0.7)),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(lane.needsName ? LightState.waiting.color.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

/// Two letters in a circle, or "?" for a voice with no name. Decorative: the name beside it is read instead.
struct Initials: View {
    let name: String
    var unnamed = false
    var size: CGFloat = 20
    /// The voice's colour in this meeting (`VoiceColors`); grey where there's no meeting to colour it by.
    var color: Color?

    var body: some View {
        Text(unnamed ? "?" : Self.letters(name))
            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(color == nil || unnamed ? .white : VoiceColors.onColor)
            .frame(width: size, height: size)
            .background(unnamed ? AnyShapeStyle(LightState.waiting.color) : AnyShapeStyle(color ?? Color.secondary.opacity(0.7)), in: Circle())
            .accessibilityHidden(true)
    }

    static func letters(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// One person's words in a transcript, laid out like Messages: yours on the right in a moss tint, everyone else's on
/// the left in grey under their name in their voice colour. The Sidekick and a finished meeting both draw these.
struct TranscriptBubble: View {
    let text: String
    let isYou: Bool
    /// Shown above the bubble when the speaker changes; never for you, whose side already says it.
    var name: String?
    var nameColor: Color?
    var time: String?
    /// A live line whose voice isn't placed yet: quieter, with a dashed edge, until it's placed.
    var pending = false
    /// The words can be selected and copied; the name above them can't, so a drag over it still plays the line.
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

/// The moss-tinted line after a rename or merge: what changed, with Undo. After a merge while someone on the call had
/// no voice, a second line says who, with "That's <name>" to name the merged voice after them instead.
struct MeetingChangeLine: View {
    let message: String
    var warning: String? = nil
    var missing: String? = nil
    var onSplit: () -> Void = {}
    let onUndo: () -> Void

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
            if let missing {
                Button("That's \(SpeakerSuggestions.firstName(missing))", action: onSplit).font(.status)
            }
            Button("Undo", action: onUndo).font(.status)
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
