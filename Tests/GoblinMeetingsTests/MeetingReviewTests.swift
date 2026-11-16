import Foundation
import Testing
@testable import GoblinMeetings

private func turn(_ speaker: String, _ start: Double, _ end: Double, track: MeetingTrack = .system,
                  _ text: String = "one two three") -> TranscriptTurn {
    TranscriptTurn(speaker: speaker, label: speaker, track: track, start: start, end: end, text: text)
}

@Test func lanesPutTheMicrophoneFirstThenNamedByTalkThenUnnamed() {
    let lanes = MeetingTimeline.lanes([
        turn("Speaker 4", 0, 5),
        turn("Priya Shah", 5, 30),
        turn("You", 30, 35, track: .microphone),
        turn("Speaker 3", 35, 40),
        turn("Sam Okafor", 40, 50),
    ])
    #expect(lanes.map(\.name) == ["You", "Priya Shah", "Sam Okafor", "Speaker 3", "Speaker 4"])
    #expect(lanes.map(\.needsName) == [false, false, false, true, true])
    #expect(lanes.first?.isYou == true)
    #expect(lanes[1].talkSeconds == 25)
}

@Test func backToBackTurnsJoinIntoOneStretchButGapsSplitThem() {
    let a = turn("Priya Shah", 0, 4), b = turn("Priya Shah", 5, 9), c = turn("Priya Shah", 20, 22)
    let lane = try! #require(MeetingTimeline.lanes([c, a, b]).first)
    #expect(lane.stretches.count == 2)
    #expect(lane.stretches[0].start == 0 && lane.stretches[0].end == 9)
    #expect(lane.stretches[0].turnIDs == [a.id, b.id])
    #expect(lane.stretches[1].turnIDs == [c.id])
    #expect(lane.talkSeconds == 10)
}

@Test func aStretchNeverJoinsAcrossTracks() {
    // A merged name can hold the mic and a remote voice; each stretch plays from one track's file.
    let lanes = MeetingTimeline.lanes([turn("Sam", 0, 4, track: .microphone), turn("Sam", 4.5, 8)])
    #expect(lanes.count == 1)
    #expect(lanes[0].stretches.map(\.track) == [.microphone, .system])
}

@Test func aRenderedTurnNeverJoinsAcrossTracks() {
    // The mic and a remote voice both named Sam: each turn keeps its own track, so playback finds its words.
    let merged = MeetingPostProcessor.merge([turn("Sam", 0, 4, track: .microphone), turn("Sam", 4.5, 8),
                                             turn("Sam", 8.5, 10)], by: \.speaker)
    #expect(merged.map(\.track) == [.microphone, .system])
    #expect(merged.map(\.start) == [0, 4.5])
    #expect(merged[1].end == 10)
}

@Test func onlySpeakerNumbersNeedNames() {
    #expect(MeetingTimeline.isUnnamed("Speaker 2"))
    #expect(MeetingTimeline.isUnnamed("Speaker 12"))
    #expect(!MeetingTimeline.isUnnamed("Them"))
    #expect(!MeetingTimeline.isUnnamed("You"))
    #expect(!MeetingTimeline.isUnnamed("Speaker Bob"))
    #expect(!MeetingTimeline.isUnnamed("Mira Patel"))
}

@Test func clipsAreTheLongestWordyLinesInMeetingOrder() {
    let turns = [
        turn("Speaker 4", 0, 1, "Yes."),
        turn("Speaker 4", 10, 20, "I can pick up the page-break fix."),
        turn("Speaker 4", 30, 33, "Sorry, that was me."),
        turn("Speaker 4", 40, 49, "I'll take the launch copy."),
        turn("Speaker 4", 50, 52, "Fine by me too."),
        turn("Priya Shah", 60, 90, "Somebody else entirely talking for a while."),
    ]
    #expect(MeetingTimeline.clips(of: "Speaker 4", in: turns).map(\.start) == [10, 30, 40])
    // A voice that only ever said a word or two still gets clips.
    #expect(MeetingTimeline.clips(of: "Speaker 4", in: [turns[0]]).count == 1)
}

@Test func marksParseSkipBadLinesAndSort() {
    let marks = MeetingMark.parse("""
        {"t": 120.5, "label": "Pricing"}
        not json
        {"t": 30}
        {"t": -1}
        {"t": 60, "label": "  "}

        """)
    #expect(marks == [MeetingMark(t: 30), MeetingMark(t: 60), MeetingMark(t: 120.5, label: "Pricing")])
}

