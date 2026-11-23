import AppKit
import Combine
import Foundation
import GoblinMeetings

/// What a meeting puts on screen while it records: the overlay's questions and chips, the Sidekick, and ⌃⌥M.
/// It listens to `MeetingsController` and answers the overlay's meeting buttons.
@MainActor
final class MeetingSurfaces {
    private let meetings: MeetingsController
    private let overlay: OverlayController
    private let sidekick: SidekickController
    private let hotkey: MeetingMarkHotkey
    private let openMeeting: (String) -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var offered: String?
    private var recordingID: String?

    init(meetings: MeetingsController, overlay: OverlayController, defaults: UserDefaults,
         openMeeting: @escaping (String) -> Void) {
        self.meetings = meetings
        self.overlay = overlay
        self.openMeeting = openMeeting
        sidekick = SidekickController(meetings: meetings, defaults: defaults, overlayPosition: { [overlay] in overlay.position })
        hotkey = MeetingMarkHotkey { [weak meetings] in meetings?.mark() }
        meetings.$phase.removeDuplicates().sink { [weak self] phase in self?.phaseChanged(phase) }.store(in: &subscriptions)
        meetings.offerRecalled.sink { [weak self] call in self?.showOffer(call) }.store(in: &subscriptions)
        meetings.$readyNotice.compactMap { $0 }.sink { [weak self] notice in self?.announce(notice) }.store(in: &subscriptions)
        meetings.$interruption.compactMap { $0 }.sink { [weak self] interruption in self?.say(interruption) }.store(in: &subscriptions)
        meetings.$quietQuestion.removeDuplicates().sink { asked in
            if asked != nil { overlay.showCompletion(.meetingQuiet(minutes: Int(MeetingsController.conversationQuietTimeout / 60)), session: UUID()) }
            else { overlay.withdraw { if case .meetingQuiet = $0 { true } else { false } } }
        }.store(in: &subscriptions)
    }

    private func showOffer(_ candidate: MeetingCandidate) {
        overlay.withdraw { if case .meetingOffer = $0 { true } else { false } }
        overlay.showCompletion(.meetingOffer(MeetingOffer(app: candidate.app.name, bundleID: candidate.id,
                                                          title: candidate.meetingTitle.map(MeetingDetector.cleanTitle),
                                                          systemAudioOff: meetings.systemAudioPermission == .denied)),
                               session: UUID())
    }

    private func phaseChanged(_ phase: MeetingsController.Phase) {
        if case .offered(let candidate) = phase {
            if offered != candidate.id, !MeetingsController.screenLocked { showOffer(candidate) }
            offered = candidate.id
        } else if offered != nil {
            offered = nil
            overlay.withdraw { if case .meetingOffer = $0 { true } else { false } }
        }
        if case .recording(let recording) = phase {
            guard recordingID != recording.meetingID else { return }
            recordingID = recording.meetingID
            hotkey.register()
            sidekick.recordingStarted()
            // With the Sidekick off, one line says it started and how to stop it.
            if !meetings.sidekickVisible { overlay.showCompletion(.meetingRecording(title: recording.title), session: UUID()) }
        } else if recordingID != nil {
            recordingID = nil
            hotkey.unregister()
            overlay.withdraw { if case .meetingQuiet = $0 { true } else { false } }
        }
    }

    private func announce(_ notice: MeetingsController.ReadyNotice) {
        var detail = notice.duration >= 60 ? "\(Int(notice.duration / 60)) min" : "\(Int(notice.duration.rounded())) s"
        if notice.voicesToName > 0 { detail += " · \(notice.voicesToName) \(notice.voicesToName == 1 ? "voice" : "voices") to name" }
        overlay.showCompletion(.meetingReady(MeetingReady(meetingID: notice.meetingID, title: notice.title, detail: detail)), session: UUID())
        meetings.acknowledgeReady()
        meetings.acknowledge(meetingID: notice.meetingID)
    }

    private func say(_ interruption: MeetingsController.Interruption) {
        let time = interruption.at.formatted(date: .omitted, time: .shortened)
        overlay.showCompletion(.meetingInterrupted(MeetingInterrupted(
            sentence: MeetingsController.interruptionSentence(interruption),
            detail: interruption.reason == .sleep ? "slept at \(time)" : "lid closed at \(time)",
            canRecordRest: interruption.callContinues)), session: UUID())
    }

    /// The overlay's meeting buttons.
    func perform(_ action: OverlayAction) {
        switch action {
        case .recordMeeting(let bundle):
            overlay.hide()
            if case .offered(let candidate) = meetings.phase, candidate.id == bundle { meetings.start(candidate) }
            else if let call = meetings.unrecordedCall, call.id == bundle { meetings.start(call) }
        case .dismissMeetingOffer:
            overlay.hide()
            meetings.dismissOffer()
        case .systemAudioSettings:
            overlay.hide()
            meetings.dismissOffer()
            meetings.openSystemAudioSettings()
        case .openMeeting(let id):
            overlay.hide()
            openMeeting(id)
        case .recordRest:
            overlay.hide()
            meetings.recordRest()
        case .dismissInterruption:
            overlay.hide()
            meetings.acknowledgeInterruption()
        case .keepGoing:
            overlay.hide()
            meetings.keepGoing()
        case .stopMeeting:
            overlay.hide()
            meetings.stop()
        default: break
        }
    }

    func shutdown() {
        hotkey.unregister()
        sidekick.shutdown()
        subscriptions.removeAll()
    }
}
