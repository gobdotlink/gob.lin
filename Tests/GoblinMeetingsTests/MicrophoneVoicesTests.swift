import Foundation
import Testing
@testable import GoblinMeetings

/// A call's microphone shared with people in the room. The fake voice model is the one People's tests use: a stretch's
/// voiceprint is the loudness it was recorded at, so each synthetic "voice" is a level of a constant signal.
private enum Room {
    static func print(_ level: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimensions)
        vector[level] = 1
        return vector
    }

    /// Mostly `level`, a little of `blend`.
    static func print(_ level: Int, blend: Int, share: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimensions)
        vector[level] = 1 - share
        vector[blend] = share
        return Voiceprint.normalized(vector)
    }

    static let embed: VoiceprintEmbed = { samples in
        let mean = samples.reduce(0, +) / Float(max(1, samples.count))
        return print(Int((mean * 10).rounded()))
    }

    static func level(_ value: Float, seconds: Double) -> [Float] {
        [Float](repeating: value, count: Int(seconds * MeetingAudio.sampleRate))
    }

    /// You (level 5) for six seconds, a colleague beside you (level 3) for six, then someone on the call (level 1).
    static func call(in root: URL, name: String = "2026-11-16 100000 Standup") throws -> URL {
        let directory = try Fixtures.meeting(in: root, name: name, seconds: 18, segments: [
            Fixtures.segment(.microphone, "morning all here is where my part of the release has got to since last week", at: 0.5),
            Fixtures.segment(.microphone, "and from me the designs are done and I will send them round after this call", at: 6.5),
            Fixtures.segment(.system, "thanks both that all sounds good to me so let us ship it on Thursday then", at: 12.5),
        ])
        try Fixtures.writeWAV(level(0.5, seconds: 6) + level(0.3, seconds: 6) + level(0, seconds: 6),
                              to: directory.appendingPathComponent(MeetingStorage.audioFile(.microphone)))
        try Fixtures.writeWAV(level(0, seconds: 12) + level(0.1, seconds: 6),
                              to: directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
        try JSONEncoder().encode(MeetingParticipants(all: ["Ana Ruiz", "Mira Patel", "Jonas Berg"], me: "Ana Ruiz"))
            .write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
        return directory
    }

    /// The speaker model: two voices on the microphone (the louder track), one on the call's.
    static func options(_ people: PeopleStore, enabled: Bool = true, microphoneRuns: Counter = Counter()) -> MeetingPostProcessOptions {
        var options = MeetingPostProcessOptions(preset: "offline", diarizer: { samples, _ in
            guard (samples.max() ?? 0) > 0.2 else { return DiarizationResult(spans: [DiarizedSpan(speaker: 0, start: 12, end: 18)]) }
            microphoneRuns.increment()
            return DiarizationResult(spans: [DiarizedSpan(speaker: 0, start: 0, end: 6), DiarizedSpan(speaker: 1, start: 6, end: 12)])
        }, dictationSpans: { _ in [] })
        options.voices = MeetingVoiceOptions(enabled: { enabled }, embed: embed, people: people)
        return options
    }

    /// Your voice as People already knows it, from three earlier calls.
    static func knowYou(_ people: PeopleStore) throws {
        for call in ["a", "b", "c"] {
            try people.learn(meetingID: call, title: "Earlier", startedAt: Date(timeIntervalSince1970: 1_700_000_000), inPerson: false,
                             voices: [MeetingVoice(label: "You", track: .microphone, seconds: 20, clipStart: 0, clipEnd: 5, embedding: print(5))],
                             names: [:], me: "Ana Ruiz")
        }
    }
}

private func voice(_ id: Int, _ embedding: [Float]) -> MicrophoneVoices.Voice { .init(id: id, embedding: embedding) }

@Test func oneVoiceOnTheMicrophoneIsYouWhateverItSoundsLike() {
    // Nothing to tell it from: the person at this Mac, as the microphone always was.
    #expect(MicrophoneVoices.sort([voice(0, Room.print(7))], yourSamples: [Room.print(5)]) == .init(you: [0]))
    #expect(MicrophoneVoices.sort([], yourSamples: [Room.print(5)]) == .init())
}

