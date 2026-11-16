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
                             : recording.dictating ? "Left out while you dictate" : nil)
                } else {
                    meterRow("You", levels: microphone, note: recording.microphoneLost ? "Not heard: the mic dropped out"
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
                if !recording.sharing {
                    Button(meetings.sidekickVisible ? "Hide Sidekick" : "Show Sidekick") { meetings.setSidekickVisible(!meetings.sidekickVisible) }
                }
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
        } else if recording.sharing {
            line("The Sidekick is hidden while you share your screen.", symbol: "eye.slash") { EmptyView() }
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
