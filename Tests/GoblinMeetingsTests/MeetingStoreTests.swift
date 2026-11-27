import Foundation
import Testing
@testable import GoblinMeetings

/// Two remote voices and the person: Speaker 1 (0–2 s), Speaker 2 (2–4 s), then "You" at 6 s.
private func threeVoiceMeeting(in root: URL, name: String = "2027-01-15 080000 Weekly sync") throws -> URL {
    try Fixtures.meeting(in: root, name: name, segments: [
        Fixtures.segment(.system, "hello everyone", at: 0.2),
        Fixtures.segment(.system, "thanks for joining", at: 2.2),
        Fixtures.segment(.microphone, "happy to be here", at: 6),
    ])
}

private let threeVoiceSpans = [DiarizedSpan(speaker: 0, start: 0, end: 1.9), DiarizedSpan(speaker: 1, start: 2.0, end: 4)]

private func transcript(_ directory: URL) throws -> [TranscriptTurn] {
    try JSONDecoder.meeting.decode([TranscriptTurn].self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)))
}

@Test func renamingASpeakerRerendersWithoutDiarizingAgain() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let calls = Counter()
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans, calls: calls))
    let id = directory.lastPathComponent

    let processed = try await store.process(id)
    #expect(processed.map(\.speaker) == ["Speaker 1", "Speaker 2", "You"])
    #expect(calls.value == 1)

    let renamed = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")
    #expect(renamed.map(\.speaker) == ["Speaker 1", "Alex Kim", "You"])
    #expect(try transcript(directory).map(\.speaker) == ["Speaker 1", "Alex Kim", "You"])
    let markdown = try String(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptMarkdownFile), encoding: .utf8)
    #expect(markdown.contains("**Alex Kim** [00:00:02]"))
    let names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.speakersFile)))
    #expect(names == ["Speaker 2": "Alex Kim"])
    #expect(calls.value == 1)

    // Naming the other voice the same merges them into one turn.
    let merged = try await store.renameSpeaker(id, from: "Speaker 1", to: "Alex Kim")
    #expect(merged.map(\.speaker) == ["Alex Kim", "You"])
    #expect(merged.first?.text == "hello everyone thanks for joining")
    let summary = try await store.summary(id)
    #expect(summary.speakers.sorted() == ["Alex Kim", "You"])

    // Clearing the name brings both diarized labels back.
    let reset = try await store.renameSpeaker(id, from: "Alex Kim", to: "")
    #expect(reset.map(\.speaker) == ["Speaker 1", "Speaker 2", "You"])
    await #expect(throws: MeetingStoreError.speakerNotFound("Nobody")) { try await store.renameSpeaker(id, from: "Nobody", to: "X") }

    // Re-processing keeps the names people gave.
    _ = try await store.renameSpeaker(id, from: "You", to: "Sam Rivera")
    #expect(try await store.process(id).map(\.speaker) == ["Speaker 1", "Speaker 2", "Sam Rivera"])
    #expect(calls.value == 2)
}

@Test func listingShowsStateTitleAndStarNewestFirst() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = try threeVoiceMeeting(in: root, name: "2027-01-15 080000 Weekly sync")
    let newer = try Fixtures.meeting(in: root, name: "2027-01-16 090000 Planning", title: "Planning",
                                     startedAt: Date(timeIntervalSince1970: 1_800_100_000))
    let live = try Fixtures.meeting(in: root, name: "2027-01-17 090000 Live", title: "Live",
                                    startedAt: Date(timeIntervalSince1970: 1_800_200_000), ended: false)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("not a meeting"), withIntermediateDirectories: true)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    // Mark the live recording active so slow parallel test runs can't age it past `liveWriteWindow` while `older` processes.
    await store.setRecording(live.lastPathComponent, true)
    _ = try await store.process(older.lastPathComponent)

    try await store.rename(older.lastPathComponent, title: "Weekly sync with Alex")
    try await store.setStarred(older.lastPathComponent, true)
    let list = await store.list()
    #expect(list.map(\.id) == [live.lastPathComponent, newer.lastPathComponent, older.lastPathComponent])
    #expect(list.map(\.state) == [.recording, .processing, .ready])
    let first = try #require(list.last)
    #expect(first.title == "Weekly sync with Alex")
    #expect(first.starred)
    #expect(first.hasAudio)
    #expect(first.duration == 10)
    #expect(first.source == "Zoom")
    #expect(Set(first.speakers) == ["Speaker 1", "Speaker 2", "You"])
    #expect(try String(contentsOf: older.appendingPathComponent(MeetingStorage.transcriptMarkdownFile), encoding: .utf8)
        .hasPrefix("# Weekly sync with Alex"))

    // An empty title goes back to the recorded one.
    try await store.rename(older.lastPathComponent, title: "  ")
    #expect(try await store.summary(older.lastPathComponent).title == "Weekly sync")

    // A live folder can't be deleted; others can, and IDs can't escape the root.
    await #expect(throws: MeetingStoreError.busy(live.lastPathComponent)) { try await store.delete(live.lastPathComponent) }
    try await store.delete(newer.lastPathComponent)
    #expect(!FileManager.default.fileExists(atPath: newer.path))
    await #expect(throws: MeetingStoreError.notFound("../x")) { try await store.detail("../x") }
    await #expect(throws: MeetingStoreError.notFound("..")) { try await store.delete("..") }
}