@Test func voicesThatSoundAlikeAreOnePersonTheSpeakerModelSplit() {
    let sorted = MicrophoneVoices.sort([voice(0, Room.print(5)), voice(2, Room.print(5, blend: 6, share: 0.2))], yourSamples: [])
    #expect(sorted == .init(you: [0, 2]))
    #expect(!sorted.isShared)
}

@Test func theVoiceClosestToYourSamplesIsYouAndTheRestAreBesideYou() {
    let voices = [voice(0, Room.print(3)), voice(1, Room.print(5, blend: 6, share: 0.2)), voice(3, Room.print(3, blend: 4, share: 0.1)),
                  voice(4, Room.print(8))]
    let sorted = MicrophoneVoices.sort(voices, yourSamples: [Room.print(5), Room.print(5), Room.print(5)])
    #expect(sorted.you == [1])
    // The colleague the speaker model heard as two voices is one person.
    #expect(sorted.others == [[0, 3], [4]])
}

@Test func withSeveralVoicesAndNoneLikeYouNobodyIsYou() {
    let voices = [voice(0, Room.print(3)), voice(1, Room.print(8))]
    // Before any sample of you exists, and when you weren't one of them.
    #expect(MicrophoneVoices.sort(voices, yourSamples: []) == .init(you: [], others: [[0], [1]]))
    #expect(MicrophoneVoices.sort(voices, yourSamples: [Room.print(5)]) == .init(you: [], others: [[0], [1]]))
}

@Test func whileACallRecordsTheClosestVoiceStaysYouOnLessThanTheTranscriptAsks() {
    // A few seconds in, your voice is only half like your samples; the colleague's isn't like them at all.
    let voices = [voice(0, Room.print(5, blend: 6, share: 0.55)), voice(1, Room.print(3))]
    let yours = [Room.print(5), Room.print(5), Room.print(5)]
    #expect(MicrophoneVoices.sort(voices, yourSamples: yours).you.isEmpty)
    #expect(MicrophoneVoices.sort(voices, yourSamples: yours, live: true) == .init(you: [0], others: [[1]]))
    // Nobody anything like you is still nobody.
    #expect(MicrophoneVoices.sort([voice(0, Room.print(8)), voice(1, Room.print(3))], yourSamples: yours, live: true).you.isEmpty)
}

@Test func aFewSamplesLearnedFromASharedMicrophoneDontMakeAColleagueYou() {
    // Two of your five samples were really a colleague's voice: by the closest sample they'd be you.
    let yours = [Room.print(5), Room.print(5), Room.print(5), Room.print(3), Room.print(3)]
    #expect(MicrophoneVoices.similarityToYou(Room.print(3), samples: yours) == 0)
    #expect(MicrophoneVoices.similarityToYou(Room.print(5), samples: yours) == 1)
    let sorted = MicrophoneVoices.sort([voice(0, Room.print(3)), voice(1, Room.print(5))], yourSamples: yours)
    #expect(sorted == .init(you: [1], others: [[0]]))
}

@Test func aMicrophoneVoiceThatIsTheCallComingOutOfTheLoudspeakersIsNobodyInTheRoom() {
    let microphone = [DiarizedSpan(speaker: 0, start: 0, end: 10), DiarizedSpan(speaker: 1, start: 10, end: 20),
                      DiarizedSpan(speaker: 2, start: 20, end: 30)]
    // Voice 1 talks only while the call does; voice 2 talks over its last two seconds.
    let system = [DiarizedSpan(speaker: 0, start: 9, end: 15), DiarizedSpan(speaker: 1, start: 14, end: 22)]
    #expect(Set(MeetingPostProcessor.withoutCallSound(microphone, system: system).map(\.speaker)) == [0, 2])
    #expect(MeetingPostProcessor.withoutCallSound(microphone, system: []) == microphone)
}

