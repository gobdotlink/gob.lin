import CoreAudio
import Foundation
import Testing
@testable import GoblinMeetings

// Lines as AccessibilityProbe logs them: "<depth> <role>: <text>". Names are made up.

@Test func zoomSelfTileDecidesMuteWhenTheToolbarIsHidden() {
    let selfMuted = ["3 AXStaticText: Sam Rivera (Host, me)", "4 AXTabGroup: Sam Rivera, Computer audio muted",
                     "4 AXTabGroup: Alex Kim, Computer audio unmuted"]
    #expect(AccessibilityProbe.muteState(selfMuted) == true)
    // Someone else's muted tile says nothing about this person.
    let otherMuted = ["3 AXStaticText: Sam Rivera (Host, me)", "4 AXTabGroup: Sam Rivera, Computer audio unmuted",
                      "4 AXTabGroup: Alex Kim, Computer audio muted"]
    #expect(AccessibilityProbe.muteState(otherMuted) == false)
    #expect(AccessibilityProbe.muteState(["4 AXTabGroup: Alex Kim, Computer audio muted"]) == nil)
    // The account button names this person when no tile says "(me)".
    #expect(AccessibilityProbe.muteState(["2 AXButton: Zoom, Sam Rivera, In a Zoom Meeting",
                                          "4 AXTabGroup: Sam Rivera, Computer audio muted"]) == true)
}

@Test func aNameThatReadsLikeAMuteStateDoesNotCrashTheSelfTileCheck() {
    // The "(me)" element names this person "alex, computer audio muted"; the state is looked for after that name.
    #expect(AccessibilityProbe.muteState(["4 AXTabGroup: Alex, Computer audio muted (me)"]) == nil)
    #expect(AccessibilityProbe.muteState(["4 AXTabGroup: Alex, Computer audio muted (me)",
                                          "4 AXTabGroup: Alex, Computer audio muted, Computer audio unmuted"]) == false)
}

@Test func zoomToolbarButtonNamesTheOppositeOfTheState() {
    #expect(AccessibilityProbe.muteState(["6 AXButton: Unmute my audio"]) == true)
    #expect(AccessibilityProbe.muteState(["6 AXButton: Mute my audio"]) == false)
    #expect(AccessibilityProbe.muteState(["5 AXStaticText: You are muted now"]) == true)
    // The toolbar wins over a tile.
    #expect(AccessibilityProbe.muteState(["6 AXButton: Mute my audio", "3 AXStaticText: Sam Rivera (Host, me)",
                                          "4 AXTabGroup: Sam Rivera, Computer audio muted"]) == false)
}

@Test func meetMicrophoneButtonGivesTheState() {
    #expect(AccessibilityProbe.muteState(["9 AXButton: Turn on microphone"]) == true)
    #expect(AccessibilityProbe.muteState(["9 AXButton: Turn off microphone"]) == false)
    #expect(AccessibilityProbe.muteState(["9 AXButton: Turn on camera", "8 AXStaticText: Daily standup"]) == nil)
}

@Test func participantsComeFromTilesAndOptionsButtons() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = """
    {"t":1,"kind":"full","ms":12,"lines":["3 AXStaticText: Sam Rivera (Host, me)","4 AXTabGroup: Sam Rivera, Computer audio unmuted","4 AXTabGroup: Alex Kim, Computer audio muted","5 AXButton: More options for Jordan Lee","5 AXButton: More options for Sam Rivera's Zoom Meeting"]}
    {"t":2,"kind":"diff","ms":9,"added":["4 AXTabGroup: Priya Shah, No audio connected","4 AXTabGroup: Alex Kim, Computer audio unmuted"],"removed":[]}
    garbage
    """
    try log.write(to: directory.appendingPathComponent(MeetingStorage.accessibilityFile), atomically: true, encoding: .utf8)
    let participants = MeetingParticipants.read(directory)
    #expect(participants.all == ["Sam Rivera", "Alex Kim", "Jordan Lee", "Priya Shah"])
    #expect(participants.me == "Sam Rivera")
    #expect(participants.others == ["Alex Kim", "Jordan Lee", "Priya Shah"])

    // A fixture without the raw log falls back to participants.json.
    try FileManager.default.removeItem(at: directory.appendingPathComponent(MeetingStorage.accessibilityFile))
    try JSONEncoder().encode(participants).write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
    #expect(MeetingParticipants.read(directory) == participants)
}