@Test func marksAreReadFromTheMeetingFolder() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2027-01-15 080000 Weekly sync")
    try "{\"t\": 4}\n{\"t\": 2, \"label\": \"Decision\"}\n".write(to: directory.appendingPathComponent(MeetingStorage.marksFile),
                                                                 atomically: true, encoding: .utf8)
    let detail = try await MeetingStore(root: root).detail(directory.lastPathComponent)
    #expect(detail.marks == [MeetingMark(t: 2, label: "Decision"), MeetingMark(t: 4)])
}

@Test func suggestionsOfferUnusedParticipantsNeverMe() {
    let lanes = MeetingTimeline.lanes([turn("You", 0, 1, track: .microphone), turn("Priya Shah", 1, 2), turn("Speaker 3", 2, 3)])
    let participants = MeetingParticipants(all: ["Will", "Priya Shah", "Sam Okafor"], me: "Will")
    let suggestions = SpeakerSuggestions.suggestions(lanes: lanes, participants: participants)
    #expect(suggestions.map(\.name) == ["Sam Okafor"])
    #expect(suggestions[0].reason == "In the call's participant list, and no voice has their name yet.")
}

@Test func moreVoicesThanParticipantsMeansASharedLaptop() {
    let participants = MeetingParticipants(all: ["Will", "Priya Shah", "Sam Okafor"], me: "Will")
    let three = MeetingTimeline.lanes([turn("You", 0, 1, track: .microphone), turn("Priya Shah", 1, 2), turn("Sam Okafor", 2, 3)])
    #expect(SpeakerSuggestions.extraVoices(lanes: three, participants: participants) == 0)
    let four = MeetingTimeline.lanes([turn("You", 0, 1, track: .microphone), turn("Priya Shah", 1, 2), turn("Sam Okafor", 2, 3),
                                      turn("Speaker 3", 3, 4)])
    #expect(SpeakerSuggestions.extraVoices(lanes: four, participants: participants) == 1)
    // Without a participant list there's nothing to compare.
    #expect(SpeakerSuggestions.extraVoices(lanes: four, participants: MeetingParticipants()) == 0)
}

@Test func ticksAndClocks() {
    #expect(MeetingTimeline.ticks(duration: 42 * 60) == [0, 600, 1_200, 1_800, 2_400])
    #expect(MeetingTimeline.ticks(duration: 25 * 60) == [0, 300, 600, 900, 1_200])
    #expect(MeetingTimeline.ticks(duration: 150) == [0, 60, 120])
    #expect(MeetingTimeline.clock(271) == "4:31")
    #expect(MeetingTimeline.clock(3_842) == "1:04:02")
    #expect(MeetingTimeline.length(42 * 60) == "42 min")
    #expect(MeetingTimeline.length(95 * 60) == "1 h 35 min")
    #expect(MeetingTimeline.length(40) == "40 s")
}

private func summary(_ state: MeetingState = .ready, speakers: [String] = ["You", "Priya Shah"], hasAudio: Bool = true,
                     interrupted: Bool = false, stopReason: String? = "call ended", startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                     id: String = "a") -> MeetingSummary {
    MeetingSummary(id: id, title: "Weekly sync", source: "Zoom", target: "", startedAt: startedAt, endedAt: nil, duration: 1_872,
                   participants: [], speakers: speakers, state: state, wasInterrupted: interrupted, hasAudio: hasAudio, starred: false,
                   failure: nil, directory: URL(fileURLWithPath: "/tmp/\(id)"), stopReason: stopReason)
}

@Test func badgesNameWhatNeedsAttention() {
    #expect(MeetingBadge.badges(summary()) == [])
    #expect(MeetingBadge.badges(summary(speakers: ["You", "Speaker 4"])) == [.needsNames])
    #expect(MeetingBadge.badges(summary(stopReason: "sleep")) == [.stoppedEarly])
    #expect(MeetingBadge.badges(summary(interrupted: true, stopReason: nil)) == [.stoppedEarly])
    #expect(MeetingBadge.badges(summary(hasAudio: false)) == [.noAudio])
    #expect(MeetingBadge.badges(summary(.processing, speakers: [])) == [.processing])
    #expect(MeetingBadge.badges(summary(.failed, speakers: ["Speaker 2"])) == [.failed, .needsNames])
    #expect(MeetingBadge.stoppedEarlySentence(summary(stopReason: "sleep")) == "Recording stopped at 31:12 because the Mac went to sleep.")
    #expect(MeetingBadge.stoppedEarlySentence(summary()) == nil)
    #expect(MeetingBadge.badges(summary(stopReason: MeetingStopReason.writeFailed)) == [.stoppedEarly])
}