@Test(.timeLimit(.minutes(1))) func someoneBesideYouOnACallGetsTheirOwnVoice() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    try Room.knowYou(people)
    let directory = try Room.call(in: meetings)
    let turns = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people))
    // Numbered with the call's own voices, in the order everyone first spoke.
    #expect(turns.map(\.speaker) == ["You", "Speaker 1", "Speaker 2"])
    #expect(turns.map(\.track) == [.microphone, .microphone, .system])
    let voices = try #require(MeetingVoices.read(directory))
    #expect(Set(voices.voices.map(\.label)) == ["You", "Speaker 1", "Speaker 2"])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.microphoneDiarizationFile).path))

    // Only your own voice was learned as you, and the colleague is nobody until named.
    let me = people.people().first(where: \.isMe)
    let you = try #require(me)
    #expect(you.samples.count == 4)
    #expect(you.samples.allSatisfy { $0.embedding == Room.print(5) })
    #expect(people.people().count == 1)

    // Named, they're a person of their own; on a timeline, someone beside you, not a guest on the call.
    let store = MeetingStore(root: meetings, options: Room.options(people))
    try await store.renameSpeaker(directory.lastPathComponent, from: "Speaker 1", to: "Sam Okafor")
    let known = people.people().first { $0.name == "Sam Okafor" }
    let sam = try #require(known)
    #expect(!sam.isMe)
    #expect(sam.samples.map(\.embedding) == [Room.print(3)])
    let detail = try await store.detail(directory.lastPathComponent)
    let lanes = MeetingTimeline.lanes(detail.turns)
    #expect(lanes.filter(\.isYou).map(\.name) == ["You"])
    #expect(lanes.first { $0.name == "Sam Okafor" }?.isOnMicrophoneOnly == true)
}

@Test(.timeLimit(.minutes(1))) func someoneKnownBesideYouIsNamedThoughTheCallNeverListedThem() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    try Room.knowYou(people)
    try people.learn(meetingID: "room", title: "Conversation", startedAt: Date(timeIntervalSince1970: 1_700_000_000), inPerson: true,
                     voices: [MeetingVoice(label: "Speaker 2", track: .microphone, seconds: 20, clipStart: 0, clipEnd: 5, embedding: Room.print(3))],
                     names: ["Speaker 2": "Sam Okafor"], me: nil)
    let directory = try Room.call(in: meetings)
    let turns = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people))
    #expect(turns.map(\.speaker) == ["You", "Sam Okafor", "Speaker 2"])
}

@Test(.timeLimit(.minutes(1))) func withRememberVoicesOffTheMicrophoneStaysOneVoice() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try Room.call(in: meetings)
    let runs = Counter()
    let turns = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people, enabled: false, microphoneRuns: runs))
    // Which voice is yours takes voiceprints, so without them the microphone isn't listened to for voices at all.
    #expect(turns.map(\.speaker) == ["You", "Speaker 1"])
    #expect(runs.value == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.microphoneDiarizationFile).path))
}

@Test(.timeLimit(.minutes(1))) func beforeYourVoiceIsKnownASharedMicrophoneHasNoYouAndTeachesNone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try Room.call(in: meetings)
    let turns = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people))
    #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 3"])
    // A blend of two people is never what your voice is first learned from.
    #expect(people.people().isEmpty)
    // Saying which one is you makes them you.
    let store = MeetingStore(root: meetings, options: Room.options(people))
    try await store.renameSpeaker(directory.lastPathComponent, from: "Speaker 1", to: "You")
    #expect(people.people().map(\.isMe) == [true])
    #expect(people.people().first?.samples.map(\.embedding) == [Room.print(5)])
    let detail = try await store.detail(directory.lastPathComponent)
    #expect(MeetingTimeline.lanes(detail.turns).filter(\.isYou).map(\.name) == ["You"])
}

