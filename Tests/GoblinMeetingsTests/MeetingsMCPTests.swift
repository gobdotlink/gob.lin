import Foundation
import Testing
@testable import GoblinMeetings

/// A finished meeting written as processing leaves it: session, transcript, notes, typed notes and marks.
@discardableResult
private func readyMeeting(in root: URL, name: String = "2027-01-15 080000 Weekly sync", title: String = "Weekly sync",
                          startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000), turns: [TranscriptTurn],
                          notes: String? = nil, typed: String? = nil, marks: [MeetingMark] = []) throws -> URL {
    let directory = try Fixtures.meeting(in: root, name: name, title: title, startedAt: startedAt, seconds: 1)
    // A finished meeting reads the same without its audio.
    for track in MeetingTrack.allCases { try FileManager.default.removeItem(at: directory.appendingPathComponent(MeetingStorage.audioFile(track))) }
    try JSONEncoder.pretty.encode(turns).write(to: directory.appendingPathComponent(MeetingStorage.transcriptFile))
    if let notes { try notes.write(to: directory.appendingPathComponent(MeetingNotesFile.markdownFile), atomically: true, encoding: .utf8) }
    if let typed { try MeetingTypedNotes.write(typed, to: directory) }
    if !marks.isEmpty { try MeetingMarks.write(marks, to: directory) }
    try Fixtures.age(directory)
    return directory
}

private func turn(_ speaker: String, _ text: String, at start: Double, track: MeetingTrack = .system) -> TranscriptTurn {
    TranscriptTurn(speaker: speaker, label: speaker, track: track, start: start, end: start + 5, text: text)
}

private let weeklyTurns = [
    turn("Sam Okafor", "Morning. Shall we start with the Kestrel launch?", at: 2),
    turn("You", "Yes. The launch moves to Thursday because the pricing page isn't ready.", at: 9, track: .microphone),
    turn("Sam Okafor", "Then I'll tell the sales team about the new pricing tiers.", at: 75),
    turn("You", "Great, and let's deploy the beta on Monday.", at: 130, track: .microphone),
]

private let weeklyNotes = """
# Kestrel launch moves to Thursday

The Kestrel launch slipped to Thursday while the pricing page is finished.

## Decisions
- Launch Kestrel on Thursday. [00:00:09]

## Action items
- [ ] **Sam Okafor**: Tell sales about the pricing tiers. [00:01:15]
"""

/// Sends one request and decodes the answer.
private func send(_ server: MeetingsMCPServer, _ method: String, _ params: JSONValue = .object([:]), id: JSONValue = 1) async throws -> JSONValue {
    let request: JSONValue = ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    let line = await server.handle(line: MeetingsMCPServer.encode(request))
    let reply = try #require(line)
    #expect(!reply.contains("\n"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
}

private func callText(_ server: MeetingsMCPServer, _ tool: String, _ arguments: JSONValue) async throws -> (text: String, isError: Bool) {
    let reply = try await send(server, "tools/call", ["name": .string(tool), "arguments": arguments])
    let result = try #require(reply["result"])
    guard case .array(let content)? = result["content"] else { Issue.record("no content"); return ("", true) }
    return (content.first?["text"]?.string ?? "", result["isError"]?.bool ?? false)
}

private let utc = TimeZone(identifier: "UTC")!

