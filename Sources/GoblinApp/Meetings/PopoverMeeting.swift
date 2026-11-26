import AppKit
import GoblinMeetings
import SwiftUI

/// The popover's meeting module, at the top while it matters: System Audio Recording off, the recording with its
/// levels and Stop, the auto-stop countdown, processing, a call that isn't being recorded, or a failure.
struct PopoverMeeting: View {
    @ObservedObject var meetings: MeetingsController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if meetings.enabled, meetings.systemAudioPermission == .denied, meetings.recording?.inPerson != true {
            attention(symbol: "speaker.slash", title: "System Audio Recording is off",
                      detail: "I can only hear your side of calls until you turn it back on.") {
                Button("Open System Settings") { dismiss.then(meetings.openSystemAudioSettings) }
            }
        }
        switch meetings.phase {
        case .recording(let recording):
            PopoverRecording(meetings: meetings, recording: recording)
        case .processing(let title, _):
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    circle("person.2", on: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.row.weight(.semibold)).lineLimit(1)
                        Text("Saved on this Mac").font(.meta).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(meetings.processingLine).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .moduleBackground()
        case .failed(let message):
            attention(symbol: "exclamationmark.triangle", title: "Meeting recording", detail: message) {
                Button("OK") { meetings.acknowledge() }
            }
        default:
            if let call = meetings.unrecordedCall {
                HStack(spacing: 10) {
                    circle("headphones", on: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(call.app.name) is using your mic").font(.row.weight(.semibold)).lineLimit(1)
                        Text("\(call.meetingTitle.map(MeetingDetector.cleanTitle) ?? call.app.name) · not recording")
                            .font(.meta).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button { meetings.start(call) } label: { Label("Record", systemImage: "record.circle") }
                        .prominent().buttonBorderShape(.capsule).controlSize(.small).disabled(!meetings.canStart)
                        .help(MeetingsController.consentLine)
                }
                .moduleBackground()
            }
        }
    }

    private func attention<Action: View>(symbol: String, title: String, detail: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(LightState.waiting.color)
                .frame(width: 30, height: 30)
                .background(LightState.waiting.color.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.row.weight(.semibold))
                Text(detail).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action().controlSize(.small).buttonBorderShape(.capsule).padding(.top, 5)
            }
        }
        .moduleBackground(attention: true)
    }
}

/// Title, elapsed time and Stop; You and Them levels (the room's, in person); then whichever line matters now.
private struct PopoverRecording: View {
    @ObservedObject var meetings: MeetingsController
    let recording: MeetingsController.Recording
    @State private var microphone = Array(repeating: 0.0, count: 26)
    @State private var system = Array(repeating: 0.0, count: 26)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                circle(recording.inPerson ? "person.2.wave.2" : "headphones", on: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recording.title).font(.row.weight(.semibold)).lineLimit(1)
                    Text(recording.inPerson ? "Recording in person" : "Recording \(recording.app)")
                        .font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Elapsed(start: recording.startedAt).font(.cardTitle)
                Button { meetings.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonBorderShape(.capsule).controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                if recording.inPerson {
                    meterRow("Room", levels: microphone, note: recording.microphoneLost ? "Not heard: the mic dropped out"
                             : recording.microphoneSilence != nil ? "Not heard: \(recording.microphone?.device.name ?? "the mic") is silent"
                             : recording.dictating ? "Left out while you dictate" : nil)
                } else {
                    meterRow("You", levels: microphone, note: recording.microphoneLost ? "Not heard: the mic dropped out"
                             : recording.microphoneSilence != nil ? "Not heard: \(recording.microphone?.device.name ?? "the mic") is silent"
                             : recording.muted == true ? "Left out while you're muted"
                             : recording.dictating ? "Left out while you dictate" : nil)
                    meterRow("Them", levels: system, note: meetings.systemAudioPermission == .denied ? "Not heard: System Audio Recording is off"
                             : recording.systemAudioLost ? "Not heard: I lost the call's sound" : nil)
                }
            }
            lines
            HStack(spacing: 6) {
                Button { meetings.mark() } label: {
                    Label { Text("Mark This") } icon: { Image(systemName: "flag.fill").foregroundStyle(GoblinBrand.candle) }
                }
                .help("Drop a bookmark here (\(MeetingMarkHotkey.title)). Label it in the Sidekick or later.")
                Button(meetings.sidekickVisible ? "Hide Sidekick" : "Show Sidekick") { meetings.setSidekickVisible(!meetings.sidekickVisible) }
                Spacer(minLength: 0)
                if !recording.marks.isEmpty {
                    Text("\(recording.marks.count) \(recording.marks.count == 1 ? "mark" : "marks")")
                        .font(.meta).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonBorderShape(.capsule).controlSize(.small)
        }
        .moduleBackground()
        .onChange(of: recording.microphoneLevel) { _, level in microphone = Array((microphone + [SidekickModel.meter(level)]).suffix(26)) }
        .onChange(of: recording.systemLevel) { _, level in system = Array((system + [SidekickModel.meter(level)]).suffix(26)) }
    }