@Test func aSharedMicrophonesVoicesAreNumberedWithTheCallsInTheOrderTheySpoke() {
    func turn(_ label: String, _ track: MeetingTrack, at start: Double) -> TranscriptTurn {
        TranscriptTurn(speaker: label, label: label, track: track, start: start, end: start + 1, text: "one two")
    }
    let beside = MeetingPostProcessor.microphoneVoiceLabel(4)
    let turns = [turn("You", .microphone, at: 0), turn("Speaker 1", .system, at: 2), turn(beside, .microphone, at: 4),
                 turn("Speaker 2", .system, at: 6), turn(beside, .microphone, at: 8), turn("Mira Patel", .system, at: 9)]
    #expect(MeetingPostProcessor.numberVoices(turns).map(\.label) == ["You", "Speaker 1", "Speaker 2", "Speaker 3", "Speaker 2", "Mira Patel"])
    // A microphone that was one voice leaves the call's numbers as they were.
    let alone = [turn("You", .microphone, at: 0), turn("Speaker 2", .system, at: 2), turn("Speaker 1", .system, at: 4)]
    #expect(MeetingPostProcessor.numberVoices(alone) == alone)
}

@Test func aNameTheWholeMicrophoneHadStaysWithYouWhenItsVoicesAreToldApart() {
    func turn(_ label: String, _ start: Double, _ end: Double) -> TranscriptTurn {
        TranscriptTurn(speaker: label, label: label, track: .microphone, start: start, end: end, text: "one two")
    }
    // Processed before, the microphone was one voice, renamed to a nickname; now a colleague is heard on it too.
    let carried = MeetingPostProcessor.carryNames(["You": "Ana R"], from: [turn("You", 0, 20)],
                                                  to: [turn("You", 0, 8), turn("Speaker 2", 8, 20)])
    #expect(carried.names == ["You": "Ana R"])
    #expect(carried.cleared.isEmpty)
    // The same when more of your speech is heard this time than the one voice had before.
    let longer = MeetingPostProcessor.carryNames(["You": "Ana R"], from: [turn("You", 0, 4)],
                                                 to: [turn("You", 0, 12), turn("Speaker 2", 12, 20)])
    #expect(longer.names == ["You": "Ana R"])
}

@Test func onACallTheMicrophonesOwnVoiceIsYouUnlessItsNamedAfterSomeoneElseInPeople() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = PeopleStore(meetingsRoot: root.appendingPathComponent("Meetings"))
    func microphone(_ label: String, _ level: Int) -> MeetingVoice {
        MeetingVoice(label: label, track: .microphone, seconds: 20, clipStart: 0, clipEnd: 5, embedding: Room.print(level))
    }
    try people.learn(meetingID: "m1", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [microphone("You", 5), microphone("Speaker 2", 3)], names: ["Speaker 2": "Sam Okafor"], me: "Ana Ruiz")
    #expect(people.people().map(\.name) == ["Ana Ruiz", "Sam Okafor"])
    #expect(people.people().map(\.isMe) == [true, false])
    // The next call was taken on this Mac by Sam alone, and its microphone is named after him.
    try people.learn(meetingID: "m2", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [microphone("You", 3)], names: ["You": "Sam Okafor"], me: "Ana Ruiz")
    #expect(people.people().first { $0.name == "Sam Okafor" }?.samples.count == 2)
    #expect(people.people().first(where: \.isMe)?.samples.count == 1)
}

@Test func aVoiceBesideYouIsMatchedToAnyoneButYouAndTheMicrophonesOwnVoiceToNobody() {
    func person(_ name: String, _ level: Int, isMe: Bool = false) -> Person {
        Person(name: name, isMe: isMe, samples: [VoiceSample(meetingID: "earlier", meetingTitle: "Earlier", label: "Speaker 1", track: .system,
                                                             heardAt: Date(timeIntervalSince1970: 1_700_000_000), seconds: 20,
                                                             clipStart: 0, clipEnd: 5, inPerson: false, embedding: Room.print(level))])
    }
    func microphone(_ label: String, _ level: Int) -> MeetingVoice {
        MeetingVoice(label: label, track: .microphone, seconds: 20, clipStart: 0, clipEnd: 5, embedding: Room.print(level))
    }
    let people = [person("Ana Ruiz", 5, isMe: true), person("Sam Okafor", 3)]
    // The call listed neither of them: someone in the room needn't have joined it.
    let matches = VoiceMatching.match([microphone("You", 3), microphone("Speaker 2", 3), microphone("Speaker 3", 5)], people: people,
                                      participants: MeetingParticipants(all: ["Mira Patel"]), inPerson: false)
    #expect(matches.keys.sorted() == ["Speaker 2"])
    #expect(matches["Speaker 2"]?.name == "Sam Okafor")
}