@Test func roleSuffixesAreNotPartOfANameAndSelfIsListed() {
    let parsed = MeetingParticipants.parse("""
    {"t":1,"lines":["4 AXTabGroup: Sam Rivera (Host, me), Computer audio muted","4 AXTabGroup: Alex Kim (Co-host), Computer audio muted"]}
    """)
    #expect(parsed.all == ["Sam Rivera", "Alex Kim"])
    #expect(parsed.me == "Sam Rivera")
    #expect(parsed.others == ["Alex Kim"])
}

@Test func meetingTitlesLoseBrowserAndIndicatorSuffixes() {
    #expect(MeetingDetector.cleanTitle("Meet – abc-defg-hij – Microphone recording - Google Chrome – Sam") == "Meet – abc-defg-hij")
    #expect(MeetingDetector.cleanTitle("Meet - Design review - Audio playing - Arc") == "Meet - Design review")
    #expect(MeetingDetector.cleanTitle("Zoom Meeting") == "Zoom Meeting")
    #expect(MeetingDetector.cleanTitle("Meet – Dia standup - Google Chrome") == "Meet – Dia standup")
    #expect(MeetingDetector.cleanTitle("Meet – Safari review – Microphone recording - Google Chrome – Sam") == "Meet – Safari review")
    #expect(MeetingDetector.cleanTitle("  Weekly sync | Microsoft Teams ") == "Weekly sync | Microsoft Teams")
}

@Test func onlyMeetingLikeWindowTitlesCount() {
    for title in ["Meet - abc-defg-hij", "Meet – Design review", "meet.google.com/abc-defg-hij", "Zoom Meeting", "Zoom Webinar",
                  "Weekly sync | Microsoft Teams", "Huddle with Alex Kim", "FaceTime"] {
        #expect(MeetingDetector.looksLikeMeeting(title), "\(title)")
    }
    for title in ["Inbox - Gmail - Google Chrome", "Zoom", "Meeting notes.md", "Google Meet pricing - Google Search", ""] {
        #expect(!MeetingDetector.looksLikeMeeting(title), "\(title)")
    }
}

@Test func aWAVWithAStaleHeaderStillReadsInFull() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("system.wav")
    let samples = (0..<8_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    try Fixtures.writeWAV(samples, to: url, finished: false)
    let read = try WAVFile.readSamples(url)
    #expect(read.count == samples.count)
    #expect(zip(read, samples).allSatisfy { abs($0 - $1) < 1e-3 })
    // Header-only and empty files read as silence-free empties instead of failing.
    try WAVFile.header(dataBytes: 0).write(to: url)
    #expect(try WAVFile.readSamples(url).isEmpty)
}

@Test func repairingAHeaderUsesTheFileLengthAndDropsAHalfSample() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("microphone.wav")
    try Fixtures.writeWAV(Fixtures.silence(seconds: 1), to: url, finished: false)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0x7F]))
    try handle.close()
    #expect(try WAVFile.repairHeader(url) == 16_000)
    let data = try Data(contentsOf: url)
    #expect(data.count == 44 + 32_000)
    func uint32(at offset: Int) -> UInt32 { data[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    #expect(uint32(at: 4) == 36 + 32_000)
    #expect(uint32(at: 40) == 32_000)
}

@Test func storageRootCanBeMovedAndRestored() {
    let original = MeetingStorage.root
    defer { MeetingStorage.root = original }
    let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-meetings-root-test", isDirectory: true)
    MeetingStorage.root = elsewhere
    #expect(MeetingStorage.root == elsewhere.standardizedFileURL)
    #expect(MeetingStorage.defaultRoot.path.hasSuffix("Application Support/gob.lin/Meetings"))
}

@Test func newMeetingFoldersNeverCollide() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try MeetingStorage.newDirectory(title: "Design/review: v2", date: date, in: root)
    let second = try MeetingStorage.newDirectory(title: "Design/review: v2", date: date, in: root)
    #expect(first != second)
    #expect(first.lastPathComponent.hasSuffix(" Design-review- v2"))
    #expect(second.lastPathComponent == first.lastPathComponent + " 2")
    #expect(MeetingStorage.title(fromFolderName: first.lastPathComponent) == "Design-review- v2")
    #expect(MeetingStorage.date(fromFolderName: first.lastPathComponent) == date)
    #expect(MeetingStorage.safeName("..") == "Meeting")
    #expect(MeetingStorage.safeName("a\nb") == "a-b")
}