@Test func retentionDeletesOldAudioUnlessStarredOrFlagged() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-8 * 86_400), recent = now.addingTimeInterval(-2 * 86_400)
    var ids: [String: String] = [:]
    for (key, started) in [("plain", old), ("starred", old), ("recent", recent)] {
        let directory = try Fixtures.meeting(in: root, name: "meeting \(key)", startedAt: started)
        try "[]".write(to: directory.appendingPathComponent(MeetingStorage.transcriptFile), atomically: true, encoding: .utf8)
        ids[key] = directory.lastPathComponent
    }
    let store = MeetingStore(root: root, options: Fixtures.options(spans: []))
    try await store.setStarred(ids["starred"]!, true)

    #expect(await store.applyRetention(now: now, keepAudio: true).isEmpty)
    #expect(await store.list().allSatisfy(\.hasAudio))

    #expect(await store.applyRetention(now: now, keepAudio: false) == [ids["plain"]!])
    let plain = try await store.detail(ids["plain"]!)
    #expect(!plain.summary.hasAudio)
    #expect(plain.systemAudio == nil && plain.microphoneAudio == nil)
    #expect(FileManager.default.fileExists(atPath: plain.summary.directory.appendingPathComponent(MeetingStorage.transcriptFile).path))
    #expect(try await store.summary(ids["starred"]!).hasAudio)
    #expect(try await store.summary(ids["recent"]!).hasAudio)
    // Once the star comes off, the next pass takes it.
    try await store.setStarred(ids["starred"]!, false)
    #expect(await store.applyRetention(now: now, keepAudio: false) == [ids["starred"]!])
}

@Test func anUnfinishedRecordingIsRepairedAndProcessedAtLaunch() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = try Fixtures.meeting(in: root, name: "2027-01-15 080000 Crashed", title: "Crashed", startedAt: started,
                                         ended: false, segments: [Fixtures.segment(.system, "are you still there", at: 0.5),
                                                                  Fixtures.segment(.microphone, "yes I am", at: 2.5)])
    // The recorder died: headers still say zero bytes, a half sample at the end, and a torn last line.
    for track in MeetingTrack.allCases {
        let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
        try Fixtures.writeWAV(Fixtures.silence(seconds: 3), to: url, finished: false)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01]))
        try handle.close()
    }
    try "{\"sample\":0,\"host\":0.25}\n{\"sample\":16000,\"host\":1.00}\n{\"sample\":32".write(
        to: directory.appendingPathComponent(MeetingStorage.timingFile(.system)), atomically: true, encoding: .utf8)
    try Fixtures.age(directory)

    let store = MeetingStore(root: root, options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 2)]))
    #expect(try await store.summary(directory.lastPathComponent).state == .interrupted)
    #expect(await store.repairUnfinished() == [directory.lastPathComponent])

    let summary = try await store.summary(directory.lastPathComponent)
    #expect(summary.state == .ready)
    #expect(summary.wasInterrupted)
    // Last timing entry: 1.00 s at sample 16000, plus the 32000 samples after it (session.json keeps whole seconds).
    let endedAt = try #require(summary.endedAt)
    #expect(abs(endedAt.timeIntervalSince(started) - 3.0) < 0.01)
    for track in MeetingTrack.allCases {
        let url = directory.appendingPathComponent(MeetingStorage.audioFile(track))
        #expect(MeetingStore.audioBytes(url) == 44 + 96_000)
        #expect(try WAVFile.readSamples(url).count == 48_000)
    }
    #expect(try transcript(directory).map(\.speaker) == ["Speaker 1", "You"])
    // Nothing is left to repair.
    #expect(await store.repairUnfinished().isEmpty)
}