@Test func daysGroupTodayYesterdayThenWeekdays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_800_000_000) // a Friday, 08:00 UTC
    let meetings = [
        summary(startedAt: now.addingTimeInterval(-3_600), id: "today-early"),
        summary(startedAt: now.addingTimeInterval(-60), id: "today-late"),
        summary(startedAt: now.addingTimeInterval(-86_400), id: "yesterday"),
        summary(startedAt: now.addingTimeInterval(-3 * 86_400), id: "older"),
    ]
    let groups = MeetingDay.groups(meetings, now: now, calendar: calendar)
    #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
    #expect(groups.count == 3)
    #expect(groups[0].meetings.map(\.id) == ["today-late", "today-early"])
    #expect(groups[2].title.contains("Tuesday"))
}

@Test func settingSpeakerNamesUndoesAMerge() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2027-01-15 080000 Weekly sync", segments: [
        Fixtures.segment(.system, "hello everyone", at: 0.2),
        Fixtures.segment(.system, "thanks for joining", at: 2.2),
        Fixtures.segment(.microphone, "happy to be here", at: 6),
    ])
    let store = MeetingStore(root: root, options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 1.9),
                                                                          DiarizedSpan(speaker: 1, start: 2.0, end: 4)]))
    let id = directory.lastPathComponent
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 1", to: "Alex Kim")
    let before = try await store.speakerNames(id)
    #expect(before == ["Speaker 1": "Alex Kim"])

    // Merging Speaker 2 into Alex Kim, then undoing it, leaves Alex Kim's own name alone.
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")
    #expect(try await store.summary(id).speakers.sorted() == ["Alex Kim", "You"])
    let restored = try await store.setSpeakerNames(id, before)
    #expect(restored.map(\.speaker) == ["Alex Kim", "Speaker 2", "You"])
    #expect(try await store.speakerNames(id) == before)
}

@Test func inPersonLanesAreAllOnTheMicAndOnlyTheNameYouIsYou() {
    let turns = [turn("Speaker 2", 0, 10, track: .microphone), turn("Speaker 1", 10, 30, track: .microphone)]
    let lanes = MeetingTimeline.lanes(turns, kind: .inPerson)
    #expect(lanes.map(\.name) == ["Speaker 1", "Speaker 2"])
    #expect(lanes.allSatisfy { !$0.isYou && $0.needsName })
    #expect(lanes.allSatisfy { $0.stretches.allSatisfy { $0.track == .microphone } })
    // After "That's me", the voice called You leads.
    let named = MeetingTimeline.lanes([turn("Speaker 2", 0, 10, track: .microphone), turn("You", 10, 12, track: .microphone)], kind: .inPerson)
    #expect(named.map(\.name) == ["You", "Speaker 2"])
    #expect(named[0].isYou)
    // No participant list, so no suggestions and no shared laptop.
    #expect(SpeakerSuggestions.suggestions(lanes: lanes, participants: MeetingParticipants()).isEmpty)
    #expect(SpeakerSuggestions.extraVoices(lanes: lanes, participants: MeetingParticipants()) == 0)
}

@Test func summariesReadTheMeetingKind() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let call = try Fixtures.meeting(in: root, name: "2027-01-15 080000 Weekly sync")
    let room = try Fixtures.meeting(in: root, name: "2027-01-15 090000 Conversation", title: "Conversation")
    let url = room.appendingPathComponent(MeetingStorage.sessionFile)
    var info = try JSONDecoder.meeting.decode(MeetingSessionInfo.self, from: Data(contentsOf: url))
    info.kind = .inPerson
    try JSONEncoder.pretty.encode(info).write(to: url)
    let store = MeetingStore(root: root)
    #expect(try await store.summary(call.lastPathComponent).kind == .call)
    #expect(try await store.summary(room.lastPathComponent).kind == .inPerson)
}
