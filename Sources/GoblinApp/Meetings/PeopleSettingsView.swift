import AppKit
import GoblinMeetings
import SwiftUI

/// Settings → People: everyone gob.lin knows by voice, and the meetings each voice came from. A voice is learned when
/// someone is named in a meeting (or a 1:1 names them), and names them in the next calls and conversations.
struct PeopleSettingsView: View {
    @ObservedObject var meetings: MeetingsController
    /// Opens a meeting on the Meetings page.
    let openMeeting: (String) -> Void

    @StateObject private var player = MeetingPlayer()
    @State private var playing: UUID?
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var forgetting: Person?

    private var me: Person? { meetings.people.first(where: \.isMe) }
    private var others: [Person] { meetings.people.filter { !$0.isMe } }

    var body: some View {
        Group {
            Section {
                voicesStatus
                    // On a row, not the page: a section's modifiers reach its small-caps header too.
                    .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                        TextField("Name", text: $newName)
                        Button("Rename") {
                            if let person = renaming { meetings.editPeople { try $0.rename(person.id, to: newName) } }
                            renaming = nil
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel", role: .cancel) { renaming = nil }
                    } message: {
                        Text("Meetings already named keep their names; I use the new one from now on.")
                    }
                    .confirmationDialog(forgetting.map { $0.isMe ? "Forget your voice?" : "Forget \($0.name)?" } ?? "",
                                        isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                        Button("Forget", role: .destructive) {
                            if let person = forgetting {
                                stopPlaying(any: person.samples)
                                meetings.editPeople { try $0.remove(person.id) }
                            }
                            forgetting = nil
                        }
                        Button("Cancel", role: .cancel) { forgetting = nil }
                    } message: {
                        Text("I'll delete every sample of this voice. Meetings keep the names they have.")
                    }
                    .onAppear { meetings.refreshPeople() }
                    .onDisappear { player.stop() }
            } header: { CapsHeader("Voices") } footer: {
                Text("A voiceprint is a short list of numbers made from a few seconds of someone's voice, enough to recognise it again. I make one for each voice you name in a meeting, in calls and in the room, and keep it on this Mac. Deleting a meeting forgets what it taught me; turning Remember voices off forgets everyone.")
            }

            if let me {
                Section {
                    PersonRow(person: me, title: "\(me.name) (you)", others: [], player: player, playing: $playing,
                              onRename: { start(rename: me) }, onMerge: { _ in }, onForget: { forgetting = me },
                              onRemoveSample: { sample in remove(sample, from: me) }, openMeeting: openMeeting, root: root)
                } header: { CapsHeader("You") }
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { person in
                        // You're a merge destination too: a voice named after you in the room before People knew it was you.
                        PersonRow(person: person, title: person.name,
                                  others: (me.map { [$0] } ?? []) + others.filter { $0.id != person.id }, player: player,
                                  playing: $playing, onRename: { start(rename: person) },
                                  onMerge: { target in meetings.editPeople { try $0.merge(person.id, into: target.id) } },
                                  onForget: { forgetting = person }, onRemoveSample: { sample in remove(sample, from: person) },
                                  openMeeting: openMeeting, root: root)
                    }
                } header: { CapsHeader("People") }
            }
        }
    }

    @ViewBuilder private var voicesStatus: some View {
        if let failure = meetings.peopleEditFailure {
            StatusRow(.problem, Text("That change didn't save. \(failure)")) {
                Button("OK") { meetings.peopleEditFailure = nil }
            }
        } else if !meetings.rememberVoices {
            StatusRow(.off, Text("Remember voices is off, so I don't keep anyone's voice.")) {
                Button("Turn On") { meetings.setRememberVoices(true) }
            }
        } else if meetings.learningVoices {
            StatusRow(.waiting, Text("Learning voices from the meetings you've already named…"))
        } else if meetings.people.isEmpty {
            StatusRow(.ready, Text("I don't know anyone's voice yet. Name a voice in a meeting and I'll remember it."))
        } else {
            StatusRow(.ready, Text(summary))
        }
    }

    private var root: URL { meetings.library.store.root }

    private var summary: String {
        let count = others.count
        return count == 0 ? "I only know your voice so far." : "I know \(count) \(count == 1 ? "person" : "people") by voice."
    }

    private func start(rename person: Person) {
        newName = person.name
        renaming = person
    }

    private func remove(_ sample: VoiceSample, from person: Person) {
        stopPlaying(any: [sample])
        meetings.editPeople { try $0.removeSample(sample.id, from: person.id) }
    }

    /// Playback of a sample that's about to go stops with it, rather than outliving its row.
    private func stopPlaying(any samples: [VoiceSample]) {
        guard let current = playing, samples.contains(where: { $0.id == current }) else { return }
        player.stop()
        playing = nil
    }
}