@Test func aFolderStillBeingWrittenIsNotRepaired() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2027-01-15 080000 Live", ended: false)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: []))
    #expect(await store.repairUnfinished().isEmpty)
    #expect(try await store.summary(directory.lastPathComponent).state == .recording)

    // This process's own recording stays recording whatever the file dates say.
    try Fixtures.age(directory)
    await store.setRecording(directory.lastPathComponent, true)
    #expect(await store.repairUnfinished().isEmpty)
    await #expect(throws: MeetingStoreError.busy(directory.lastPathComponent)) { try await store.deleteAudio(directory.lastPathComponent) }
}

@Test func aFailedRunIsRecordedAndClearedOnRetry() async throws {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "diarizer unavailable" } }
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let failing = MeetingStore(root: root, options: MeetingPostProcessOptions(diarizer: { _, _ in throw Boom() },
                                                                              dictationSpans: { _ in [] }))
    await #expect(throws: Boom.self) { try await failing.process(directory.lastPathComponent) }
    let failed = try await failing.summary(directory.lastPathComponent)
    #expect(failed.state == .failed)
    #expect(failed.failure == "diarizer unavailable")

    // A retry cut off by quit leaves the meeting pending, not failed, so the next launch runs it again.
    let quitting = MeetingStore(root: root, options: MeetingPostProcessOptions(diarizer: { _, _ in throw CancellationError() },
                                                                             dictationSpans: { _ in [] }))
    await #expect(throws: CancellationError.self) { try await quitting.process(directory.lastPathComponent) }
    #expect(try await quitting.summary(directory.lastPathComponent).state == .processing)
    #expect(try await quitting.summary(directory.lastPathComponent).failure == nil)

    let working = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await working.process(directory.lastPathComponent)
    #expect(try await working.summary(directory.lastPathComponent).state == .ready)
    #expect(try await working.summary(directory.lastPathComponent).failure == nil)
}

@Test func mutedAndDictatedMicrophoneLinesAreDropped() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "meeting", segments: [
        Fixtures.segment(.microphone, "said while muted", at: 1),
        Fixtures.segment(.microphone, "dictated into notes", at: 4),
        Fixtures.segment(.microphone, "said to the call", at: 7),
    ])
    try "{\"t\":0.5,\"muted\":true}\n{\"t\":3,\"muted\":false}\n".write(
        to: directory.appendingPathComponent(MeetingStorage.muteFile), atomically: true, encoding: .utf8)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: [], dictations: [3.8...5.5]))
    let turns = try await store.process(directory.lastPathComponent)
    #expect(turns.map(\.text) == ["said to the call"])
    let report = try #require(try await store.detail(directory.lastPathComponent).report)
    #expect(report.mutedSegmentsDropped == 1)
    #expect(report.dictationSegmentsDropped == 1)
}

@Test func linesAfterTheCallEndedAreDropped() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "meeting", segments: [
        Fixtures.segment(.microphone, "said to the call", at: 1),
        Fixtures.segment(.microphone, "heard in the room afterwards", at: 7),
    ])
    let url = directory.appendingPathComponent(MeetingStorage.sessionFile)
    var info = try JSONDecoder.meetingDates.decode(MeetingSessionInfo.self, from: Data(contentsOf: url))
    info.stopReason = "call ended"
    info.callEndedAt = 5
    try JSONEncoder.pretty.encode(info).write(to: url)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: []))
    let turns = try await store.process(directory.lastPathComponent)
    #expect(turns.map(\.text) == ["said to the call"])
    let report = try #require(try await store.detail(directory.lastPathComponent).report)
    #expect(report.afterCallSegmentsDropped == 1)
}