    @ViewBuilder private var lines: some View {
        if meetings.quietQuestion != nil {
            // Stop is beside the time; the line only needs the other answer.
            line("It's been quiet for 10 minutes. Still going?", symbol: "waveform.slash") {
                Button("Keep Going") { meetings.keepGoing() }
            }
        } else if recording.autoStopRemaining() != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = recording.autoStopRemaining() ?? 0
                line(left > 0 ? "\(recording.app) let go of the mic, so I'll stop in \(MeetingsController.elapsed(left))."
                              : "\(recording.app) let go of the mic. I'll stop once the call goes quiet.", symbol: "info.circle") {
                    Button("Keep Recording") { meetings.keepRecording() }
                    Button("Stop Now") { meetings.stop() }.prominent()
                }
            }
        } else if let lost = MeetingCopy.captureLost(recording) {
            line(lost, symbol: "exclamationmark.triangle") { EmptyView() }
        } else if !recording.inPerson, recording.muted == true {
            line("You're muted in \(recording.app), so I'm leaving your mic out.", symbol: "mic.slash") { EmptyView() }
        } else if let download = meetings.speechModelDownload {
            line(MeetingCopy.speechModelDownload(download) + " Captions start after.", symbol: "arrow.down.circle") { EmptyView() }
        } else if let captions = recording.captions {
            line(MeetingCopy.captions(captions), symbol: "captions.bubble") { EmptyView() }
        }
    }

    private func line<Actions: View>(_ text: String, symbol: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
                Text(text).fixedSize(horizontal: false, vertical: true).monospacedDigit()
            }
            .font(.status)
            HStack(spacing: 6) { actions() }.buttonBorderShape(.capsule).controlSize(.small).padding(.leading, 21)
        }
    }

    private func meterRow(_ label: String, levels: [Double], note: String?) -> some View {
        GridRow {
            Text(label).font(.meta).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            if let note {
                Text(note).font(.meta).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(level > 0.02 ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.tertiary))
                            .frame(width: 3, height: 3 + level * 13)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 16)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ready card

/// After a meeting is processed, until it's opened or set aside: what it was, whose voices I knew, and the one thing
/// left to do, which is usually naming voices. The overlay's ready chip says it once; this stays until it's dealt with.
struct PopoverReadyMeeting: View {
    let model: AppModel
    @ObservedObject private var meetings: MeetingsController
    @Environment(\.dismiss) private var dismiss
    @State private var knownVoices: [String] = []
    @State private var copied = false

    init(model: AppModel) {
        self.model = model
        _meetings = ObservedObject(wrappedValue: model.meetings)
    }

    /// The card's meeting, while nothing more urgent holds the meeting module.
    private var meeting: StoredMeeting? { meetings.visibleUnopenedMeeting }

    var body: some View {
        if let meeting {
            let toName = meeting.speakers.filter(MeetingsController.isUnnamedVoice).count
            HStack(alignment: .top, spacing: 10) {
                circle("checkmark", on: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(meeting.title) is ready").font(.row.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { meetings.dismissUnopened() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                            .help("Done with this. It stays on the Meetings page.")
                            .accessibilityLabel("Dismiss")
                    }
                    Text(facts(meeting)).font(.meta).foregroundStyle(.secondary).lineLimit(2).monospacedDigit()
                    if toName > 0 {
                        Text("\(toName) \(toName == 1 ? "voice still needs a name" : "voices still need names").")
                            .font(.meta).foregroundStyle(GoblinBrand.candle)
                    }
                    HStack(spacing: 6) {
                        if toName > 0 {
                            Button("Who's This?") { dismiss.then { model.openMeeting(meeting.id, askWho: true) } }.prominent()
                            Button("Open") { dismiss.then { model.openMeeting(meeting.id) } }
                        } else {
                            Button("Open") { dismiss.then { model.openMeeting(meeting.id) } }.prominent()
                        }
                        Button(copied ? "Copied" : "Copy Transcript") {
                            Task {
                                guard await meetings.copyTranscript(meeting.id) else { return }
                                copied = true
                                try? await Task.sleep(for: .seconds(1.6))
                                copied = false
                            }
                        }
                    }
                    .buttonBorderShape(.capsule).controlSize(.small).padding(.top, 6)
                }
            }
            .moduleBackground()
            .task(id: meeting) {
                let detail = try? await meetings.library.store.detail(meeting.id)
                knownVoices = (detail?.namedFromVoice ?? []).sorted()
            }
        }
    }

    /// "27 min · Helium · I knew Mira's voice", "… · I knew Mira's and your voices".
    private func facts(_ meeting: StoredMeeting) -> String {
        var parts = [MeetingTimeline.length(meeting.duration), MeetingsView.sourceName(meeting)]
        // Others first, you last, as people say it.
        let whose = knownVoices.filter { $0 != MeetingPostProcessor.microphoneLabel }.map { SpeakerSuggestions.firstName($0) + "'s" }
            + (knownVoices.contains(MeetingPostProcessor.microphoneLabel) ? ["your"] : [])
        if let last = whose.last {
            let names = whose.count == 1 ? last : whose.dropLast().joined(separator: ", ") + " and " + last
            parts.append("I knew \(names) \(whose.count == 1 ? "voice" : "voices")")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Recent meetings

/// The last week's meetings, one click from the menu bar, drawn like the dictation rows. A meeting with voices to name
/// says how many, in amber. Record Conversation sits in the header and All Meetings opens the page; the plate is there
/// whenever Meetings is on.
struct PopoverMeetingsList: View {
    let model: AppModel
    @ObservedObject private var meetings: MeetingsController
    /// A waiting update holds a module above the lists until it's installed.
    @ObservedObject private var updates: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    /// Up to three rows, as many as fit under the menu bar with everything else the popover shows. The popover doesn't
    /// scroll, so on a short screen with the ready card up the plate can come down to All Meetings alone.
    private var rows: Int {
        let available = (NSScreen.main?.visibleFrame.height ?? 1_000) - Self.restOfPopover - Self.plateChrome
            - (meetings.visibleUnopenedMeeting == nil ? 0 : Self.readyCard)
            - (updates.availableVersion == nil ? 0 : Self.updateNotice)
        return min(3, max(0, Int(available / Self.rowHeight)))
    }
    /// Measured heights in points: the popover without this plate, the ready card, the update module, the plate with no
    /// rows (its header, All Meetings and padding), and one row. A little is kept spare for a problem module.
    static let restOfPopover: CGFloat = 600
    static let readyCard: CGFloat = 104
    static let updateNotice: CGFloat = 58
    static let plateChrome: CGFloat = 70
    static let rowHeight: CGFloat = 42
    /// Older meetings are on the page, not here.
    static let recent: TimeInterval = 7 * 86_400

    init(model: AppModel) {
        self.model = model
        _meetings = ObservedObject(wrappedValue: model.meetings)
        _updates = ObservedObject(wrappedValue: model.updates)
    }

    private var shown: [StoredMeeting] {
        let since = Date().addingTimeInterval(-Self.recent)
        // The ready card already shows its meeting while it's up, and the meeting module the one recording.
        let card = meetings.visibleUnopenedMeeting?.id
        return Array(meetings.meetings.filter { meeting in
            meeting.startedAt >= since && meeting.id != card && meeting.state != .recording
        }.prefix(rows))
    }

    var body: some View {
        if meetings.enabled {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    CapsHeader("Meetings")
                    Spacer(minLength: 8)
                    // People talking in the room, with no call: the mic alone.
                    if !meetings.isRecording {
                        Button("Record Conversation") { dismiss.then(meetings.startConversation) }
                            .buttonBorderShape(.capsule).controlSize(.small).disabled(!meetings.canStart)
                            .help("Record the people talking around this Mac from your mic. \(MeetingsController.consentLine)")
                    }
                }
                .padding(.horizontal, PopoverModule.bleed).frame(height: PopoverModule.header).padding(.bottom, 2)
                ForEach(shown) { meeting in
                    PopoverMeetingRow(meeting: meeting) { dismiss.then { model.openMeeting(meeting.id) } }
                }
                if meetings.meetings.isEmpty {
                    Text("Your meetings show up here.").font(.status).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, PopoverModule.bleed)
                } else {
                    menuItem("All Meetings", chevron: true, inset: PopoverModule.bleed) { dismiss.then { model.openMeeting() } }
                }
            }
            .padding(.horizontal, PopoverModule.inset - PopoverModule.bleed).padding(.top, 6).padding(.bottom, 8)
            .moduleBackground(padded: false)
        }
    }
}

private struct PopoverMeetingRow: View {
    let meeting: StoredMeeting
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let toName = meeting.speakers.filter(MeetingsController.isUnnamedVoice).count
        // A button, so keyboard navigation reaches it like any other control in the popover.
        Button(action: open) {
            HStack(spacing: 10) {
                MeetingIcon(meeting: meeting, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text([MeetingsView.sourceName(meeting), MeetingTimeline.length(meeting.duration),
                          meeting.startedAt.formatted(.relative(presentation: .named))].joined(separator: " · "))
                        .font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if meeting.state == .processing || meeting.state == .interrupted {
                    HStack(spacing: 4) { StatusLight(state: .waiting); Text("Processing") }.font(.meta).foregroundStyle(.secondary)
                } else if toName > 0 {
                    HStack(spacing: 4) { StatusLight(state: .waiting); Text("\(toName) to name") }.font(.meta).foregroundStyle(.secondary)
                }
            }
            .font(.row)
            .padding(.vertical, 5).padding(.horizontal, PopoverModule.bleed)
            .frame(height: 40)
            .background(hovered ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}