@Test func mcpHandshakeListsReadOnlyToolsAndAnswersOnlyRequests() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    let initialize = try await send(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": .object([:])], id: 7)
    #expect(initialize["id"] == 7)
    #expect(initialize["result"]?["protocolVersion"]?.string == "2025-06-18")
    #expect(initialize["result"]?["serverInfo"]?["name"]?.string == "goblin")
    #expect(initialize["result"]?["instructions"]?.string?.contains("misheard") == true)
    // An unknown version gets the newest one this server speaks.
    let future = try await send(server, "initialize", ["protocolVersion": "2099-01-01"])
    #expect(future["result"]?["protocolVersion"]?.string == MeetingsMCPServer.protocolVersions[0])

    let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(notification == nil)

    let tools = try await send(server, "tools/list")
    guard case .array(let list)? = tools["result"]?["tools"] else { Issue.record("no tools"); return }
    #expect(list.compactMap { $0["name"]?.string } == ["list_meetings", "search_meetings", "get_transcript", "get_notes"])
    #expect(list.allSatisfy { $0["annotations"]?["readOnlyHint"]?.bool == true && $0["annotations"]?["destructiveHint"]?.bool == false })

    let unknown = try await send(server, "meetings/delete")
    #expect(unknown["error"]?["code"]?.number == -32601)
    let unknownTool = try await send(server, "tools/call", ["name": "delete_meeting"])
    #expect(unknownTool["error"]?["code"]?.number == -32602)
    let garbage = try #require(await server.handle(line: "{not json"))
    #expect(garbage.contains("-32700"))
}

@Test func searchFindsMisheardWordsWordFormsAndQuotedPhrases() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try readyMeeting(in: root, turns: weeklyTurns, notes: weeklyNotes)
    try readyMeeting(in: root, name: "2027-01-16 090000 Design review", title: "Design review",
                     startedAt: Date(timeIntervalSince1970: 1_800_090_000), turns: [turn("Mira", "The new icons look great.", at: 4)])
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    // Speech recognition's spelling still finds the word, with its time, speaker and the lines either side.
    let misheard = try await callText(server, "search_meetings", ["query": "Kestral", "speaker": "Sam"])
    #expect(!misheard.isError)
    #expect(misheard.text.contains("[00:00:02] Sam Okafor:"))
    #expect(misheard.text.contains("**Kestrel**"))
    #expect(misheard.text.contains("after: [00:00:09] You:"))
    #expect(misheard.text.contains("meeting_id: 2027-01-15 080000 Weekly sync"))
    #expect(!misheard.text.contains("Design review"))

    let forms = try await callText(server, "search_meetings", ["query": "deploying", "fuzzy": false])
    #expect(forms.text.contains("**deploy**"))

    // Notes are searched too, and say where they're from.
    let notes = try await callText(server, "search_meetings", ["query": "tell sales"])
    #expect(notes.text.contains("from the notes"))

    let phrase = try await callText(server, "search_meetings", ["query": "\"pricing tiers\""])
    #expect(phrase.text.contains("▸ [00:01:15] Sam Okafor: Then I'll tell the sales team about the new **pricing** **tiers**."))
    // The line about the pricing page is only context before it, never a match.
    #expect(phrase.text.contains("before: [00:00:09] You:"))
    #expect(!phrase.text.contains("▸ [00:00:09]"))

    // A quoted word must appear as written: no near-misses, and the other words can't stand in for it.
    let quotedWord = try await callText(server, "search_meetings", ["query": "\"Kestral\" launch"])
    #expect(quotedWord.text.hasPrefix("Nothing in"))
    let exactWord = try await callText(server, "search_meetings", ["query": "\"Kestrel\" launch", "speaker": "Sam"])
    #expect(exactWord.text.contains("**Kestrel** **launch**"))

    let nothing = try await callText(server, "search_meetings", ["query": "\"tiers pricing\""])
    #expect(nothing.text.hasPrefix("Nothing in 2 meetings"))
    let missing = try await callText(server, "search_meetings", ["query": "   "])
    #expect(missing.isError)
}

@Test func transcriptsComeInPagesAndTimeRanges() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try readyMeeting(in: root, turns: weeklyTurns)
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    let range = try await callText(server, "get_transcript", ["meeting_id": "2027-01-15 080000 Weekly sync", "from": "1:00", "to": "2:00"])
    #expect(range.text.contains("[00:01:15] Sam Okafor: Then I'll tell"))
    #expect(!range.text.contains("[00:00:09]") && !range.text.contains("[00:02:10]"))

    #expect(try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "speaker": "Okafor"]).text.contains("Sam Okafor: Morning"))
    #expect(try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "speaker": "Oka"]).text.contains("No lines match"))
    let mine = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "speaker": "you"])
    #expect(mine.text.contains("[00:00:09] You:") && mine.text.contains("[00:02:10] You:") && !mine.text.contains("Sam Okafor:"))


    let bad = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "from": "soon"])
    #expect(bad.isError && bad.text.contains("from:"))
}