@Test func anExportedFixtureReplaysToTheSameTranscript() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    try "{\"t\":1,\"lines\":[\"4 AXTabGroup: Alex Kim, Computer audio muted\",\"4 AXTabGroup: Priya Shah, Computer audio muted\"]}\n"
        .write(to: directory.appendingPathComponent(MeetingStorage.accessibilityFile), atomically: true, encoding: .utf8)
    try "{\"t\":8,\"muted\":true}\n".write(to: directory.appendingPathComponent(MeetingStorage.muteFile), atomically: true, encoding: .utf8)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans, dictations: [0...0.1]))
    let id = directory.lastPathComponent
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 1", to: "Alex Kim")
    let original = try transcript(directory)

    let destination = root.appendingPathComponent("fixture")
    let files = try await store.exportFixture(id, to: destination)
    #expect(files.contains(MeetingStorage.audioFile(.system)) && files.contains(MeetingStorage.audioFile(.microphone)))
    #expect(files.contains(MeetingStorage.speakersFile) && files.contains(MeetingStorage.participantsFile))
    #expect(files.contains(MeetingStorage.dictationsFile) && files.contains(MeetingStorage.muteFile))
    #expect(files.contains(MeetingStorage.transcriptFile) && files.contains(MeetingStorage.segmentsFile))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(MeetingStorage.accessibilityFile).path))
    #expect(MeetingParticipants.read(destination).all == ["Alex Kim", "Priya Shah"])
    #expect(MeetingPostProcessor.readDictations(destination) == [0...0.1])

    // The fixture carries its own dictation spans; the history is never consulted.
    let replay = MeetingPostProcessOptions(diarizer: { _, _ in DiarizationResult(spans: threeVoiceSpans) },
                                           dictationSpans: { _ in [0...100] })
    let replayed = try await MeetingPostProcessor.run(directory: destination, options: replay)
    #expect(replayed.map(\.speaker) == original.map(\.speaker))
    #expect(replayed.map(\.text) == original.map(\.text))

    await #expect(throws: MeetingStoreError.destinationNotEmpty(destination.path)) { try await store.exportFixture(id, to: destination) }
}

@Test func aFixtureExportsWithoutTheRawCallWindowLog() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    // What a recording keeps by default: participants.json, written while the call ran, and no accessibility.jsonl.
    try JSONEncoder().encode(MeetingParticipants(all: ["Sam Rivera", "Alex Kim"], me: "Sam Rivera"))
        .write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    let id = directory.lastPathComponent
    _ = try await store.process(id)
    #expect(try await store.detail(id).participants.others == ["Alex Kim"])

    let destination = root.appendingPathComponent("fixture")
    let files = try await store.exportFixture(id, to: destination)
    #expect(files.contains(MeetingStorage.participantsFile))
    #expect(MeetingParticipants.read(destination) == MeetingParticipants(all: ["Sam Rivera", "Alex Kim"], me: "Sam Rivera"))
}

@Test func markdownExportHasFrontMatterThenTurns() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    try "{\"t\":1,\"lines\":[\"3 AXStaticText: Sam Rivera (Host, me)\",\"4 AXTabGroup: Alex \\\"AK\\\" Kim, Computer audio muted\"]}\n"
        .write(to: directory.appendingPathComponent(MeetingStorage.accessibilityFile), atomically: true, encoding: .utf8)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    let id = directory.lastPathComponent
    _ = try await store.process(id)
    try await store.rename(id, title: "Sync: Q1 plans")
    let detail = try await store.detail(id)
    let markdown = MeetingMarkdown.export(detail, timeZone: TimeZone(identifier: "UTC")!)
    let expectedHead = """
    ---
    title: "Sync: Q1 plans"
    date: 2027-01-15T08:00:00Z
    duration: "00:00:10"
    app: "Zoom"
    participants:
      - "Sam Rivera"
      - "Alex \\"AK\\" Kim"
    speakers:
    """
    #expect(markdown.hasPrefix(expectedHead))
    #expect(markdown.contains("\n---\n\n**Speaker 1** [00:00:00]  \nhello everyone\n\n**Speaker 2** [00:00:02]  \nthanks for joining\n"))
    #expect(markdown.contains("**You** [00:00:06]  \nhappy to be here"))
    let empty = MeetingMarkdown.export(title: "Solo", date: Date(timeIntervalSince1970: 0), duration: 0, app: "", participants: [],
                                       speakers: [], turns: [], timeZone: TimeZone(identifier: "UTC")!)
    #expect(empty == "---\ntitle: \"Solo\"\ndate: 1970-01-01T00:00:00Z\nduration: \"00:00:00\"\napp: \"\"\nparticipants: []\nspeakers: []\n---\n")
}

@Test(arguments: MeetingPostProcessOptions.presets)
func theSpeakerModelLoadsFromGoblinsOwnModelFolder(preset: String) {
    let files = MeetingSpeakerModel.files(preset: preset)
    #expect(files.directory.lastPathComponent == MeetingSpeakerModel.folder)
    #expect(files.directory.deletingLastPathComponent().lastPathComponent == "models")
    #expect(MeetingSpeakerModel.bundleName(preset: preset) == "Nemotron3Diarizer_\(preset).mlmodelc")
}

