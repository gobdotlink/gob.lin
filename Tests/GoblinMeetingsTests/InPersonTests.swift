import Foundation
import Testing
@testable import GoblinMeetings

/// A conversation in the room: no system track, and the voices are split on the microphone.
@Test func inPersonMeetingSplitsVoicesOnTheMicrophone() async throws {
    let root = try Fixtures.temporaryDirectory()
    let directory = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var info = MeetingSessionInfo(title: "Conversation", source: "In person", target: "microphone only",
                                  startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    info.kind = .inPerson
    info.endedAt = info.startedAt.addingTimeInterval(10)
    try JSONEncoder.pretty.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
    try Fixtures.writeSegments([
        Fixtures.segment(.microphone, "shall we look at the plan", at: 0.5),
        Fixtures.segment(.microphone, "yes the launch is friday", at: 4.5),
    ], to: directory)
    try Fixtures.writeWAV(Fixtures.silence(seconds: 10), to: directory.appendingPathComponent(MeetingStorage.audioFile(.microphone)))
    let spans = [DiarizedSpan(speaker: 0, start: 0.3, end: 2.5), DiarizedSpan(speaker: 1, start: 4.3, end: 6.5)]

    let turns = try await MeetingPostProcessor.run(directory: directory, options: Fixtures.options(spans: spans))

    #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    #expect(turns.allSatisfy { $0.track == .microphone })
    #expect(!turns.contains { $0.speaker == MeetingPostProcessor.microphoneLabel })
}

/// Audio deleted after a failed run: Try Again still writes the transcript from the lines, under one voice.
@Test func inPersonMeetingProcessesAfterItsAudioIsDeleted() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var info = MeetingSessionInfo(title: "Conversation", source: "In person", target: "microphone only",
                                  startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    info.kind = .inPerson
    info.endedAt = info.startedAt.addingTimeInterval(10)
    try JSONEncoder.pretty.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
    try Fixtures.writeSegments([Fixtures.segment(.microphone, "shall we look at the plan", at: 0.5)], to: directory)
    let calls = Counter()

    let turns = try await MeetingPostProcessor.run(directory: directory, options: Fixtures.options(spans: [], calls: calls))

    #expect(turns.map(\.text) == ["shall we look at the plan"])
    #expect(calls.value == 0)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path))
}

@Test func inPersonTargetDescribesItselfAndCallsDecodeWithoutAKind() throws {
    #expect(SystemAudioTarget.none.description == "microphone only")
    let old = #"{"title":"Old call","source":"Zoom","target":"app","startedAt":"2026-11-15T10:00:00Z","maximumBacklog":0,"decodeMilliseconds":[]}"#
    let decoded = try JSONDecoder.meetingDates.decode(MeetingSessionInfo.self, from: Data(old.utf8))
    #expect(decoded.kind == nil)
}