@Test func peopleBesideYouArentTakenForASharedLaptopOnTheCall() {
    func turn(_ speaker: String, _ track: MeetingTrack, at start: Double) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, label: speaker, track: track, start: start, end: start + 1, text: "one two three")
    }
    let lanes = MeetingTimeline.lanes([turn("You", .microphone, at: 0), turn("Speaker 1", .microphone, at: 1), turn("Speaker 2", .microphone, at: 2),
                                       turn("Priya Shah", .system, at: 3)])
    #expect(lanes.filter(\.isYou).map(\.name) == ["You"])
    #expect(lanes.filter(\.isOnMicrophoneOnly).map(\.name) == ["You", "Speaker 1", "Speaker 2"])
    let participants = MeetingParticipants(all: ["Ana Ruiz", "Priya Shah"], me: "Ana Ruiz")
    #expect(SpeakerSuggestions.extraVoices(lanes: lanes, participants: participants) == 0)
}

private func snapshot(_ track: MeetingTrack, arrival: [Int], known: [Int: String] = [:], besideYou: [Int: Int] = [:],
                      you: Set<Int> = []) -> LiveSpeakers.Snapshot {
    LiveSpeakers.Snapshot(track: track, placedFrom: 0, placedUntil: 60, spans: [], names: [:], arrival: arrival, known: known,
                          besideYou: besideYou, you: you)
}

@Test func liveTheCallsVoicesAndThePeopleBesideYouShareOneRunOfNumbers() {
    var names = LiveVoiceNames()
    func name(_ track: MeetingTrack, _ voice: Int, remembers: Bool = true) -> String? {
        names.name(.init(track: track, voice: voice), remembersVoices: remembers)
    }
    names.take(snapshot(.system, arrival: [2]))
    // Two voices on the mic, and nothing yet says either isn't you.
    names.take(snapshot(.microphone, arrival: [0, 1]))
    #expect(name(.system, 2) == "Speaker 1")
    #expect(name(.microphone, 0) == nil)
    #expect(name(.microphone, 1) == nil)

    // Voice 1 turns out to be someone else, heard as voices 1 and 3; then another caller comes in.
    names.take(snapshot(.microphone, arrival: [0, 1, 3], besideYou: [1: 1, 3: 1], you: [0]))
    names.take(snapshot(.system, arrival: [2, 0]))
    #expect(name(.microphone, 0) == nil)
    #expect(name(.microphone, 1) == "Speaker 2")
    #expect(name(.microphone, 3) == "Speaker 2")
    #expect(name(.system, 0) == "Speaker 3")

    // People knows them: the name shows, and their number isn't handed to anyone else.
    names.take(snapshot(.microphone, arrival: [0, 1, 3, 2], known: [1: "Sam Okafor", 3: "Sam Okafor"], besideYou: [1: 1, 3: 1, 2: 2],
                        you: [0]))
    #expect(name(.microphone, 3) == "Sam Okafor")
    #expect(name(.microphone, 2) == "Speaker 4")

    // A mic voice that only talks while the call does is the call, coming back out of the loudspeakers: still You.
    var echo = LiveVoiceNames()
    var call = snapshot(.system, arrival: [0])
    call.spans = [DiarizedSpan(speaker: 0, start: 10, end: 40)]
    var heard = snapshot(.microphone, arrival: [0, 1, 2], besideYou: [1: 1, 2: 2], you: [0])
    heard.spans = [DiarizedSpan(speaker: 0, start: 0, end: 9), DiarizedSpan(speaker: 1, start: 12, end: 30),
                   DiarizedSpan(speaker: 2, start: 41, end: 60)]
    echo.take(call)
    echo.take(heard)
    #expect(echo.name(.init(track: .microphone, voice: 1), remembersVoices: true) == nil)
    #expect(echo.name(.init(track: .microphone, voice: 2), remembersVoices: true) == "Speaker 2")

    // Remember voices turned off mid-call: the mic is one voice again, and the call's keep only their numbers.
    #expect(name(.microphone, 3, remembers: false) == nil)
    #expect(name(.system, 2, remembers: false) == "Speaker 1")
}