@Test func aProcessingRunStoppedByQuitIsRunAgainAtLaunch() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    _ = try await MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans)).process(id)

    // Re-processing a finished meeting, cut off by quit partway: the old transcript is still there.
    let quitting = MeetingStore(root: root, options: MeetingPostProcessOptions(diarizer: { _, _ in throw CancellationError() },
                                                                             dictationSpans: { _ in [] }))
    await #expect(throws: CancellationError.self) { try await quitting.process(id) }
    let pending = try await quitting.summary(id)
    #expect(pending.state == .processing)
    #expect(pending.failure == nil)

    let calls = Counter()
    let relaunched = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans, calls: calls))
    #expect(await relaunched.repairUnfinished() == [id])
    #expect(calls.value == 1)
    #expect(try await relaunched.summary(id).state == .ready)
    #expect(MeetingMetadata.read(directory).pending == false)
}

@Test func aKilledRunLeavesTheMeetingPendingAndAFailureIsNotRetriedAlone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    // What a run leaves behind when the app dies in the middle of it.
    var metadata = MeetingMetadata.read(directory)
    metadata.pending = true
    try metadata.write(directory)
    #expect(try await store.summary(id).state == .processing)

    struct Broken: Error {}
    let failing = MeetingStore(root: root, options: MeetingPostProcessOptions(diarizer: { _, _ in throw Broken() },
                                                                            dictationSpans: { _ in [] }))
    await #expect(throws: Broken.self) { try await failing.process(id) }
    #expect(try await failing.summary(id).state == .failed)
    #expect(MeetingMetadata.read(directory).pending == false)
    #expect(await failing.repairUnfinished().isEmpty)
}

@Test func aTranscriptThatWontDecodeIsFailedNotReady() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    #expect(try await store.summary(id).state == .ready)

    try Data("[{\"speaker\": \"Speaker 1\", \"sta".utf8).write(to: directory.appendingPathComponent(MeetingStorage.transcriptFile))
    let damaged = try await store.summary(id)
    #expect(damaged.state == .failed)
    #expect(damaged.failure == MeetingStore.unreadableTranscript)

    // Try Again rebuilds it.
    _ = try await store.process(id)
    #expect(try await store.summary(id).state == .ready)
    #expect(try transcript(directory).map(\.speaker) == ["Speaker 1", "Speaker 2", "You"])
}

@Test func reprocessingKeepsNamesOnTheVoicesTheyWereGivenTo() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    _ = try await MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans)).process(id)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")

    // A second run hears a third voice at the start, so the voice that was Speaker 2 is now Speaker 3.
    let split = [DiarizedSpan(speaker: 0, start: 0, end: 0.45), DiarizedSpan(speaker: 1, start: 0.45, end: 1.9),
                 DiarizedSpan(speaker: 2, start: 2.0, end: 4)]
    let turns = try await MeetingStore(root: root, options: Fixtures.options(spans: split)).process(id)
    #expect(turns.first { $0.text == "thanks for joining" }?.speaker == "Alex Kim")
    #expect(turns.filter { $0.speaker == "Alex Kim" }.count == 1)
    #expect(try await store.speakerNames(id) == ["Speaker 3": "Alex Kim"])
    #expect(try await store.detail(id).report?.namesCleared == nil)
}

@Test func aRerunCutOffBetweenNamesAndAttributionIsFinishedNotMixed() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")

    // A rerun numbered Alex's voice Speaker 3 and stopped once relabel.json was written; the old pair is untouched.
    var turns = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                               from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
    for index in turns.indices where turns[index].label == "Speaker 2" { turns[index].label = "Speaker 3" }
    try JSONEncoder.pretty.encode(MeetingPostProcessor.Relabel(turns: turns, names: ["Speaker 3": "Alex Kim"]))
        .write(to: directory.appendingPathComponent(MeetingStorage.relabelFile))

    let rendered = try MeetingPostProcessor.render(directory: directory)
    #expect(rendered.first { $0.text == "thanks for joining" }?.speaker == "Alex Kim")
    #expect(try await store.speakerNames(id) == ["Speaker 3": "Alex Kim"])
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.relabelFile).path))
}