@Test func zoomSelfTileWithRoleSuffixGivesMuteState() {
    let account = "1 AXButton: Zoom, Sam Rivera, In a Zoom Meeting, Basic account"
    #expect(AccessibilityProbe.muteState([account, "1 AXTabGroup: Sam Rivera (Host, me), Computer audio muted"]) == true)
    #expect(AccessibilityProbe.muteState([account, "1 AXTabGroup: Sam Rivera (Host, me), Computer audio unmuted"]) == false)
    // Someone else's tile with a role suffix says nothing about the person's own mute.
    #expect(AccessibilityProbe.muteState([account, "1 AXTabGroup: Sam Riverside (Co-host), Computer audio muted"]) == nil)
}

@Test func participantsGatheredLiveMatchTheLogReading() {
    var collector = MeetingParticipants.Collector()
    collector.add(["3 AXStaticText: Sam Rivera (Host, me)", "4 AXTabGroup: Alex Kim, Computer audio muted"])
    collector.add(["5 AXButton: More options for Jordan Lee", "6 AXButton: Mute my audio"])
    collector.add(["4 AXTabGroup: Alex Kim, Computer audio unmuted"])
    let parsed = MeetingParticipants.parse("""
    {"t":1,"lines":["3 AXStaticText: Sam Rivera (Host, me)","4 AXTabGroup: Alex Kim, Computer audio muted"]}
    {"t":2,"added":["5 AXButton: More options for Jordan Lee","6 AXButton: Mute my audio","4 AXTabGroup: Alex Kim, Computer audio unmuted"]}
    """)
    #expect(collector.participants == parsed)
    #expect(collector.participants.all == ["Sam Rivera", "Alex Kim", "Jordan Lee"])
    #expect(collector.participants.me == "Sam Rivera")
}

@Test func theRawCallWindowLogIsOnlyKeptWhenAskedFor() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = AccessibilityProbe(pid: 1, isBrowser: false, directory: directory, sessionStart: Date(), rawLog: false)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.accessibilityFile).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.muteFile).path))
    _ = AccessibilityProbe(pid: 1, isBrowser: false, directory: directory, sessionStart: Date(), rawLog: true)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.accessibilityFile).path))
}

@Test func rebuildingMuteLeavesARecordingWithoutTheRawLogAlone() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_000)
    let muteURL = directory.appendingPathComponent(MeetingStorage.muteFile)
    try "{\"t\":3.00,\"muted\":true}\n".write(to: muteURL, atomically: true, encoding: .utf8)
    #expect(try AccessibilityProbe.rebuildMuteLog(directory: directory, sessionStart: start) == nil)
    #expect(try String(contentsOf: muteURL, encoding: .utf8) == "{\"t\":3.00,\"muted\":true}\n")

    try "{\"t\":1005,\"lines\":[\"6 AXButton: Unmute my audio\"]}\n{\"t\":1009,\"added\":[\"6 AXButton: Mute my audio\"],\"removed\":[\"6 AXButton: Unmute my audio\"]}\n"
        .write(to: directory.appendingPathComponent(MeetingStorage.accessibilityFile), atomically: true, encoding: .utf8)
    #expect(try AccessibilityProbe.rebuildMuteLog(directory: directory, sessionStart: start) == 2)
    #expect(try String(contentsOf: muteURL, encoding: .utf8) == "{\"t\":5.00,\"muted\":true}\n{\"t\":9.00,\"muted\":false}\n")
}

@Test func theDetectionLogGoesAtLaunchUnlessDebugging() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("detection.jsonl")
    try "{}\n".write(to: log, atomically: true, encoding: .utf8)
    MeetingDetector.removeLog(at: log, unless: true)
    #expect(FileManager.default.fileExists(atPath: log.path))
    MeetingDetector.removeLog(at: log, unless: false)
    #expect(!FileManager.default.fileExists(atPath: log.path))
}

@Test func toolbarPhrasesCountOnlyOnControls() {
    // Someone in the chat, or a caption, saying the words isn't the button.
    #expect(AccessibilityProbe.muteState(["7 AXStaticText: Alex Kim: can you turn on microphone please"]) == nil)
    #expect(AccessibilityProbe.muteState(["7 AXGroup: turn on microphone | Chat message"]) == nil)
    #expect(AccessibilityProbe.muteState(["7 AXStaticText: Unmute my audio"]) == nil)
    #expect(AccessibilityProbe.muteState(["7 AXStaticText: Alex Kim: you are muted now, by the way"]) == nil)
    // The controls themselves, as buttons, toggles or switches.
    #expect(AccessibilityProbe.muteState(["9 AXCheckBox/AXToggle: Turn on microphone (⌘ + d)"]) == true)
    #expect(AccessibilityProbe.muteState(["9 AXCheckBox/AXSwitch: Turn off microphone"]) == false)
    #expect(AccessibilityProbe.muteState(["9 AXButton: Turn off microphone | mic"]) == false)
    // A chat line beside the real button doesn't change what the button says.
    #expect(AccessibilityProbe.muteState(["7 AXStaticText: turn on microphone", "9 AXButton: Turn off microphone"]) == false)
}

