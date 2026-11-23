import Foundation
import Testing
import UserNotifications
@testable import GoblinMeetings

// MARK: Live captions while muted

private func segment(_ track: MeetingTrack, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(track: track, start: start, end: end, text: "words", words: [], decodeMilliseconds: 0)
}

@Test func liveCaptionsLeaveOutMicLinesSaidWhileMuted() {
    var timeline = MuteTimeline()
    timeline.record(false, at: 0.08)
    timeline.record(true, at: 20.14)
    // Still muted: the span runs on until the call app shows the mic on again.
    #expect(timeline.silences(segment(.microphone, 24, 28)))
    // The other side is never muted by your mute.
    #expect(!timeline.silences(segment(.system, 24, 28)))
    // Before the mute, and a line whose midpoint falls before it.
    #expect(!timeline.silences(segment(.microphone, 10, 14)))
    #expect(!timeline.silences(segment(.microphone, 16, 22)))
    #expect(timeline.silences(segment(.microphone, 19, 23)))
    timeline.record(false, at: 43.6)
    #expect(timeline.silences(segment(.microphone, 40, 44)))
    #expect(!timeline.silences(segment(.microphone, 44, 50)))
}

@Test func muteTimelineIgnoresRepeatsAndMatchesTheTranscriptRule() {
    var timeline = MuteTimeline()
    timeline.record(true, at: 5)
    timeline.record(true, at: 6)
    timeline.record(false, at: 8)
    timeline.record(true, at: 10)
    #expect(timeline.changes.count == 3)
    let log = timeline.changes.map { "{\"t\":\($0.t),\"muted\":\($0.muted)}" }.joined(separator: "\n")
    // The final transcript reads mute.jsonl into the same spans the live captions use.
    #expect(MeetingPostProcessor.mutedSpans(log, end: 20) == timeline.spans(end: 20))
    #expect(timeline.spans(end: 20) == [5...8, 10...20])
}

// MARK: Offers

private func candidate(_ bundleID: String, title: String?, likely: Bool = true) -> MeetingCandidate {
    let call = CallApp.matching(bundleID: bundleID)
    let app = AudioClientApp(bundleID: bundleID, name: call?.name ?? bundleID, pid: 1, processes: [], callApp: call)
    return MeetingCandidate(app: app, since: Date(timeIntervalSince1970: 0), meetingTitle: title, isLikelyMeeting: likely)
}

/// The third real-app run: a conversation, a Zoom call recorded until it ended, a Zoom call set to Never, then a
/// Google Meet in Chrome. The Meet call has to be offered.
@Test func aMeetCallIsOfferedAfterRecordedAndNeverCalls() {
    var gate = MeetingOfferGate()
    var policies: [String: MeetingCallPolicy] = [:]
    func update(_ candidates: [MeetingCandidate], busy: String? = nil) -> MeetingOfferGate.Decision {
        gate.update(candidates: candidates, busy: busy, policy: { policies[$0] ?? .ask }).decision
    }
    let zoom = candidate("us.zoom.xos", title: "Zoom Meeting")

    // A conversation in the room records, processes and finishes with no call app on the mic.
    #expect(update([], busy: "recording") == .none)
    #expect(update([], busy: "processing") == .none)
    #expect(update([]) == .none)

    // Zoom takes the mic: not yet 2 s, then offered, then recorded.
    let early = gate.update(candidates: [candidate("us.zoom.xos", title: "Zoom Meeting", likely: false)], busy: nil) { _ in .ask }
    #expect(early.decision == .none)
    #expect(early.skipped == [.init(bundleID: "us.zoom.xos", reason: .tooShort)])
    #expect(update([zoom]) == .offer(zoom))
    #expect(update([zoom], busy: "offering us.zoom.xos") == .none)
    gate.hold(zoom)
    #expect(update([zoom], busy: "recording") == .none)
    // The call ends; recording stops a minute later and is processed.
    #expect(update([], busy: "recording") == .none)
    #expect(gate.holds.isEmpty)
    #expect(update([], busy: "processing") == .none)
    #expect(update([]) == .none)

    // Zoom set to Never: a second call isn't offered.
    policies["us.zoom.xos"] = .never
    let never = gate.update(candidates: [zoom], busy: nil) { policies[$0] ?? .ask }
    #expect(never.decision == .none)
    #expect(never.skipped == [.init(bundleID: "us.zoom.xos", reason: .never)])
    #expect(update([]) == .none)
    policies["us.zoom.xos"] = nil

    // A Meet tab in Chrome holds the mic: offered.
    let title = "Meet – abc-defg-hij – Microphone recording - Google Chrome – Personal"
    #expect(MeetingDetector.looksLikeMeeting(title))
    let meet = candidate("com.google.Chrome", title: title)
    #expect(update([meet]) == .offer(meet))
}