@Test func speakerNamesAreReadAndReplacedOnlyAfterARelabelLeftBehindIsFinished() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")
    let relabelURL = directory.appendingPathComponent(MeetingStorage.relabelFile)
    var turns = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                               from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
    for index in turns.indices where turns[index].label == "Speaker 2" { turns[index].label = "Speaker 3" }
    let pending = try JSONEncoder.pretty.encode(MeetingPostProcessor.Relabel(turns: turns, names: ["Speaker 3": "Alex Kim"]))

    // The undo snapshot is the names for the attribution relabel.json holds, not the older pair's.
    try pending.write(to: relabelURL)
    #expect(try await store.speakerNames(id) == ["Speaker 3": "Alex Kim"])
    #expect(!FileManager.default.fileExists(atPath: relabelURL.path))

    // Replacing every name with a relabel pending: the replacement is what's left.
    try pending.write(to: relabelURL)
    let rendered = try await store.setSpeakerNames(id, ["Speaker 3": "Sam Lee"])
    #expect(rendered.first { $0.text == "thanks for joining" }?.speaker == "Sam Lee")
    #expect(try await store.speakerNames(id) == ["Speaker 3": "Sam Lee"])
}

@Test func fixtureExportFinishesARelabelLeftBehindFirst() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")
    var turns = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                               from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
    for index in turns.indices where turns[index].label == "Speaker 2" { turns[index].label = "Speaker 3" }
    try JSONEncoder.pretty.encode(MeetingPostProcessor.Relabel(turns: turns, names: ["Speaker 3": "Alex Kim"]))
        .write(to: directory.appendingPathComponent(MeetingStorage.relabelFile))

    let destination = root.appendingPathComponent("fixture", isDirectory: true)
    try await store.exportFixture(id, to: destination)

    // The fixture holds the pair relabel.json was for, not the older attribution with the newer names.
    let names = try JSONDecoder().decode([String: String].self,
                                         from: Data(contentsOf: destination.appendingPathComponent(MeetingStorage.speakersFile)))
    #expect(names == ["Speaker 3": "Alex Kim"])
    let attributed = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                                    from: Data(contentsOf: destination.appendingPathComponent(MeetingStorage.attributedFile)))
    #expect(attributed.first { $0.text == "thanks for joining" }?.label == "Speaker 3")
    #expect(try transcript(destination).first { $0.text == "thanks for joining" }?.speaker == "Alex Kim")
}

@Test func namesNoVoiceMatchesAfterReprocessingAreClearedAndSaid() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try threeVoiceMeeting(in: root)
    let id = directory.lastPathComponent
    let store = MeetingStore(root: root, options: Fixtures.options(spans: threeVoiceSpans))
    _ = try await store.process(id)
    _ = try await store.renameSpeaker(id, from: "Speaker 1", to: "Sam Rivera")
    _ = try await store.renameSpeaker(id, from: "Speaker 2", to: "Alex Kim")

    // Heard as one voice this time: neither name can be told apart, so both go rather than land on the wrong person.
    let turns = try await MeetingStore(root: root, options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 2.0, end: 4)])).process(id)
    #expect(!turns.contains { $0.speaker == "Sam Rivera" || $0.speaker == "Alex Kim" })
    #expect(try await store.detail(id).report?.namesCleared == ["Alex Kim", "Sam Rivera"])
    // Naming a voice again puts the note away.
    _ = try await store.renameSpeaker(id, from: "Speaker 1", to: "Sam Rivera")
    #expect(try await store.detail(id).report?.namesCleared == nil)
}

@Test func onlyTheDictatedWordsOfAMicLineAreLeftOut() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Words at 1.0, 1.3, … 2.8; the take ran from key-down at 1.85 s to key-up at 3.1 s.
    let directory = try Fixtures.meeting(in: root, name: "meeting", segments: [
        Fixtures.segment(.microphone, "I was saying that remind me tomorrow", at: 1),
    ])
    let store = MeetingStore(root: root, options: Fixtures.options(spans: [], dictations: [1.85...3.1]))
    let turns = try await store.process(directory.lastPathComponent)
    #expect(turns.map(\.text) == ["I was saying"])
    #expect(try await store.detail(directory.lastPathComponent).report?.dictationSegmentsDropped == 1)
}

@Test func aFolderStillBeingRecordedIsntProcessed() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "live", ended: false, segments: [Fixtures.segment(.system, "hi", at: 1)])
    let store = MeetingStore(root: root, options: Fixtures.options(spans: []))
    await #expect(throws: MeetingStoreError.busy("live")) { try await store.process(directory.lastPathComponent) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.transcriptFile).path))
}