@Test func aLongTranscriptPagesThroughEveryLineOnce() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // 40 lines of about 100 characters: more than one 1,000-character page.
    let turns = (0..<40).map { turn($0.isMultiple(of: 2) ? "Sam Okafor" : "You", "Line \($0) " + String(repeating: "words ", count: 14), at: Double($0 * 10)) }
    try readyMeeting(in: root, turns: turns)
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    var seen: [String] = []
    var cursor: Int?
    var pages = 0
    for _ in 0..<20 {
        pages += 1
        var arguments: [String: JSONValue] = ["meeting_id": "Weekly sync", "max_chars": 1000]
        if let cursor { arguments["cursor"] = .number(Double(cursor)) }
        let page = try await callText(server, "get_transcript", .object(arguments))
        #expect(!page.isError)
        seen += page.text.matches(of: /\] [^:]+: (Line \d+)/).map { String($0.output.1) }
        guard let match = page.text.firstMatch(of: /cursor (\d+)/) else { cursor = nil; break }
        cursor = Int(match.output.1)
    }
    #expect(cursor == nil && pages > 1)
    #expect(seen == (0..<40).map { "Line \($0)" })
}

@Test func notesIncludeWhatWasTypedAndMarkedAndSayWhenThereAreNone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // notes.md copies the typed notes in under Your notes, as the app writes it; an ordinary [1] reference isn't a time.
    try readyMeeting(in: root, turns: weeklyTurns, notes: weeklyNotes + "\n- See the launch checklist [1]\n\n## Your notes\n- A template section that happens to share the heading\n\n## Your notes\nAsk Sam about Q3 budget\n\n_Notes by Codex, Auto template._\n",
                     typed: "Ask Sam about Q3 budget", marks: [MeetingMark(t: 75, label: "pricing")])
    try readyMeeting(in: root, name: "2027-01-16 090000 Design review", title: "Design review", turns: [turn("Mira", "Icons.", at: 4)])
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    let notes = try await callText(server, "get_notes", ["meeting_id": "weekly SYNC"])
    #expect(notes.text.contains("## Decisions"))
    #expect(notes.text.contains("## Typed during the meeting") && notes.text.contains("Q3 budget"))
    #expect(notes.text.contains("- [00:01:15] pricing"))
    // Only the copy of the typed notes goes: a section of the notes' own with that heading, and the footer, stay.
    #expect(notes.text.components(separatedBy: "Q3 budget").count == 2)
    #expect(notes.text.contains("happens to share the heading") && notes.text.contains("_Notes by Codex, Auto template._"))
    let typed = try await callText(server, "search_meetings", ["query": "budget"])
    #expect(typed.text.hasPrefix("1 passage") && typed.text.contains("from the your notes"))
    // The byline stays in the notes but isn't something said or decided.
    let byline = try await callText(server, "search_meetings", ["query": "Codex"])
    #expect(byline.text.hasPrefix("Nothing in"))
    let reference = try await callText(server, "search_meetings", ["query": "checklist"])
    #expect(reference.text.contains("**checklist** [1]") && !reference.text.contains("[00:00:01]"))

    let none = try await callText(server, "get_notes", ["meeting_id": "Design review"])
    #expect(!none.isError && none.text.contains("No notes are stored"))

    let unknown = try await callText(server, "get_notes", ["meeting_id": "Retro"])
    #expect(unknown.isError && unknown.text.contains("list_meetings"))
}

