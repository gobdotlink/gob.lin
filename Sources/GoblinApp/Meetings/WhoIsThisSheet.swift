import GoblinMeetings
import SwiftUI

/// Naming a voice, in a popover over the meeting's page so the transcript stays in reach: three clips to listen to,
/// names it could be and why, and a name field that completes from People and the call's list. With more than one
/// voice to name it walks through them ("1 of 3"), longest talker first. Renaming a named voice uses the same view
/// with the field ready. On a call that listed fewer people than I heard, the shared-laptop case waits behind a
/// disclosure. In person there's no participant list, so it offers That's Me first, as it does for someone heard
/// beside you on a call's mic.
struct WhoIsThisView: View {
    let meeting: StoredMeeting
    let lane: MeetingLane
    let lanes: [MeetingLane]
    let turns: [TranscriptTurn]
    let participants: MeetingParticipants
    /// Who this voice sounds like, from People or another voice of this meeting, closest first.
    var voiceSuggestions: [SpeakerSuggestion] = []
    /// Everyone People knows, for the name field's completions.
    var people: [String] = []
    /// Remember voices is on, so the name given here is learned.
    var remembersVoices = false
    /// Renaming a voice that already has a name: no suggestions, the field filled in.
    var renaming = false
    /// "1 of 3" while walking through several voices; nil for one.
    var position: (index: Int, count: Int)? = nil
    @ObservedObject var player: MeetingPlayer
    let onName: (String) -> Void
    var onSkip: (() -> Void)? = nil
    var onShowInTranscript: (Double) -> Void = { _ in }
    let onClose: () -> Void

    @State private var typed = ""
    @State private var sharedLaptop = false
    @State private var laptopOwner = ""
    @FocusState private var fieldFocused: Bool

    private var inPerson: Bool { meeting.kind == .inPerson }
    /// On a call, a voice from this Mac's mic that isn't you: someone in the room, who the call never listed.
    private var besideYou: Bool { !inPerson && lane.isOnMicrophoneOnly }
    private var clips: [TranscriptTurn] { MeetingTimeline.clips(of: lane.name, in: turns) }
    private var suggestions: [SpeakerSuggestion] {
        guard !renaming else { return [] }
        // A voice that sounds like someone comes first; the participant list fills in the rest.
        let listed = inPerson || besideYou ? [] : SpeakerSuggestions.suggestions(lanes: lanes, participants: participants)
        let heard = voiceSuggestions.filter { $0.name != lane.name }
        return Array((heard + listed.filter { item in !heard.contains { $0.name == item.name } }).prefix(3))
    }
    private var extraVoices: Int {
        renaming || inPerson || besideYou ? 0 : SpeakerSuggestions.extraVoices(lanes: lanes, participants: participants)
    }
    /// In person, nobody is You until someone says so; nor on a shared mic when I couldn't tell which voice was yours.
    private var offerMe: Bool {
        !renaming && (inPerson || besideYou) && !lanes.contains(where: \.isYou)
            && !voiceSuggestions.contains { $0.name == MeetingPostProcessor.microphoneLabel }
    }
    /// Whose laptop a second voice could have come through: named people heard through the call, not beside you.
    private var owners: [String] { lanes.filter { !$0.needsName && !$0.isYou && (inPerson || !$0.isOnMicrophoneOnly) }.map(\.name) }

    /// The choices in order, each a name and why; the first is the default button.
    private var choices: [(name: String, reason: String, button: String)] {
        var result: [(String, String, String)] = []
        if offerMe { result.append(("You", "The person at this Mac.", "That's Me")) }
        for suggestion in suggestions {
            let button = suggestion.name == MeetingPostProcessor.microphoneLabel ? "That's Me"
                : MeetingTimeline.isUnnamed(suggestion.name) ? "Same Voice"
                : "That's \(SpeakerSuggestions.firstName(suggestion.name))"
            result.append((suggestion.name, suggestion.reason, button))
        }
        return result
    }

    /// Names to complete the field with: People, the call's list and this meeting's other voices, matching what's typed.
    private var completions: [String] {
        let query = typedName
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        return (people + participants.all + lanes.filter { !$0.needsName && $0.id != lane.id }.map(\.name))
            .filter { $0.localizedCaseInsensitiveContains(query) && $0 != query && seen.insert($0.lowercased()).inserted }
            .prefix(6).map { $0 }
    }

