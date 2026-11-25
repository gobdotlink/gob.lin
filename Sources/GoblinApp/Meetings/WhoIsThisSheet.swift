import GoblinMeetings
import SwiftUI

/// Naming a voice nobody recognised: three clips to listen to, names it could be and why, a free name, and,
/// on a call that listed fewer people than I heard, the shared-laptop case. In person there's no participant
/// list, so it offers "That's me" and a free name instead; the same for someone heard beside you on a call's mic.
struct WhoIsThisSheet: View {
    let meeting: StoredMeeting
    let lane: MeetingLane
    let lanes: [MeetingLane]
    let turns: [TranscriptTurn]
    let participants: MeetingParticipants
    /// Who this voice sounds like, from People or another voice of this meeting, closest first.
    var voiceSuggestions: [SpeakerSuggestion] = []
    /// Remember voices is on, so the name given here is learned.
    var remembersVoices = false
    @ObservedObject var player: MeetingPlayer
    let onName: (String) -> Void
    let onClose: () -> Void

    @State private var typed = ""
    @State private var sharedLaptop = false
    @State private var laptopOwner = ""

    private var inPerson: Bool { meeting.kind == .inPerson }
    /// On a call, a voice from this Mac's mic that isn't you: someone in the room, who the call never listed.
    private var besideYou: Bool { !inPerson && lane.isOnMicrophoneOnly }
    private var clips: [TranscriptTurn] { MeetingTimeline.clips(of: lane.name, in: turns) }
    private var suggestions: [SpeakerSuggestion] {
        // A voice that sounds like someone comes first; the participant list fills in the rest.
        let listed = inPerson || besideYou ? [] : SpeakerSuggestions.suggestions(lanes: lanes, participants: participants)
        let heard = voiceSuggestions.filter { $0.name != lane.name }
        return Array((heard + listed.filter { item in !heard.contains { $0.name == item.name } }).prefix(4))
    }
    private var extraVoices: Int {
        inPerson || besideYou ? 0 : SpeakerSuggestions.extraVoices(lanes: lanes, participants: participants)
    }
    /// In person, nobody is You until someone says so; nor on a shared mic when I couldn't tell which voice was yours.
    private var offerMe: Bool {
        (inPerson || besideYou) && !lanes.contains(where: \.isYou) && !voiceSuggestions.contains { $0.name == MeetingPostProcessor.microphoneLabel }
    }
    /// Whose laptop a second voice could have come through: named people heard through the call, not beside you.
    private var owners: [String] { lanes.filter { !$0.needsName && !$0.isYou && (inPerson || !$0.isOnMicrophoneOnly) }.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Who's this?").font(.cardTitle)
            Text(lead).font(.status).foregroundStyle(.secondary).padding(.top, 4).fixedSize(horizontal: false, vertical: true)

            CapsHeader("Listen").padding(.leading, 14).padding(.top, 16).padding(.bottom, 4)
            Plate(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        if index > 0 { Hairline().padding(.horizontal, 10) }
                        clipRow(clip)
                    }
                }
            }

            if extraVoices > 0 { sharedLaptopCard.padding(.top, 10) }

            if offerMe || !suggestions.isEmpty {
                CapsHeader("Could be").padding(.leading, 14).padding(.top, 16).padding(.bottom, 4)
                Plate(padding: 4) {
                    VStack(spacing: 0) {
                        if offerMe {
                            suggestionRow(name: "You", reason: "Names this voice You, the person at this Mac.", button: "That's Me")
                        }
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 || offerMe { Hairline().padding(.horizontal, 10) }
                            suggestionRow(name: suggestion.name, reason: suggestion.reason,
                                          button: suggestion.name == MeetingPostProcessor.microphoneLabel ? "That's Me"
                                              : MeetingTimeline.isUnnamed(suggestion.name) ? "Same Voice"
                                              : "That's \(SpeakerSuggestions.firstName(suggestion.name))")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(sharedLaptop ? "Name the second voice" : "That's…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useTyped)
                    .accessibilityLabel("Name for \(lane.name)")
                Button("Use Name", action: useTyped).disabled(typedName.isEmpty)
            }
            .padding(.top, 14)

            HStack(spacing: 10) {
                Text(remembersVoices ? "I'll remember this voice for next time." : "Remember voices is off, so I'll ask again next time.")
                    .font(.status).foregroundStyle(.secondary)
                Spacer()
                Button("Not Now", action: onClose).keyboardShortcut(.cancelAction)
            }
            .closingActions()
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 540)
        .onDisappear { player.stop() }
    }

    private var lead: String {
        let talked = MeetingTimeline.length(lane.talkSeconds)
        // A lane someone merged from both tracks came through neither alone.
        let mixed = Set(lane.stretches.map(\.track)).count > 1
        return inPerson || mixed ? "\(lane.name) talked for \(talked). Listen, then give them a name."
            : besideYou ? "\(lane.name) talked for \(talked), through your mic."
            : "\(lane.name) talked for \(talked), through the \(meeting.source.isEmpty ? "call" : meeting.source) audio."
    }

    private var typedName: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func useTyped() {
        if !typedName.isEmpty { onName(typedName) }
        else if sharedLaptop, !laptopOwner.isEmpty { onName(SpeakerSuggestions.guestName(on: laptopOwner)) }
    }

    private func clipRow(_ clip: TranscriptTurn) -> some View {
        let range = clip.start...max(clip.start, clip.end)
        let playing = player.playingRange == range
        return Button { if playing { player.stop() } else { player.play(range, track: clip.track) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(GoblinBrand.moss, in: Circle())
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text("“\(clip.text)”").font(.row).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(MeetingTimeline.clock(clip.start)).font(.meta).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(playing ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!player.hasAudio)
        .accessibilityLabel("\(playing ? "Stop" : "Play") clip at \(MeetingTimeline.clock(clip.start)): \(clip.text)")
    }

    private func suggestionRow(name: String, reason: String, button: String) -> some View {
        HStack(spacing: 10) {
            Initials(name: name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.row.weight(.semibold))
                Text(reason).font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button) { onName(name) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var sharedLaptopCard: some View {
        Plate(padding: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Button { sharedLaptop.toggle(); if laptopOwner.isEmpty { laptopOwner = owners.first ?? "" } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "laptopcomputer").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("One laptop had two voices").font(.row.weight(.semibold))
                            Text("\(meeting.source.isEmpty ? "The call" : meeting.source) listed \(participants.all.count == 1 ? "1 person" : "\(participants.all.count) people"), but I heard \(participants.all.count + extraVoices). I'll keep the laptop's owner and name this voice.")
                                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: sharedLaptop ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(sharedLaptop ? AnyShapeStyle(GoblinBrand.mossText) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(sharedLaptop ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sharedLaptop ? [.isSelected] : [])
                if sharedLaptop, !owners.isEmpty {
                    HStack {
                        Text("Whose laptop").font(.row)
                        Spacer()
                        Picker("Whose laptop", selection: $laptopOwner) {
                            ForEach(owners, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        Button("Name as Guest") { onName(SpeakerSuggestions.guestName(on: laptopOwner)) }.disabled(laptopOwner.isEmpty)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
    }
}