@Test func aMeetingStillRecordingReadsAsProvisionalYouAndThem() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2027-01-17 100000 Standup", title: "Standup", startedAt: Date(), ended: false, segments: [
        Fixtures.segment(.system, "anyone blocked today", at: 1),
        Fixtures.segment(.microphone, "not me", at: 4),
        Fixtures.segment(.microphone, "this is my private aside", at: 10),
        Fixtures.segment(.microphone, "dictated email to finance", at: 20),
        Fixtures.segment(.microphone, "after the call talking to the room", at: 40),
    ])
    // The call ended at 30 s; recording went on a little after it.
    var session = try JSONDecoder.meeting.decode(MeetingSessionInfo.self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
    session.callEndedAt = 30
    try JSONEncoder.pretty.encode(session).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
    // Muted from 9 to 15 s, and a dictation from 19 to 22 s: neither was said to the meeting.
    try "{\"t\":9,\"muted\":true}\n{\"t\":15,\"muted\":false}\n".write(to: directory.appendingPathComponent(MeetingStorage.muteFile), atomically: true, encoding: .utf8)
    try "{\"start\":19,\"end\":22}\n".write(to: directory.appendingPathComponent(MeetingStorage.liveDictationsFile), atomically: true, encoding: .utf8)
    let server = MeetingsMCPServer(root: root, timeZone: utc)
    // Recording all through the test, however long it takes.
    await server.query.store.setRecording(directory.lastPathComponent, true)

    let list = try await callText(server, "list_meetings", .object([:]))
    #expect(list.text.contains("recording now"))
    let transcript = try await callText(server, "get_transcript", ["meeting_id": "Standup"])
    #expect(transcript.text.contains("still recording"))
    #expect(transcript.text.contains("[00:00:01] Them: anyone blocked today"))
    #expect(transcript.text.contains("You: not me"))
    #expect(!transcript.text.contains("private aside") && !transcript.text.contains("finance") && !transcript.text.contains("talking to the room"))
    let aside = try await callText(server, "search_meetings", ["query": "private aside finance"])
    #expect(aside.text.hasPrefix("Nothing in"))
    let search = try await callText(server, "search_meetings", ["query": "blocked"])
    #expect(search.text.contains("provisional"))
    let finished = try await callText(server, "list_meetings", ["include_in_progress": false])
    #expect(finished.text == "No meetings match.")
}

@Test func listingFiltersByTimePersonAndWords() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_200_000)
    try readyMeeting(in: root, startedAt: now.addingTimeInterval(-3 * 86_400), turns: weeklyTurns, notes: weeklyNotes)
    try readyMeeting(in: root, name: "2027-01-16 090000 Design review", title: "Design review",
                     startedAt: now.addingTimeInterval(-3_600), turns: [turn("Mira", "Icons.", at: 4)])
    let server = MeetingsMCPServer(root: root, timeZone: utc, now: { now })

    let recent = try await callText(server, "list_meetings", ["since": "2d"])
    #expect(recent.text.contains("Design review") && !recent.text.contains("Weekly sync"))
    let sam = try await callText(server, "list_meetings", ["person": "sam"])
    #expect(sam.text.contains("Weekly sync") && !sam.text.contains("Design review") && sam.text.contains("notes: yes"))
    let words = try await callText(server, "list_meetings", ["query": "design"])
    #expect(words.text.hasPrefix("1 meeting:"))
    let limited = try await callText(server, "list_meetings", ["limit": 1])
    #expect(limited.text.hasPrefix("2 meetings match; the newest is below"))
    // A meeting named by id still has to be in the period asked about.
    let outside = try await callText(server, "search_meetings", ["query": "Kestrel", "meeting_id": "Weekly sync", "since": "2d"])
    #expect(outside.text.hasPrefix("That meeting is outside"))
    // Huge numbers are clamped, not a crash; a misspelled filter is an error, not ignored.
    let huge = try await callText(server, "list_meetings", ["limit": .number(1e300)])
    #expect(!huge.isError)
    let tiny = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "cursor": .number(-1e300), "max_chars": .number(1e300)])
    #expect(!tiny.isError && tiny.text.contains("[00:00:02]"))
    let misspelled = try await callText(server, "list_meetings", ["snce": "2d"])
    #expect(misspelled.isError && misspelled.text.contains("Unknown argument snce"))
    let wrongKind = try await callText(server, "list_meetings", ["since": ["days": 2]])
    #expect(wrongKind.isError && wrongKind.text.contains("since must be a string"))
    let fractional = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "cursor": .number(1.5)])
    #expect(fractional.isError && fractional.text.contains("cursor must be a whole number"))
    let nullMisspelled = try await callText(server, "list_meetings", ["snce": .null])
    #expect(nullMisspelled.isError)
    let blank = try await callText(server, "search_meetings", ["query": "Kestrel", "meeting_id": " "])
    #expect(blank.isError && blank.text.contains("meeting_id is empty"))
    // A near-miss is a letter or two off, not a longer word that starts the same.
    let prefix = try await callText(server, "search_meetings", ["query": "plan"])
    #expect(prefix.text.hasPrefix("Nothing in"))
}