@Test func whatWasSaidWhileMutedDoesntMakeSomeoneBesideYouTheCallsOwnSound() {
    // Ten seconds under the call while muted, then five to the meeting with the call quiet.
    let microphone = [DiarizedSpan(speaker: 0, start: 0, end: 8), DiarizedSpan(speaker: 1, start: 10, end: 20),
                      DiarizedSpan(speaker: 1, start: 30, end: 35)]
    let system = [DiarizedSpan(speaker: 0, start: 9, end: 21)]
    #expect(MeetingPostProcessor.callSoundVoices(microphone, system: system) == [1])
    #expect(MeetingPostProcessor.callSoundVoices(microphone, system: system, excluded: [9.0...21.0]).isEmpty)
    // A voice heard only while muted has nothing left to be judged by, and isn't called the call's sound for it.
    #expect(MeetingPostProcessor.outside([DiarizedSpan(speaker: 2, start: 4, end: 12)], [0.0...5.0, 8.0...10.0])
        == [DiarizedSpan(speaker: 2, start: 5, end: 8), DiarizedSpan(speaker: 2, start: 10, end: 12)])
}

private func microphoneTurn(_ label: String, _ start: Double, _ end: Double, track: MeetingTrack = .microphone) -> TranscriptTurn {
    TranscriptTurn(speaker: label, label: label, track: track, start: start, end: end, text: "one two")
}

@Test func whenASharedMicrophoneGoesBackToOneVoiceYouKeepsOnlyYourOwnName() {
    // Told apart before: you for 8 s, a named guest for 12. Run again with Remember voices off, it's one voice.
    let before = [microphoneTurn("You", 0, 8), microphoneTurn("Speaker 2", 8, 20)]
    let guest = MeetingPostProcessor.carryNames(["Speaker 2": "Sam Okafor"], from: before, to: [microphoneTurn("You", 0, 20)])
    #expect(guest.names.isEmpty)
    #expect(guest.cleared == ["Sam Okafor"])
    let nickname = MeetingPostProcessor.carryNames(["You": "Ana R", "Speaker 2": "Sam Okafor"], from: before,
                                                   to: [microphoneTurn("You", 0, 20)])
    #expect(nickname.names == ["You": "Ana R"])
}

@Test func aBorrowersNameOnTheWholeMicrophoneDoesntGoToTheVoiceNowKnownToBeYou() {
    // The whole microphone was named after someone else in People; told apart, one of its voices is you.
    let carried = MeetingPostProcessor.carryNames(["You": "Sam Okafor"], from: [microphoneTurn("You", 0, 20)],
                                                  to: [microphoneTurn("You", 0, 8), microphoneTurn("Speaker 2", 8, 20)],
                                                  others: ["sam okafor"])
    #expect(carried.names.isEmpty)
    // Still one voice, it was Sam's microphone that day and stays his.
    let whole = MeetingPostProcessor.carryNames(["You": "Sam Okafor"], from: [microphoneTurn("You", 0, 20)],
                                                to: [microphoneTurn("You", 0, 20)], others: ["Sam Okafor"])
    #expect(whole.names == ["You": "Sam Okafor"])
}

@Test(.timeLimit(.minutes(1))) func aBorrowerKnownOnlyFromThisCallStillKeepsTheirNameOffYou() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let then = Date(timeIntervalSince1970: 1_700_000_000)
    func heard(_ label: String, _ track: MeetingTrack) -> MeetingVoice {
        MeetingVoice(label: label, track: track, seconds: 20, clipStart: 0, clipEnd: 5, embedding: Room.print(3))
    }
    try people.learn(meetingID: "earlier", title: "Earlier", startedAt: then, inPerson: false, voices: [heard("Speaker 1", .system)],
                     names: ["Speaker 1": "Sam Okafor"], me: "Ana Ruiz")
    // The microphone was one voice, named after Sam; then the other call he was known from was deleted.
    let directory = try Room.call(in: meetings)
    _ = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people, enabled: false))
    try JSONEncoder().encode(["You": "Sam Okafor"]).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile))
    try people.learn(meetingID: directory.lastPathComponent, title: "Standup", startedAt: then, inPerson: false,
                     voices: [heard("You", .microphone)], names: ["You": "Sam Okafor"], me: "Ana Ruiz")
    try people.forget(meetingID: "earlier")
    #expect(people.people().map(\.name) == ["Sam Okafor"])
    try Room.knowYou(people)

    // Told apart now, the voice recognised as you doesn't take his name.
    let turns = try await MeetingPostProcessor.run(directory: directory, options: Room.options(people))
    #expect(turns.map(\.speaker) == ["You", "Speaker 1", "Speaker 2"])
    #expect(MeetingPostProcessor.speakerNames(directory)["You"] == nil)
}