@Test func aParticipantNamedLikeAControlIsNotTheControl() {
    // Zoom's own button, as it reads.
    #expect(AccessibilityProbe.muteState(["6 AXButton: Mute my audio | audio"]) == false)
    // Someone who calls themselves "Unmute my audio" gets a menu button with that name in it.
    #expect(AccessibilityProbe.muteState(["5 AXPopUpButton: More options for Unmute my audio",
                                          "6 AXButton: Mute my audio | audio"]) == false)
    #expect(AccessibilityProbe.muteState(["5 AXPopUpButton: More options for Unmute my audio"]) == nil)
    // Or a tile's button named just that: controls that disagree say nothing, and the self tile decides.
    #expect(AccessibilityProbe.muteState(["5 AXButton: Unmute my audio", "6 AXButton: Mute my audio | audio"]) == nil)
    #expect(AccessibilityProbe.muteState(["5 AXButton: Unmute my audio", "6 AXButton: Mute my audio | audio",
                                          "3 AXStaticText: Sam Rivera (Host, me)", "4 AXTabGroup: Sam Rivera, Computer audio unmuted"]) == false)
    // A name with brackets isn't a shortcut.
    #expect(AccessibilityProbe.muteState(["5 AXButton: Unmute my audio (Guest)"]) == nil)
}

@Test func aMuteNobodyCanSeeAnyMoreGoesUnknown() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_000)
    // Muted at 5 s; the meeting's tab is left at 10 s, and nothing says either way until 70 s.
    try """
    {"t":1005,"kind":"full","lines":["9 AXButton: Turn on microphone"]}
    {"t":1010,"kind":"diff","added":["3 AXStaticText: Inbox"],"removed":["9 AXButton: Turn on microphone"]}
    {"t":1070,"kind":"full","lines":["3 AXStaticText: Inbox"]}
    {"t":1080,"kind":"diff","added":["9 AXButton: Turn on microphone"],"removed":["3 AXStaticText: Inbox"]}
    """.write(to: directory.appendingPathComponent(MeetingStorage.accessibilityFile), atomically: true, encoding: .utf8)
    #expect(try AccessibilityProbe.rebuildMuteLog(directory: directory, sessionStart: start) == 3)
    let text = try String(contentsOf: directory.appendingPathComponent(MeetingStorage.muteFile), encoding: .utf8)
    #expect(text == "{\"t\":5.00,\"muted\":true}\n{\"t\":40.00,\"muted\":false,\"unknown\":true}\n{\"t\":80.00,\"muted\":true}\n")
    // The words between 40 and 80 s are kept: the mute had expired.
    let timeline = MuteTimeline(jsonl: text)
    #expect(timeline.isMuted(at: 20))
    #expect(!timeline.isMuted(at: 60))
    #expect(timeline.isMuted(at: 90))
}

@Test func theSystemTrackHearsOnlyTheTapsOwnStream() {
    // The output device's two-channel input stream comes first, then the tap's mono stream, one frame shorter.
    let device: [Float] = [0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]
    let tap: [Float] = [0.1, 0.2, 0.3]
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    device.withUnsafeBufferPointer { devicePointer in
        tap.withUnsafeBufferPointer { tapPointer in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(device.count * 4),
                                  mData: UnsafeMutableRawPointer(mutating: devicePointer.baseAddress))
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(tap.count * 4),
                                  mData: UnsafeMutableRawPointer(mutating: tapPointer.baseAddress))
            #expect(SystemAudioTap.mixTap(list, skipping: 1) == [0.1, 0.2, 0.3])
            // No device streams: the same.
            #expect(SystemAudioTap.mixTap(UnsafeMutableAudioBufferListPointer(list.unsafeMutablePointer), skipping: 5) == [0.1, 0.2, 0.3])
        }
    }
    // Two buffers of different lengths mix only as far as the shorter one.
    let long: [Float] = [1, 1, 1, 1], short: [Float] = [0, 0]
    long.withUnsafeBufferPointer { a in
        short.withUnsafeBufferPointer { b in
            let mixed = SystemAudioTap.mix([AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: UnsafeMutableRawPointer(mutating: a.baseAddress)),
                                            AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: UnsafeMutableRawPointer(mutating: b.baseAddress))])
            #expect(mixed == [0.5, 0.5])
        }
    }
}