@Test func youAndThemFollowTheRecorderWhateverTheirName() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // The recorder renamed from You to Will: the label stays You.
    let renamed = [TranscriptTurn(speaker: "Will", label: "You", track: .microphone, start: 2, end: 6, text: "I'll ship the beta."),
                   turn("Sam Okafor", "Great, ship it.", at: 8)]
    let directory = try readyMeeting(in: root, turns: renamed)
    // A failed meeting is done, not in progress.
    var metadata = MeetingMetadata()
    metadata.failure = "Diarization failed."
    try metadata.write(directory)
    try Fixtures.age(directory)
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    let mine = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync", "speaker": "You"])
    #expect(mine.text.contains("Will: I'll ship") && !mine.text.contains("Sam Okafor:"))
    let theirs = try await callText(server, "search_meetings", ["query": "ship", "speaker": "them"])
    #expect(theirs.text.contains("▸ [00:00:08] Sam Okafor") && !theirs.text.contains("▸ [00:00:02]"))
    let done = try await callText(server, "list_meetings", ["include_in_progress": false])
    #expect(done.text.contains("Weekly sync") && done.text.contains("failed"))
}

@Test func readingMeetingsChangesNothingOnDisk() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try readyMeeting(in: root, turns: weeklyTurns, notes: weeklyNotes)
    try Fixtures.meeting(in: root, name: "2027-01-17 100000 Standup", title: "Standup", ended: false,
                         segments: [Fixtures.segment(.system, "hi", at: 1)])
    // An interrupted recording, which the app would repair: reading it must not.
    try Fixtures.age(root.appendingPathComponent("2027-01-17 100000 Standup"))
    func snapshot() throws -> [String: Date] {
        var files: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])!
        for case let url as URL in enumerator {
            files[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return files
    }
    let before = try snapshot()
    let server = MeetingsMCPServer(root: root, timeZone: utc)
    for (tool, arguments) in [("list_meetings", JSONValue.object([:])), ("search_meetings", ["query": "launch"]),
                              ("get_transcript", ["meeting_id": "Standup"]), ("get_notes", ["meeting_id": "Weekly sync"])] {
        let result = try await callText(server, tool, arguments)
        #expect(!result.isError, "\(tool): \(result.text)")
    }
    let resources = try await send(server, "resources/list")
    guard case .array(let listed)? = resources["result"]?["resources"], let uri = listed.first?["uri"]?.string else {
        Issue.record("no resources"); return
    }
    let read = try await send(server, "resources/read", ["uri": .string(uri)])
    #expect(read["result"] != nil)
    #expect(try snapshot() == before)
    // A resource names its meeting exactly: a deleted one isn't answered with a lookalike.
    let gone = try await send(server, "resources/read", ["uri": .string(MeetingsMCPServer.resourceURI("2027-01-15 080000 Weekly"))])
    #expect(gone["error"] != nil)
}