@Test func yourNicknameFollowsYourVoiceWhenARerunFindsNobodyToBeYou() {
    // You were one voice among two, under a nickname. With your samples gone, the rerun numbers both voices.
    let before = [microphoneTurn("You", 0, 8), microphoneTurn("Speaker 2", 8, 20)]
    let carried = MeetingPostProcessor.carryNames(["You": "Ana R"], from: before,
                                                  to: [microphoneTurn("Speaker 1", 0, 8), microphoneTurn("Speaker 2", 8, 20)])
    #expect(carried.names == ["Speaker 1": "Ana R"])
}

@Test func aVoiceMergedIntoYouAndRenamedIsStillYourLane() {
    // You and a fragment of you the speaker model split off, merged and given a nickname: every paragraph joins both.
    let attributed = [microphoneTurn("You", 0, 2), microphoneTurn("Speaker 2", 2, 4), microphoneTurn("Speaker 1", 5, 7, track: .system)]
    let named = attributed.map { turn -> TranscriptTurn in
        var turn = turn
        if turn.track == .microphone { turn.speaker = "Ana R" }
        return turn
    }
    let rendered = MeetingPostProcessor.merge(named, by: \.speaker, joining: .paragraphs)
    #expect(rendered.map(\.label) == ["You", "Speaker 1"])
    #expect(MeetingTimeline.lanes(rendered).filter(\.isYou).map(\.name) == ["Ana R"])
}

@Test func aVoiceSomeoneNamedYouIsLearnedHoweverUnlikeYourOtherSamples() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = PeopleStore(meetingsRoot: root.appendingPathComponent("Meetings"))
    func microphone(_ label: String, _ level: Int) -> MeetingVoice {
        MeetingVoice(label: label, track: .microphone, seconds: 20, clipStart: 0, clipEnd: 5, embedding: Room.print(level))
    }
    for meeting in ["m1", "m2", "m3"] {
        try people.learn(meetingID: meeting, title: "Call", startedAt: Date(), inPerson: false, voices: [microphone("You", 5)],
                         names: [:], me: "Ana Ruiz")
    }
    // A shared microphone where nobody was known to be you, and you said That's Me on a voice unlike those samples.
    try people.learn(meetingID: "m4", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [microphone("Speaker 1", 7), microphone("Speaker 2", 3)], names: ["Speaker 1": "You"], me: "Ana Ruiz")
    #expect(people.people().first(where: \.isMe)?.meetingIDs.sorted() == ["m1", "m2", "m3", "m4"])
}

@Test func someoneBesideYouWhoTheCallAlsoListedIsntCountedAsComingThroughIt() {
    func turn(_ speaker: String, _ track: MeetingTrack, at start: Double) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, label: speaker, track: track, start: start, end: start + 1, text: "one two three")
    }
    // Sam joined on his own laptop without audio and talks beside you; Priya's laptop carried two voices.
    let lanes = MeetingTimeline.lanes([turn("You", .microphone, at: 0), turn("Sam Okafor", .microphone, at: 1),
                                       turn("Priya Shah", .system, at: 2), turn("Speaker 2", .system, at: 3)])
    let participants = MeetingParticipants(all: ["Ana Ruiz", "Sam Okafor", "Priya Shah"], me: "Ana Ruiz")
    #expect(SpeakerSuggestions.extraVoices(lanes: lanes, participants: participants) == 1)
    // The same whether or not the call listed him, or you.
    #expect(SpeakerSuggestions.extraVoices(lanes: lanes, participants: MeetingParticipants(all: ["Ana Ruiz", "Priya Shah"], me: "Ana Ruiz")) == 1)
    #expect(SpeakerSuggestions.extraVoices(lanes: lanes, participants: MeetingParticipants(all: ["Sam Okafor", "Priya Shah"])) == 1)
}