@Test func aCallStoppedByHandIsAskedAgainOnlyOnItsNextCall() {
    var gate = MeetingOfferGate()
    let zoom = candidate("us.zoom.xos", title: "Zoom Meeting")
    #expect(gate.update(candidates: [zoom], busy: nil) { _ in .ask }.decision == .offer(zoom))
    gate.hold(zoom)
    // Stopped by hand while Zoom keeps the mic: not asked again.
    let after = gate.update(candidates: [zoom], busy: nil) { _ in .ask }
    #expect(after.decision == .none)
    #expect(after.skipped == [.init(bundleID: "us.zoom.xos", reason: .alreadyAsked)])
    // Zoom lets go and starts a new call: asked again.
    #expect(gate.update(candidates: [], busy: nil) { _ in .ask }.decision == .none)
    #expect(gate.update(candidates: [zoom], busy: nil) { _ in .ask }.decision == .offer(zoom))
}

@Test func alwaysRecordsAndBusyWaits() {
    var gate = MeetingOfferGate()
    let teams = candidate("com.microsoft.teams2", title: "Standup | Microsoft Teams")
    let busy = gate.update(candidates: [teams], busy: "processing") { _ in .always }
    #expect(busy.decision == .none)
    #expect(busy.skipped == [.init(bundleID: "com.microsoft.teams2", reason: .busy("processing"))])
    // Processing done: the call still on the mic is taken up then.
    #expect(gate.update(candidates: [teams], busy: nil) { _ in .always }.decision == .record(teams))
}

@Test func theNextCallAppIsOfferedWhenTheFirstIsSkipped() {
    var gate = MeetingOfferGate()
    let zoom = candidate("us.zoom.xos", title: "Zoom Meeting")
    let meet = candidate("com.google.Chrome", title: "Meet – abc-defg-hij")
    let result = gate.update(candidates: [zoom, meet], busy: nil) { $0 == "us.zoom.xos" ? .never : .ask }
    #expect(result.decision == .offer(meet))
}

/// The real Slack huddle: a Zoom recording was still counting down to auto-stop when Slack took the mic, so Slack was
/// skipped as busy. Once the recording ended and was processed, the re-check has to offer Slack, which never changed.
@Test func aHuddleSkippedWhileZoomRecordsIsOfferedWhenTheRecordingEnds() {
    var gate = MeetingOfferGate()
    func update(_ candidates: [MeetingCandidate], busy: String?) -> (decision: MeetingOfferGate.Decision, skipped: [MeetingOfferGate.Skip]) {
        gate.update(candidates: candidates, busy: busy) { _ in .ask }
    }
    let zoom = candidate("us.zoom.xos", title: "Zoom Meeting")
    let slack = candidate("com.tinyspeck.slackmacgap", title: "Slack huddle")
    #expect(update([zoom], busy: nil).decision == .offer(zoom))
    gate.hold(zoom)
    // Zoom lets go; the recording counts down. Slack takes the mic and is skipped.
    #expect(update([], busy: "recording").decision == .none)
    let skipped = update([slack], busy: "recording")
    #expect(skipped.decision == .none)
    #expect(skipped.skipped == [.init(bundleID: "com.tinyspeck.slackmacgap", reason: .busy("recording"))])
    // Auto-stop, then processing: still busy, and nothing about Slack changes from here on.
    #expect(MeetingOfferGate.blockerCleared(from: "recording", to: "processing") == false)
    #expect(update([slack], busy: "processing").decision == .none)
    // Processing finishes: the blocker cleared, so the controller decides again with the same picture.
    #expect(MeetingOfferGate.blockerCleared(from: "processing", to: nil))
    #expect(update([slack], busy: nil).decision == .offer(slack))
}

@Test func theOfferIsCheckedAgainOnlyWhenTheBlockerClears() {
    #expect(MeetingOfferGate.blockerCleared(from: "recording", to: nil))
    #expect(MeetingOfferGate.blockerCleared(from: "a recording is starting", to: nil))
    #expect(MeetingOfferGate.blockerCleared(from: "offering us.zoom.xos", to: nil))
    #expect(!MeetingOfferGate.blockerCleared(from: nil, to: nil))
    #expect(!MeetingOfferGate.blockerCleared(from: nil, to: "recording"))
    #expect(!MeetingOfferGate.blockerCleared(from: "a recording is starting", to: "recording"))
}

/// Recording one call holds only that call: another app already on the mic is offered once the recording ends, and
/// the recorded one isn't asked about again until it lets go.
@Test func startingARecordingHoldsOnlyTheCallRecorded() {
    var gate = MeetingOfferGate()
    let zoom = candidate("us.zoom.xos", title: "Zoom Meeting")
    let slack = candidate("com.tinyspeck.slackmacgap", title: "Slack huddle")
    #expect(gate.update(candidates: [zoom, slack], busy: nil) { _ in .ask }.decision == .offer(zoom))
    gate.hold(zoom)
    #expect(gate.holds == ["us.zoom.xos"])
    #expect(gate.update(candidates: [zoom, slack], busy: "recording") { _ in .ask }.decision == .none)
    let after = gate.update(candidates: [zoom, slack], busy: nil) { _ in .ask }
    #expect(after.decision == .offer(slack))
    #expect(after.skipped == [.init(bundleID: "us.zoom.xos", reason: .alreadyAsked)])
    // Recording all system audio holds nothing.
    var other = MeetingOfferGate()
    other.hold(nil)
    #expect(other.holds.isEmpty)
}