@Test func aResourceOpensAMeetingWhoseIDEndsInASpace() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Titles are cut at 80 characters, which can leave the folder name ending in a space.
    try readyMeeting(in: root, name: "2027-01-15 080000 Weekly sync ", turns: weeklyTurns)
    let server = MeetingsMCPServer(root: root, timeZone: utc)
    let read = try await send(server, "resources/read", ["uri": .string(MeetingsMCPServer.resourceURI("2027-01-15 080000 Weekly sync "))])
    #expect(read["result"] != nil)
}

@Test func resourceURIsRoundTripMeetingIDs() {
    let id = "2027-01-15 080000 Meet – Q3 / plans"
    let uri = MeetingsMCPServer.resourceURI(id)
    #expect(!uri.contains(" ") && !uri.dropFirst("goblin-meeting://".count).contains("/"))
    #expect(MeetingsMCPServer.meetingID(fromResource: uri) == id)
    #expect(MeetingsMCPServer.meetingID(fromResource: "file:///etc/passwd") == nil)
}

@Test func timesParseAsDatesAgesAndOffsets() {
    let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    #expect(MeetingQuery.parseDate("today", now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_971_200))
    #expect(MeetingQuery.parseDate("yesterday", endOfDay: true, now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_971_200))
    #expect(MeetingQuery.parseDate("36h", now: now, timeZone: utc) == now.addingTimeInterval(-129_600))
    #expect(MeetingQuery.parseDate("2027-01-10", now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_539_200))
    #expect(MeetingQuery.parseDate("2027-01-10", endOfDay: true, now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_625_600))
    #expect(MeetingQuery.parseDate("2027-01-10T14:00:00Z", now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_589_600))
    #expect(MeetingQuery.parseDate("2027-01-10 14:00", now: now, timeZone: utc) == Date(timeIntervalSince1970: 1_799_589_600))
    #expect(MeetingQuery.parseDate("last tuesday", now: now, timeZone: utc) == nil)
    #expect(MeetingQuery.parseOffset("1:02:03") == 3_723)
    #expect(MeetingQuery.parseOffset("12:30") == 750)
    #expect(MeetingQuery.parseOffset("90s") == 90)
    #expect(MeetingQuery.parseOffset("-5") == nil)
    #expect(MeetingQuery.parseOffset("soon") == nil)
}

@Test func claudeDesktopSettingsKeepEverythingElse() async throws {
    let home = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = AIAppConnections.claudeDesktopConfig(home: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"preferences":{"sidebarMode":"chat"},"mcpServers":{"other":{"command":"/usr/bin/other","args":["--x"]}}}"#
        .write(to: file, atomically: true, encoding: .utf8)
    let command = ["/Applications/gob.lin.app/Contents/MacOS/GoblinApp", "mcp"]

    #expect(await AIAppConnections.state(.claudeDesktop, command: command, home: home) == .notConnected)
    try await AIAppConnections.connect(.claudeDesktop, command: command, home: home)
    #expect(await AIAppConnections.state(.claudeDesktop, command: command, home: home) == .connected)
    #expect(await AIAppConnections.state(.claudeDesktop, command: ["/tmp/GoblinApp", "mcp"], home: home)
            == .connectedElsewhere(command[0]))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((object["preferences"] as? [String: String]) == ["sidebarMode": "chat"])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    #expect((servers["other"] as? [String: Any])?["command"] as? String == "/usr/bin/other")
    #expect((servers["goblin"] as? [String: Any])?["args"] as? [String] == ["mcp"])

    try await AIAppConnections.disconnect(.claudeDesktop, home: home)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((object["mcpServers"] as? [String: Any])?.keys.sorted() == ["other"])

    // A server list that isn't one is left for the person to fix.
    try #"{"mcpServers":[{"command":"/usr/bin/other"}]}"#.write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: AIAppConnectionError.unexpectedConfig("claude_desktop_config.json")) {
        try await AIAppConnections.connect(.claudeDesktop, command: command, home: home)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == #"{"mcpServers":[{"command":"/usr/bin/other"}]}"#)

    // A file that doesn't parse is left exactly as it was.
    try "{ broken".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: AIAppConnectionError.unreadableConfig("claude_desktop_config.json")) {
        try await AIAppConnections.connect(.claudeDesktop, command: command, home: home)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "{ broken")
}