/// A person: name and how often they were heard, opening to the meetings their voice came from.
private struct PersonRow: View {
    let person: Person
    let title: String
    let others: [Person]
    @ObservedObject var player: MeetingPlayer
    @Binding var playing: UUID?
    let onRename: () -> Void
    let onMerge: (Person) -> Void
    let onForget: () -> Void
    let onRemoveSample: (VoiceSample) -> Void
    let openMeeting: (String) -> Void
    let root: URL

    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    ForEach(person.samples.sorted { $0.heardAt > $1.heardAt }) { sample in
                        SampleRow(sample: sample, root: root, player: player, playing: $playing,
                                  onRemove: { onRemoveSample(sample) }, onOpen: { openMeeting(sample.meetingID) })
                    }
                }
                .padding(.leading, 16).padding(.top, 6)
            } label: {
                HStack(spacing: 10) {
                    Initials(name: person.name, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(caption).font(.meta).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Menu {
                Button("Rename…", action: onRename)
                if !others.isEmpty {
                    Section("Merge Into") { ForEach(others) { other in Button(other.name) { onMerge(other) } } }
                }
                Divider()
                Button(person.isMe ? "Forget My Voice…" : "Forget \(SpeakerSuggestions.firstName(person.name))…", role: .destructive, action: onForget)
            } label: { IconButtonLabel(symbol: "ellipsis") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for \(person.name)")
        }
    }

    private var caption: String {
        let meetings = person.meetingIDs.count
        var parts = ["\(meetings) \(meetings == 1 ? "meeting" : "meetings")", MeetingTimeline.length(person.secondsHeard) + " heard"]
        if let last = person.lastHeard { parts.append("last heard " + last.formatted(.dateTime.day().month())) }
        return parts.joined(separator: " · ")
    }
}

/// One meeting's sample of a voice: play it while the meeting keeps its audio, open the meeting, or remove it.
private struct SampleRow: View {
    let sample: VoiceSample
    let root: URL
    @ObservedObject var player: MeetingPlayer
    @Binding var playing: UUID?
    let onRemove: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    private var audio: URL { root.appendingPathComponent(sample.meetingID).appendingPathComponent(MeetingStorage.audioFile(sample.track)) }
    private var hasAudio: Bool { FileManager.default.fileExists(atPath: audio.path) }
    private var isPlaying: Bool { playing == sample.id && player.playingRange != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(hasAudio ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(Color.secondary.opacity(0.4)), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasAudio)
            .help(hasAudio ? "Play this voice" : "This meeting's audio is gone; the voiceprint stays.")
            .accessibilityLabel(isPlaying ? "Stop" : "Play \(sample.meetingTitle)")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sample.meetingTitle).font(.status).lineLimit(1)
                    Text([sample.heardAt.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()),
                          MeetingTimeline.length(sample.seconds), sample.inPerson ? "in person" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.meta).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open this meeting")
            Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove the sample from \(sample.meetingTitle)")
        }
        .padding(.vertical, 5)
        .onHover { hovering = $0 }
        // The trash button only shows on hover, which VoiceOver never does.
        .accessibilityAction(named: "Remove Sample", onRemove)
        .contextMenu {
            Button("Open Meeting", action: onOpen)
            Button("Remove Sample", role: .destructive, action: onRemove)
        }
    }

    private func toggle() {
        if isPlaying { player.stop(); playing = nil; return }
        player.load(microphone: sample.track == .microphone ? audio : nil, system: sample.track == .system ? audio : nil)
        player.play(sample.clipStart...max(sample.clipStart, sample.clipEnd), track: sample.track)
        playing = sample.id
    }
}