@Test func aGuestsNameOnAVoiceOnceTakenForYouDoesntGoToYourOwnWords() {
    // Told apart before, the guest's 12 s were taken for You and named after him. Run again, You is the other voice.
    let before = [microphoneTurn("Speaker 2", 0, 8), microphoneTurn("You", 8, 20)]
    let moved = MeetingPostProcessor.carryNames(["You": "Sam Okafor"], from: before,
                                                to: [microphoneTurn("You", 0, 8), microphoneTurn("Speaker 2", 8, 20)],
                                                others: ["Sam Okafor"])
    #expect(moved.names.isEmpty)
    #expect(moved.cleared == ["Sam Okafor"])
    // The same voice is You both times, numbered differently beside it: its nickname stays.
    let same = MeetingPostProcessor.carryNames(["You": "Ana R"], from: before,
                                               to: [microphoneTurn("Speaker 1", 0, 8), microphoneTurn("You", 9, 20)])
    #expect(same.names == ["You": "Ana R"])
}

@Test func liveSomeoneKnownAtYourMicWhileYouSayNothingKeepsTheirName() {
    // Sam takes the call at your Mac: his voice, known from People, and the call coming out of the loudspeakers.
    var names = LiveVoiceNames()
    var call = snapshot(.system, arrival: [0])
    call.spans = [DiarizedSpan(speaker: 0, start: 10, end: 40)]
    var heard = snapshot(.microphone, arrival: [0, 1], known: [0: "Sam Okafor"], besideYou: [0: 0, 1: 1])
    heard.spans = [DiarizedSpan(speaker: 0, start: 0, end: 9), DiarizedSpan(speaker: 1, start: 12, end: 30)]
    names.take(call)
    names.take(heard)
    #expect(names.name(.init(track: .microphone, voice: 0), remembersVoices: true) == "Sam Okafor")
    #expect(names.name(.init(track: .microphone, voice: 1), remembersVoices: true) == nil)
    #expect(names.name(.init(track: .microphone, voice: 0), remembersVoices: false) == nil)
}

@Test func liveACallTakenAloneBeforeYourVoiceIsKnownIsStillYou() {
    // No sample of you yet: your voice and the call coming out of the loudspeakers are both "beside you" at first.
    var names = LiveVoiceNames()
    var call = snapshot(.system, arrival: [0])
    call.spans = [DiarizedSpan(speaker: 0, start: 10, end: 40)]
    var heard = snapshot(.microphone, arrival: [0, 1], besideYou: [0: 0, 1: 1])
    heard.spans = [DiarizedSpan(speaker: 0, start: 0, end: 9), DiarizedSpan(speaker: 1, start: 12, end: 30)]
    names.take(call)
    names.take(heard)
    #expect(names.name(.init(track: .microphone, voice: 0), remembersVoices: true) == nil)
    #expect(names.name(.init(track: .microphone, voice: 1), remembersVoices: true) == nil)

    // Someone really beside a voice known to be you keeps their number.
    var shared = LiveVoiceNames()
    var room = snapshot(.microphone, arrival: [0, 1, 2], besideYou: [1: 1, 2: 2])
    room.you = [0]
    room.spans = [DiarizedSpan(speaker: 0, start: 0, end: 9), DiarizedSpan(speaker: 1, start: 12, end: 30),
                  DiarizedSpan(speaker: 2, start: 41, end: 60)]
    shared.take(call)
    shared.take(room)
    #expect(shared.name(.init(track: .microphone, voice: 1), remembersVoices: true) == nil)
    #expect(shared.name(.init(track: .microphone, voice: 2), remembersVoices: true) == "Speaker 2")
}