    /// Whether the typed name is someone already known, or someone new.
    private var typedIsNew: Bool {
        let known = people + participants.all + lanes.map(\.name)
        return !typedName.isEmpty && !known.contains { $0.caseInsensitiveCompare(typedName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CapsHeader("Listen").padding(.top, 14).padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    if index > 0 { Hairline() }
                    clipRow(clip)
                }
            }
            if !choices.isEmpty {
                CapsHeader("Could be").padding(.top, 14).padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        if index > 0 { Hairline() }
                        choiceRow(choice, index: index)
                    }
                }
            }
            if extraVoices > 0 { sharedLaptopLine.padding(.top, 12) }
            nameField.padding(.top, 14)
            footer.padding(.top, 14)
        }
        .padding(18)
        .frame(width: 400)
        .onAppear {
            typed = renaming ? lane.name : ""
            if renaming || choices.isEmpty { fieldFocused = true }
        }
        .onChange(of: lane.id) { _, _ in
            // On to the next voice: the last one's clip stops, so it isn't heard over this one.
            player.stop()
            typed = renaming ? lane.name : ""
            sharedLaptop = false
        }
        .onDisappear { player.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(renaming ? "Rename \(lane.name)" : "Who's This?").font(.cardTitle)
                Text(lead).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let position, position.count > 1 {
                Text("\(position.index + 1) of \(position.count)").font(.meta).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var lead: String {
        let talked = MeetingTimeline.length(lane.talkSeconds)
        // A lane someone merged from both tracks came through neither alone.
        let mixed = Set(lane.stretches.map(\.track)).count > 1
        return inPerson || mixed ? "\(lane.name) talked for \(talked)."
            : besideYou ? "\(lane.name) talked for \(talked), through your mic."
            : "\(lane.name) talked for \(talked), through the \(meeting.source.isEmpty ? "call" : meeting.source) audio."
    }

    private var typedName: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func useTyped() {
        if !typedName.isEmpty { onName(typedName) }
    }

    private func clipRow(_ clip: TranscriptTurn) -> some View {
        let range = clip.start...max(clip.start, clip.end)
        let playing = player.playingRange == range
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { if playing { player.stop() } else { player.play(range, track: clip.track) } } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(GoblinBrand.moss, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .disabled(!player.hasAudio)
            .accessibilityLabel("\(playing ? "Stop" : "Play") clip at \(MeetingTimeline.clock(clip.start)): \(clip.text)")
            Text("“\(clip.text)”").font(.row).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button { onShowInTranscript(clip.start) } label: {
                Text(MeetingTimeline.clock(clip.start)).font(.meta).monospacedDigit().foregroundStyle(GoblinBrand.mossText)
                    .padding(.horizontal, 4).padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Transcript")
            .accessibilityLabel("Show \(MeetingTimeline.clock(clip.start)) in the transcript")
        }
        .padding(.vertical, 7)
        .background(playing ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous).inset(by: -4))
    }

    private func choiceRow(_ choice: (name: String, reason: String, button: String), index: Int) -> some View {
        HStack(spacing: 10) {
            Initials(name: choice.name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.name).font(.row.weight(.semibold))
                Text(choice.reason).font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if index == 0 {
                // The most likely name: Return takes it, unless a name is being typed.
                Button(choice.button) { onName(choice.name) }
                    .prominent()
                    .keyboardShortcut(typedName.isEmpty ? .defaultAction : KeyboardShortcut("1", modifiers: .command))
            } else {
                Button(choice.button) { onName(choice.name) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(choice.name). \(choice.reason)")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(sharedLaptop ? "Name the second voice" : renaming ? "Name" : "Someone else…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(useTyped)
                    .textInputSuggestions {
                        ForEach(completions, id: \.self) { name in Text(name).textInputCompletion(name) }
                    }
                    .accessibilityLabel("Name for \(lane.name)")
                Button(renaming ? "Rename" : "Use Name", action: useTyped)
                    .disabled(typedName.isEmpty || typedName == lane.name)
                    .keyboardShortcut(typedName.isEmpty ? nil : .defaultAction)
            }
            if typedIsNew, typedName != lane.name {
                Text("New person: I haven't heard of \(typedName) before.").font(.meta).foregroundStyle(.secondary)
            }
        }
    }

    /// The rare case of two people on one laptop: a quiet line until it's wanted.
    private var sharedLaptopLine: some View {
        DisclosureGroup(isExpanded: $sharedLaptop) {
            HStack {
                Text("Whose laptop").font(.status)
                Spacer()
                Picker("Whose laptop", selection: $laptopOwner) {
                    ForEach(owners, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                Button("Name as Guest") { onName(SpeakerSuggestions.guestName(on: laptopOwner)) }.disabled(laptopOwner.isEmpty)
            }
            .padding(.top, 6)
        } label: {
            Text("Two people on one laptop? \(meeting.source.isEmpty ? "The call" : meeting.source) listed \(participants.all.count == 1 ? "1 person" : "\(participants.all.count) people"), but I heard \(participants.all.count + extraVoices).")
                .font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: sharedLaptop) { _, open in if open, laptopOwner.isEmpty { laptopOwner = owners.first ?? "" } }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(remembersVoices ? "I'll remember this voice for next time." : "Remember voices is off, so I'll ask again next time.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onSkip, let position, position.count > 1 {
                Button("Skip", action: onSkip)
            }
            Button(position.map { $0.count > 1 } == true ? "Done" : "Not Now", action: onClose).keyboardShortcut(.cancelAction)
        }
    }
}