// MARK: ⌃⌥M

@Test func markShortcutNeedsExactlyControlAndOption() {
    let m = MeetingMarkShortcut.ansiKeyCode
    let controlOption = MeetingMarkShortcut.control | MeetingMarkShortcut.option
    #expect(MeetingMarkShortcut.matches(keyCode: m, charactersIgnoringModifiers: "m", modifierFlags: controlOption))
    // Caps Lock (1 << 16) and fn (1 << 23) don't matter.
    #expect(MeetingMarkShortcut.matches(keyCode: m, charactersIgnoringModifiers: "M", modifierFlags: controlOption | 1 << 16 | 1 << 23))
    #expect(!MeetingMarkShortcut.matches(keyCode: m, charactersIgnoringModifiers: "m", modifierFlags: MeetingMarkShortcut.option))
    #expect(!MeetingMarkShortcut.matches(keyCode: m, charactersIgnoringModifiers: "m", modifierFlags: controlOption | MeetingMarkShortcut.shift))
    #expect(!MeetingMarkShortcut.matches(keyCode: m, charactersIgnoringModifiers: "m", modifierFlags: controlOption | MeetingMarkShortcut.command))
    #expect(!MeetingMarkShortcut.matches(keyCode: 45, charactersIgnoringModifiers: "n", modifierFlags: controlOption))
    // Dvorak puts M elsewhere: the layout's key code, or the character, still counts.
    #expect(MeetingMarkShortcut.matches(keyCode: 41, charactersIgnoringModifiers: "m", modifierFlags: controlOption, mKeyCode: 41))
    #expect(MeetingMarkShortcut.matches(keyCode: 41, charactersIgnoringModifiers: nil, modifierFlags: controlOption, mKeyCode: 41))
}

// MARK: Notifications

@Test func allowAsksOnceThenOpensSettings() {
    #expect(NotificationAccess.step(for: .notDetermined) == .request)
    #expect(NotificationAccess.step(for: nil) == .request)
    #expect(NotificationAccess.step(for: .denied) == .openSettings)
    #expect(NotificationAccess.step(for: .authorized) == .none)
    #expect(NotificationAccess.step(for: .provisional) == .none)
    #expect(NotificationAccess.settingsURL(bundleID: "app.goblin.dictation").absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.goblin.dictation")
    #expect(NotificationAccess.settingsURL(bundleID: nil).absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
}

// MARK: Track timeline

@Test func aLongCaptureGapIsPaddedInFullSoTheTrackStaysOnTheSessionClock() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try TrackRecorder(track: .microphone, directory: directory, sessionStart: 0, onChunk: { _ in }, onEvent: { _ in })
    let second = [Float](repeating: 0, count: 16_000)
    recorder.append(CapturedBuffer(samples: second, sampleRate: 16_000, hostSeconds: 0))
    // The device comes back after more than half an hour.
    recorder.append(CapturedBuffer(samples: second, sampleRate: 16_000, hostSeconds: 2_000))
    let stats = recorder.finish()
    #expect(stats.samples == 2_001 * 16_000)
    #expect(stats.gaps.map(\.seconds) == [1_999])
}

@Test func aShortGapIsFilledOnlyWhereTheCaptureReopened() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try TrackRecorder(track: .microphone, directory: directory, sessionStart: 0, onChunk: { _ in }, onEvent: { _ in })
    let second = [Float](repeating: 0, count: 16_000)
    recorder.append(CapturedBuffer(samples: second, sampleRate: 16_000, hostSeconds: 0))
    // A tenth of a second late without a reopen reads as clock jitter.
    recorder.append(CapturedBuffer(samples: second, sampleRate: 16_000, hostSeconds: 1.1))
    // The same after the mic reopened is time that passed unrecorded.
    var reopened = CapturedBuffer(samples: second, sampleRate: 16_000, hostSeconds: 2.2)
    reopened.resumes = true
    recorder.append(reopened)
    let stats = recorder.finish()
    #expect(stats.gaps.count == 1)
    #expect(abs((stats.gaps.first?.seconds ?? 0) - 0.1) < 0.001)
    #expect(stats.samples == 3 * 16_000 + 1_600)
}

@Test func aLineThatFinishesDecodingLateStillReadsInTimeOrder() {
    var lines: [TranscriptSegment] = []
    for start in [1.0, 5.0, 3.0, 5.0, 0.5, 6.0] { lines.insert(segment(.system, start, start + 1), byStart: \.start) }
    #expect(lines.map(\.start) == [0.5, 1, 3, 5, 5, 6])
}
