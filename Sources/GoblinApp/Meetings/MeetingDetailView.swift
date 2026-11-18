import AppKit
import GoblinMeetings
import SwiftUI

/// One meeting: who was there, a timeline with a lane per voice and the marks above it, the named transcript,
/// the notes, when a notes model wrote them. Names change through `MeetingStore.renameSpeaker`, each with Undo.
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
    private var inPerson: Bool { meeting.kind == .inPerson }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !lanes.isEmpty { people.padding(.top, 14) }
                if let undo { undoBar(undo).padding(.top, 12) }
                notices
                // Without voices (nothing transcribed, or processing failed) the kept audio can still be played.
                if !lanes.isEmpty || (meeting.state != .recording && player.hasAudio) {
                    MeetingTimelineView(meeting: meeting, lanes: lanes, marks: detail?.marks ?? [], player: player,
                                        audioDeleted: detail.map { $0.microphoneAudio == nil && $0.systemAudio == nil } ?? false,
                                        onName: { who = $0 }, onRename: startRename, onMerge: merge)
                        .padding(.top, 16)
                }
                transcript.padding(.top, 20)
                notes.padding(.top, 20)
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
    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRows(spacing: 6) {
                ForEach(lanes) { lane in
                    SpeakerChip(lane: lane, others: lanes.filter { $0.id != lane.id },
                                namedFromVoice: detail?.namedFromVoice.contains(lane.name) ?? false,
                                offersWho: !(detail?.voiceSuggestions[lane.name] ?? []).isEmpty, onName: { who = lane },
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
        let unnamed = lanes.filter(\.needsName)
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
            if let first = unnamed.first, meeting.state == .ready {
                notice {
                    StatusRow(.waiting, Text(unnamed.count == 1 ? "I need a name for one voice." : "I need names for \(unnamed.count) voices.")) {
                        Button("Who's This?") { who = first }
                    }
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

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                CapsHeader("Transcript")
                if let kept = audioKeptLine { Text("· " + kept).font(.meta).foregroundStyle(.secondary) }
            }
            .padding(.leading, 6)
            if turns.isEmpty {
                Text(detail == nil ? " " : meeting.state == .ready ? "Nobody said anything I could make out." : "The transcript comes once I've sorted out who said what.")
                    .font(.status).foregroundStyle(.secondary).padding(.leading, 6)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    switch row {
                    case .turn(let turn): turnRow(turn)
                    case .mark(let mark, _): markRow(mark)
                    }
                }
            }
        }
    }

    private enum Row {
        case turn(TranscriptTurn), mark(MeetingMark, Int)
        var id: String {
            switch self {
            case .turn(let turn): turn.id.uuidString
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
            rows.append(.turn(turn))
        }
        rows += marks.map { .mark($0.0, $0.1) }
        return rows
    }

    private func turnRow(_ turn: TranscriptTurn) -> some View {
        let unnamed = MeetingTimeline.isUnnamed(turn.speaker)
        // The line under the playhead, while anything plays.
        let current = player.playing && player.time >= turn.start - 0.1 && player.time <= turn.end + 0.1
        return Button { if player.hasAudio { player.play(turn.start...turn.end, track: turn.track) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MeetingTimeline.clock(turn.start)).font(.meta).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Text(turn.speaker).font(.status.weight(.semibold))
                    .foregroundStyle(unnamed ? AnyShapeStyle(GoblinBrand.candle) : AnyShapeStyle(.secondary))
                    .lineLimit(1).frame(width: 96, alignment: .leading)
                Text(turn.text).font(.row).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
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

    private var audioKeptLine: String? {
        guard detail != nil else { return nil }
        guard meeting.hasAudio else { return "audio deleted" }
        if meeting.starred { return "audio kept while starred" }
        let until = (meeting.endedAt ?? meeting.startedAt).addingTimeInterval(MeetingStore.audioRetention)
        return "audio kept until " + until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var notes: some View {
        MeetingNotesSection(meeting: meeting, notes: savedNotes, stale: notesStale, names: detail?.speakerNames ?? [:],
                            model: notesModel, player: player) {
            reloads += 1
            onEdited()
        }
    }

    // MARK: Loading and editing

    private func load() async {
        guard let next = try? await store.detail(meeting.id) else { return }
        if detail?.microphoneAudio != next.microphoneAudio || detail?.systemAudio != next.systemAudio || detail == nil {
            player.load(microphone: next.microphoneAudio, system: next.systemAudio)
        }
        detail = next
        lanes = MeetingTimeline.lanes(next.turns, kind: meeting.kind)
        savedNotes = try? await store.notes(meeting.id)
        notesStale = (try? await store.notesAreStale(meeting.id)) ?? false
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
        let unmatched = inPerson ? [] : SpeakerSuggestions.unmatched(lanes: lanes, participants: detail?.participants ?? MeetingParticipants())
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
            Initials(name: lane.name, unnamed: lane.needsName)
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

    var body: some View {
        Text(unnamed ? "?" : Self.letters(name))
            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(unnamed ? AnyShapeStyle(LightState.waiting.color) : AnyShapeStyle(Color.secondary.opacity(0.7)), in: Circle())
            .accessibilityHidden(true)
    }

    static func letters(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
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