@Test func theCopiedCommandIsQuotedForAShell() {
    #expect(AIAppConnections.shellCommand(["/Applications/gob.lin.app/Contents/MacOS/GoblinApp", "mcp"])
            == "/Applications/gob.lin.app/Contents/MacOS/GoblinApp mcp")
    #expect(AIAppConnections.shellCommand(["/Users/a b/it's/GoblinApp", "mcp"]) == #"'/Users/a b/it'\''s/GoblinApp' mcp"#)
}

@Test func aMeetingProcessedAgainKeepsServingItsTranscript() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try readyMeeting(in: root, turns: weeklyTurns)
    // Its live lines are still there, and say something else.
    try Fixtures.writeSegments([Fixtures.segment(.system, "live only wording", at: 2)], to: directory)
    var metadata = MeetingMetadata()
    metadata.pending = true
    try metadata.write(directory)
    try Fixtures.age(directory)
    let server = MeetingsMCPServer(root: root, timeZone: utc)

    let list = try await callText(server, "list_meetings", .object([:]))
    #expect(list.text.contains("processing"))
    let transcript = try await callText(server, "get_transcript", ["meeting_id": "Weekly sync"])
    #expect(transcript.text.contains("[00:00:02] Sam Okafor:") && !transcript.text.contains("live lines"))
    #expect(!transcript.text.contains("live only wording"))
}

@Test func nothingIsReadWhileMeetingsIsOff() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try readyMeeting(in: root, turns: weeklyTurns)
    let server = MeetingsMCPServer(root: root, timeZone: utc, unavailable: { "Meetings is off." })

    let list = try await callText(server, "list_meetings", .object([:]))
    #expect(list.isError && list.text == "Meetings is off.")
    let resources = try await send(server, "resources/list")
    #expect(resources["result"]?["resources"] == .array([]))
    let read = try await send(server, "resources/read", ["uri": .string(MeetingsMCPServer.resourceURI("2027-01-15 080000 Weekly sync"))])
    #expect(read["error"]?["message"]?.string == "Meetings is off.")
}

@Test func aConversationInTheRoomStillRecordingIsNeitherYouNorThem() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2027-01-17 100000 Chat", title: "Chat", startedAt: Date(), ended: false,
                                         segments: [Fixtures.segment(.microphone, "lunch plans", at: 1)])
    var session = try JSONDecoder.meeting.decode(MeetingSessionInfo.self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
    session.kind = .inPerson
    try JSONEncoder.pretty.encode(session).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
    let server = MeetingsMCPServer(root: root, timeZone: utc)
    await server.query.store.setRecording(directory.lastPathComponent, true)

    #expect(try await callText(server, "get_transcript", ["meeting_id": "Chat"]).text.contains("Room: lunch plans"))
    #expect(try await callText(server, "get_transcript", ["meeting_id": "Chat", "speaker": "them"]).text.contains("No lines match"))
    #expect(try await callText(server, "get_transcript", ["meeting_id": "Chat", "speaker": "you"]).text.contains("No lines match"))
    #expect(try await callText(server, "get_transcript", ["meeting_id": "Chat", "speaker": "Room"]).text.contains("lunch plans"))
}

@Test func claudeSettingsKeepTheirSymlinkAndPermissions() async throws {
    let home = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = AIAppConnections.claudeDesktopConfig(home: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let target = home.appendingPathComponent("dotfiles-claude.json")
    try "{}".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

    try await AIAppConnections.connect(.claudeDesktop, command: ["/Applications/gob.lin.app/Contents/MacOS/GoblinApp", "mcp"], home: home)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8).contains("goblin"))
    #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o600)
}
