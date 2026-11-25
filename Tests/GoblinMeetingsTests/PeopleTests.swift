import Foundation
import GoblinCore
import Testing
@testable import GoblinMeetings

/// People and Remember voices, with a fake voice model: a stretch's voiceprint is which loudness it was recorded at, so
/// each synthetic "voice" is a level of a constant signal.
private enum Voices {
    static func print(_ level: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimensions)
        vector[level] = 1
        return vector
    }

    /// Mostly `level`, a little of `blend`: similar enough to be the same voice, or not, by `share`.
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

    static func voice(_ label: String, _ embedding: [Float], track: MeetingTrack = .system) -> MeetingVoice {
        MeetingVoice(label: label, track: track, seconds: 20, clipStart: 0, clipEnd: 5, embedding: embedding)
    }

    static func person(_ name: String, _ embedding: [Float], isMe: Bool = false, meeting: String = "earlier") -> Person {
        Person(name: name, isMe: isMe, samples: [VoiceSample(meetingID: meeting, meetingTitle: "Earlier", label: "Speaker 1", track: .system,
                                                             heardAt: Date(timeIntervalSince1970: 1_700_000_000), seconds: 20,
                                                             clipStart: 0, clipEnd: 5, inPerson: false, embedding: embedding)])
    }
}

private func store(_ root: URL) -> PeopleStore { PeopleStore(meetingsRoot: root.appendingPathComponent("Meetings")) }

@Test func aNamedVoiceBecomesSomeoneInPeopleAndTheMicIsYou() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    try people.learn(meetingID: "m1", title: "Standup", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(2)),
                              Voices.voice("You", Voices.print(5), track: .microphone)],
                     names: ["Speaker 1": "Mira Patel"], me: "Ana Ruiz")
    let known = people.people()
    // Speaker 2 has no name yet, so nobody is learned from it.
    #expect(known.map(\.name) == ["Ana Ruiz", "Mira Patel"])
    #expect(known.first?.isMe == true)
    #expect(known.allSatisfy { $0.samples.count == 1 && $0.meetingIDs == ["m1"] })
}

@Test func renamingAVoiceMovesItsSampleAndUnnamingTakesItAway() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    let voices = [Voices.voice("Speaker 1", Voices.print(1))]
    try people.learn(meetingID: "m1", title: "Standup", startedAt: Date(), inPerson: false, voices: voices,
                     names: ["Speaker 1": "Jonas"], me: nil)
    try people.learn(meetingID: "m1", title: "Standup", startedAt: Date(), inPerson: false, voices: voices,
                     names: ["Speaker 1": "Mira"], me: nil)
    #expect(people.people().map(\.name) == ["Mira"])
    try people.learn(meetingID: "m1", title: "Standup", startedAt: Date(), inPerson: false, voices: voices, names: [:], me: nil)
    #expect(people.people().isEmpty)
}

@Test func guestsAndVoiceNumbersAreNeverPeople() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(2)),
                              Voices.voice("Them", Voices.print(3))],
                     names: ["Speaker 1": SpeakerSuggestions.guestName(on: "Sam"), "Speaker 2": "Speaker 3"], me: nil)
    #expect(people.people().isEmpty)
}

@Test func aClearMatchIsNamedAndACloseCallIsOnlySuggested() {
    let people = [Voices.person("Mira Patel", Voices.print(1)), Voices.person("Jonas Berg", Voices.print(2))]
    let voices = [Voices.voice("Speaker 1", Voices.print(1, blend: 9, share: 0.1)),   // ~0.99 like Mira
                  Voices.voice("Speaker 2", Voices.print(2, blend: 9, share: 0.38)),  // ~0.85 like Jonas... then checked below
                  Voices.voice("Speaker 3", Voices.print(9))]                         // nobody
    let matches = VoiceMatching.match(voices, people: people, participants: MeetingParticipants(), inPerson: false)
    #expect(matches["Speaker 1"]?.name == "Mira Patel")
    #expect(matches["Speaker 1"]?.named == true)
    let shad = Voiceprint.similarity(voices[1].embedding, Voices.print(2))
    #expect((matches["Speaker 2"]?.named ?? false) == (shad >= VoiceMatching.nameThreshold))
    #expect(matches["Speaker 3"] == nil)
    // Between the bars: suggested, not named.
    let close = Voices.voice("Speaker 4", Voices.print(1, blend: 9, share: 0.5))
    let similarity = Voiceprint.similarity(close.embedding, Voices.print(1))
    #expect(similarity >= VoiceMatching.suggestThreshold && similarity < VoiceMatching.nameThreshold)
    let suggested = VoiceMatching.match([close], people: people, participants: MeetingParticipants(), inPerson: false)
    #expect(suggested["Speaker 4"]?.named == false)
    #expect(suggested["Speaker 4"]?.name == "Mira Patel")
}

@Test func aCallsVoicesAreOnlyMatchedToItsParticipantsAndNeverToYou() {
    let people = [Voices.person("Mira Patel", Voices.print(1)), Voices.person("Ana Ruiz", Voices.print(5), isMe: true)]
    let voices = [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(5))]
    let elsewhere = VoiceMatching.match(voices, people: people, participants: MeetingParticipants(all: ["Sam Okafor", "Ana Ruiz"], me: "Ana Ruiz"),
                                        inPerson: false)
    #expect(elsewhere.isEmpty)
    let invited = VoiceMatching.match(voices, people: people, participants: MeetingParticipants(all: ["Mira Patel"]), inPerson: false)
    #expect(invited.keys.sorted() == ["Speaker 1"])
}

@Test func inTheRoomYourVoiceIsRecognisedAsYou() {
    let people = [Voices.person("Ana Ruiz", Voices.print(5), isMe: true), Voices.person("Mira", Voices.print(1))]
    let voices = [Voices.voice("Speaker 1", Voices.print(5), track: .microphone), Voices.voice("Speaker 2", Voices.print(1), track: .microphone)]
    let matches = VoiceMatching.match(voices, people: people, participants: MeetingParticipants(), inPerson: true)
    #expect(matches["Speaker 1"]?.name == MeetingPostProcessor.microphoneLabel)
    #expect(matches["Speaker 2"]?.name == "Mira")
}

@Test func oneStraySampleAmongAPersonsOthersNamesNobody() {
    func sample(_ meeting: String, _ embedding: [Float], inPerson: Bool = false) -> VoiceSample {
        VoiceSample(meetingID: meeting, meetingTitle: meeting, label: "You", track: .microphone, heardAt: Date(timeIntervalSince1970: 1_700_000_000),
                    seconds: 20, clipStart: 0, clipEnd: 5, inPerson: inPerson, embedding: embedding)
    }
    // Three calls of Ana's own voice, and one where a colleague did most of the talking into her microphone.
    let calls = [sample("m1", Voices.print(5)), sample("m2", Voices.print(5)), sample("m3", Voices.print(5)), sample("m4", Voices.print(1))]
    let colleague = [Voices.voice("Speaker 1", Voices.print(1), track: .microphone)]
    let ana = Person(name: "Ana Ruiz", isMe: true, samples: calls)
    #expect(VoiceMatching.match(colleague, people: [ana], participants: MeetingParticipants(), inPerson: true).isEmpty)
    // The colleague is still found when People knows them, however close the stray sample is.
    let mira = Voices.person("Mira Patel", Voices.print(1, blend: 9, share: 0.1))
    let known = VoiceMatching.match(colleague, people: [ana, mira], participants: MeetingParticipants(), inPerson: true)
    #expect(known["Speaker 1"]?.name == "Mira Patel")
    #expect(known["Speaker 1"]?.named == true)
    let own = VoiceMatching.match([Voices.voice("Speaker 2", Voices.print(5), track: .microphone)], people: [ana],
                                  participants: MeetingParticipants(), inPerson: true)
    #expect(own["Speaker 2"]?.named == true)

    // With too few to compare, the closest sample stands, as it does for someone heard once.
    let few = Person(name: "Ana Ruiz", isMe: true, samples: [calls[0], calls[3]])
    #expect(VoiceMatching.match(colleague, people: [few], participants: MeetingParticipants(), inPerson: true)["Speaker 1"]?.named == true)

    // The room's microphone hears a voice differently from a call's, so one room sample isn't held against the calls.
    let room = Person(name: "Ana Ruiz", isMe: true, samples: Array(calls[0...2]) + [sample("m5", Voices.print(1), inPerson: true)])
    #expect(VoiceMatching.match(colleague, people: [room], participants: MeetingParticipants(), inPerson: true)["Speaker 1"]?.named == true)
}

@Test func twoVoicesOfOneMeetingThatSoundAlikeAreOfferedAsOne() {
    let voices = [Voices.voice("Speaker 2", Voices.print(1)), Voices.voice("Speaker 5", Voices.print(1, blend: 9, share: 0.2)),
                  Voices.voice("Speaker 1", Voices.print(3))]
    let pairs = VoiceMatching.sameVoice(voices)
    #expect(pairs.count == 1)
    #expect(Set([pairs[0].0, pairs[0].1]) == ["Speaker 2", "Speaker 5"])
    let suggestions = VoiceSuggestions.suggestions(MeetingVoices(voices: voices), names: [:], people: [])
    #expect(suggestions["Speaker 5"]?.first?.name == "Speaker 2")
}

/// A call whose system track has two synthetic voices: level 0.1 for 0–6 s, level 0.3 for 6–12 s.
private func twoVoiceCall(in root: URL, name: String, participants: [String]) throws -> URL {
    let directory = try Fixtures.meeting(in: root, name: name, seconds: 12,
                                         segments: [Fixtures.segment(.system, "morning everyone here is my update for today and it is mostly about the release plan", at: 0.5),
                                                    Fixtures.segment(.system, "thanks and mine is that the release went out last night and nothing broke yet so far", at: 6.5)])
    let samples = [Float](repeating: 0.1, count: Int(6 * MeetingAudio.sampleRate)) + [Float](repeating: 0.3, count: Int(6 * MeetingAudio.sampleRate))
    try Fixtures.writeWAV(samples, to: directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
    try JSONEncoder().encode(MeetingParticipants(all: participants + ["Ana Ruiz"], me: "Ana Ruiz"))
        .write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
    return directory
}

private func voiceOptions(_ people: PeopleStore, enabled: Bool = true) -> MeetingPostProcessOptions {
    var options = Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 6), DiarizedSpan(speaker: 1, start: 6, end: 12)])
    options.voices = MeetingVoiceOptions(enabled: { enabled }, embed: Voices.embed, people: people)
    return options
}

@Test(.timeLimit(.minutes(1))) func aVoiceSomeoneWasNamedInBeforeIsNamedInTheNextCall() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let first = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    _ = try await MeetingPostProcessor.run(directory: first, options: voiceOptions(people))
    // Nobody known yet: both voices wait for names, and nothing is learned from them.
    #expect(people.people().filter { !$0.isMe }.isEmpty)
    let store = MeetingStore(root: meetings, options: voiceOptions(people))
    try await store.renameSpeaker(first.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    #expect(people.people().map(\.name) == ["Mira Patel"])

    let second = try twoVoiceCall(in: meetings, name: "2026-11-17 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    let turns = try await MeetingPostProcessor.run(directory: second, options: voiceOptions(people))
    #expect(turns.map(\.speaker) == ["Mira Patel", "Speaker 2"])
    let detail = try await store.detail(second.lastPathComponent)
    #expect(detail.namedFromVoice == ["Mira Patel"])
    #expect(people.people().first?.meetingIDs.count == 2)

    // Deleting the meeting forgets what it taught.
    try await store.delete(second.lastPathComponent)
    #expect(people.people().first?.meetingIDs == [first.lastPathComponent])
}

@Test(.timeLimit(.minutes(1))) func withRememberVoicesOffNoVoiceprintIsKept() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    _ = try await MeetingPostProcessor.run(directory: directory, options: voiceOptions(people, enabled: false))
    #expect(MeetingVoices.read(directory) == nil)
    #expect(!FileManager.default.fileExists(atPath: people.url.path))
}

@Test(.timeLimit(.minutes(1))) func turningRememberVoicesOnLearnsFromNamedMeetingsAndNamesTheRest() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let first = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    let second = try twoVoiceCall(in: meetings, name: "2026-11-17 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    // Recorded while Remember voices was off; the first was named by hand.
    let off = MeetingStore(root: meetings, options: voiceOptions(people, enabled: false))
    for directory in [first, second] {
        try Fixtures.age(directory)
        _ = try await off.process(directory.lastPathComponent)
    }
    try await off.renameSpeaker(first.lastPathComponent, from: "Speaker 2", to: "Jonas Berg")

    let on = MeetingStore(root: meetings, options: voiceOptions(people))
    let named = try await on.learnVoices()
    #expect(named == 1)
    #expect(people.people().map(\.name) == ["Jonas Berg"])
    let detail = try await on.detail(second.lastPathComponent)
    #expect(Set(detail.turns.map(\.speaker)) == ["Speaker 1", "Jonas Berg"])

    // Off again: every voiceprint goes, the names stay.
    try await on.forgetVoices()
    #expect(people.people().isEmpty)
    #expect(MeetingVoices.read(second) == nil)
    #expect(try await on.detail(second.lastPathComponent).turns.contains { $0.speaker == "Jonas Berg" })
}

@Test func aMicTrackUnlikeEveryKnownSampleOfYourVoiceIsNotLearnedAsYou() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    // Three calls teach your voice.
    for meeting in ["m1", "m2", "m3"] {
        try people.learn(meetingID: meeting, title: "Call", startedAt: Date(), inPerson: false,
                         voices: [Voices.voice("You", Voices.print(5, blend: 6, share: 0.1), track: .microphone)], names: [:], me: "Ana")
    }
    // Then a call where the mic carried something else: it isn't you.
    try people.learn(meetingID: "m4", title: "Test call", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("You", Voices.print(9), track: .microphone)], names: [:], me: "Ana")
    #expect(people.people().first?.meetingIDs.sorted() == ["m1", "m2", "m3"])
    // Your voice on a fourth call is learned as usual.
    try people.learn(meetingID: "m5", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("You", Voices.print(5), track: .microphone)], names: [:], me: "Ana")
    #expect(people.people().first?.meetingIDs.count == 4)
}

@Test func aRenameInPeopleSurvivesTheMeetingBeingLearnedAgain() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    let voices = [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(2))]
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices,
                     names: ["Speaker 1": "Mira"], me: nil)
    // Corrected in People: Mira is Mira Patel.
    let mira = try #require(people.people().first)
    try people.rename(mira.id, to: "Mira Patel")
    // Then the meeting names its other voice, so it's learned again with Speaker 1 still called "Mira".
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices,
                     names: ["Speaker 1": "Mira", "Speaker 2": "Jonas"], me: nil)
    #expect(Set(people.people().map(\.name)) == ["Mira Patel", "Jonas"])
    #expect(people.people().first { $0.name == "Mira Patel" }?.id == mira.id)
    // Renamed in the meeting itself, the voice moves to the new name.
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices,
                     names: ["Speaker 1": "Ana", "Speaker 2": "Jonas"], me: nil)
    #expect(Set(people.people().map(\.name)) == ["Ana", "Jonas"])
}

@Test func aSuggestionFollowsThePersonNotTheNameSavedWithIt() {
    let mira = Voices.person("Mira Patel", Voices.print(1))
    let match = MeetingVoices.Match(personID: mira.id, name: "Mira", similarity: 0.7, named: false)
    let voices = MeetingVoices(voices: [Voices.voice("Speaker 1", Voices.print(1))], matches: ["Speaker 1": match])
    #expect(VoiceSuggestions.suggestions(voices, names: [:], people: [mira])["Speaker 1"]?.first?.name == "Mira Patel")
    // Forgotten since: no suggestion that would bring them back.
    #expect(VoiceSuggestions.suggestions(voices, names: [:], people: [])["Speaker 1"] == nil)
}

@Test(.timeLimit(.minutes(1))) func processingAgainReplacesTheOldVoiceprints() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    _ = try await MeetingPostProcessor.run(directory: directory, options: voiceOptions(people))
    let store = MeetingStore(root: meetings, options: voiceOptions(people))
    try await store.renameSpeaker(directory.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    #expect(!people.people().isEmpty)
    // Processed again without Remember voices: the old voiceprints and what they taught are gone.
    _ = try await MeetingPostProcessor.run(directory: directory, options: voiceOptions(people, enabled: false))
    #expect(MeetingVoices.read(directory) == nil)
    #expect(people.people().allSatisfy { !$0.meetingIDs.contains(directory.lastPathComponent) })
}

@Test(.timeLimit(.minutes(1))) func turningRememberVoicesOffWhileEmbeddingKeepsNothing() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    try JSONEncoder().encode(["Speaker 1": "Mira Patel"]).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile))
    let switchedOff = Counter()
    var options = Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 6), DiarizedSpan(speaker: 1, start: 6, end: 12)])
    options.voices = MeetingVoiceOptions(enabled: { switchedOff.value == 0 }, embed: { samples in
        switchedOff.increment()  // The switch goes off while the model works.
        return try await Voices.embed(samples)
    }, people: people)
    _ = try await MeetingPostProcessor.run(directory: directory, options: options)
    #expect(MeetingVoices.read(directory) == nil)
    #expect(people.people().isEmpty)
}

@Test func overlappingVoicesAreLeftOutOfAVoiceprint() {
    // Two voices at once from 2 s to 3 s, inside Speaker 1's turn.
    let spans = [DiarizedSpan(speaker: 0, start: 0, end: 5), DiarizedSpan(speaker: 1, start: 2, end: 3)]
    #expect(VoiceStretches.overlaps(spans) == [2...3])
    let turn = TranscriptTurn(speaker: "Speaker 1", label: "Speaker 1", track: .system, start: 0, end: 5, text: "a long line")
    let pieces = VoiceStretches.pieces(of: "Speaker 1", in: [turn], track: .system, crossTrack: false, overlaps: VoiceStretches.overlaps(spans))
    #expect(pieces == [0...2, 3...5])
}

@Test func aVoiceprintTakesAtMostItsBudgetOfSpeech() {
    let turn = TranscriptTurn(speaker: "Speaker 1", label: "Speaker 1", track: .system, start: 0, end: 120, text: "two minutes")
    let pieces = VoiceStretches.pieces(of: "Speaker 1", in: [turn], track: .system, crossTrack: false)
    #expect(pieces.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } == VoiceStretches.budget)
}

@Test func aRemovedSampleOrForgottenPersonStaysOutWhenTheMeetingIsLearnedAgain() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    let voices = [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(2))]
    let names = ["Speaker 1": "Mira", "Speaker 2": "Jonas"]
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices, names: names, me: nil)
    let mira = try #require(people.people().first { $0.name == "Mira" })
    try people.removeSample(mira.samples[0].id, from: mira.id)
    let jonas = try #require(people.people().first { $0.name == "Jonas" })
    try people.remove(jonas.id)
    // An Undo or a rename elsewhere in the meeting learns it again: neither comes back.
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices, names: names, me: nil)
    #expect(people.people().isEmpty)
    // Processing the meeting again starts it afresh.
    try people.forget(meetingID: "m1")
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices, names: names, me: nil)
    #expect(people.people().count == 2)
}

@Test func speechTakenOutOfALineStaysOutOfItsVoiceprint() {
    // Words at 0–2 s and 6–8 s; what was between was said while muted and removed.
    var words = Fixtures.words("one two three four five six", at: 0)
    words += Fixtures.words("seven eight nine ten eleven twelve", at: 6)
    let turn = TranscriptTurn(speaker: "You", label: "You", track: .microphone, start: 0, end: words.last!.end,
                              text: words.map(\.text).joined(separator: " "), words: words)
    let pieces = VoiceStretches.pieces(of: "You", in: [turn], track: .microphone, crossTrack: true)
    #expect(pieces.count == 2)
    #expect(pieces.allSatisfy { !$0.contains(4) })
}

@Test func aShortenedClipKeepsTheTranscriptsCorrections() {
    // The shown text says "iPhone" where two words were heard.
    var words = Fixtures.words(Array(repeating: "and the eye phone again", count: 14).joined(separator: " "), at: 0)
    words = Array(words)
    let text = Array(repeating: "and the iPhone again", count: 14).joined(separator: " ")
    let turn = TranscriptTurn(speaker: "Speaker 1", label: "Speaker 1", track: .system, start: 0, end: words.last!.end, text: text, words: words)
    let clip = MeetingTimeline.clips(of: "Speaker 1", in: [turn]).first!
    #expect(clip.text.contains("iPhone"))
    #expect(!clip.text.contains("eye phone"))
}

@Test func aVoiceWithTheStandInNameThemGetsSuggestions() {
    let mira = Voices.person("Mira Patel", Voices.print(1))
    let voices = MeetingVoices(voices: [Voices.voice("Them", Voices.print(1))],
                               matches: ["Them": MeetingVoices.Match(personID: mira.id, name: mira.name, similarity: 0.7, named: false)])
    #expect(VoiceSuggestions.suggestions(voices, names: [:], people: [mira])["Them"]?.first?.name == "Mira Patel")
}

@Test(.timeLimit(.minutes(1))) func processingWithoutVoiceOptionsStillClearsWhatTheMeetingTaught() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    _ = try await MeetingPostProcessor.run(directory: directory, options: voiceOptions(people))
    try await MeetingStore(root: meetings, options: voiceOptions(people)).renameSpeaker(directory.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    #expect(!people.people().isEmpty)
    // The CLI processes it again with no voice options at all.
    _ = try await MeetingPostProcessor.run(directory: directory,
                                           options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 12)]))
    #expect(people.people().isEmpty)
}

@Test(.timeLimit(.minutes(1))) func backfillDropsVoiceprintsMadeFromAnAttributionThatChangedMeanwhile() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    try Fixtures.age(directory)
    let off = MeetingStore(root: meetings, options: voiceOptions(people, enabled: false))
    _ = try await off.process(directory.lastPathComponent)
    try await off.renameSpeaker(directory.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    // While the model works, something else processes the meeting again and rewrites its attribution.
    var options = voiceOptions(people)
    let attributed = directory.appendingPathComponent(MeetingStorage.attributedFile)
    options.voices = MeetingVoiceOptions(enabled: { true }, embed: { samples in
        let data = try Data(contentsOf: attributed)
        try FileManager.default.removeItem(at: attributed)
        try data.write(to: attributed)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: attributed.path)
        return try await Voices.embed(samples)
    }, people: people)
    _ = try await MeetingStore(root: meetings, options: options).learnVoices()
    #expect(MeetingVoices.read(directory) == nil)
    #expect(people.people().isEmpty)
}

@Test(.timeLimit(.minutes(1))) func learningVoicesAgainKeepsTheMarksOfNamesGivenFromAVoice() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let first = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    let second = try twoVoiceCall(in: meetings, name: "2026-11-17 100000 Sync", participants: ["Mira Patel", "Jonas Berg"])
    let store = MeetingStore(root: meetings, options: voiceOptions(people))
    for directory in [first, second] { try Fixtures.age(directory); _ = try await store.process(directory.lastPathComponent) }
    try await store.renameSpeaker(first.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    #expect(try await store.learnVoices() == 1)
    #expect(try await store.detail(second.lastPathComponent).namedFromVoice == ["Mira Patel"])
    // A second run names nothing new, and the mark stays.
    #expect(try await store.learnVoices() == 0)
    #expect(try await store.detail(second.lastPathComponent).namedFromVoice == ["Mira Patel"])
}

@Test func aSampleLetGoForSpaceDoesNotComeBackUnderItsOldName() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    // The first meeting named the voice "Mira"; People then calls her Mira Patel.
    try people.learn(meetingID: "m0", title: "First", startedAt: Date(timeIntervalSince1970: 0), inPerson: false,
                     voices: [Voices.voice("Speaker 1", Voices.print(1))], names: ["Speaker 1": "Mira"], me: nil)
    try people.rename(try #require(people.people().first).id, to: "Mira Patel")
    // Enough newer meetings push the first one's sample out.
    for index in 1...PeopleStore.samplesPerPerson {
        try people.learn(meetingID: "m\(index)", title: "Later", startedAt: Date(timeIntervalSince1970: Double(index) * 1_000),
                         inPerson: false, voices: [Voices.voice("Speaker 1", Voices.print(1))], names: ["Speaker 1": "Mira Patel"], me: nil)
    }
    #expect(people.people().first?.meetingIDs.contains("m0") == false)
    // Learning the first meeting again (another voice named there) doesn't bring "Mira" back.
    try people.learn(meetingID: "m0", title: "First", startedAt: Date(timeIntervalSince1970: 0), inPerson: false,
                     voices: [Voices.voice("Speaker 1", Voices.print(1)), Voices.voice("Speaker 2", Voices.print(2))],
                     names: ["Speaker 1": "Mira", "Speaker 2": "Jonas"], me: nil)
    #expect(Set(people.people().map(\.name)) == ["Mira Patel", "Jonas"])
}

@Test func anAutomaticNameGoesToEveryVoiceMergedIntoIt() {
    // Speaker 2 was merged into Speaker 1, which has no name yet.
    var names = ["Speaker 2": "Speaker 1"]
    let before = names
    MeetingPostProcessor.nameVoice(shownAs: "Speaker 1", "Mira Patel", names: &names, before: before,
                                   labels: ["Speaker 1", "Speaker 2", "Speaker 3"])
    #expect(names == ["Speaker 1": "Mira Patel", "Speaker 2": "Mira Patel"])
}

@Test func aShortMuteInsideALineIsLeftOutOfTheVoiceprint() {
    let words = Fixtures.words("one two three four five six seven eight nine ten", at: 0)
    let turn = TranscriptTurn(speaker: "You", label: "You", track: .microphone, start: 0, end: words.last!.end,
                              text: words.map(\.text).joined(separator: " "), words: words)
    // Muted for half a second in the middle: shorter than a pause between runs, but still taken out.
    let pieces = VoiceStretches.pieces(of: "You", in: [turn], track: .microphone, crossTrack: true, overlaps: [1.2...1.7])
    #expect(pieces.allSatisfy { !$0.contains(1.4) })
}

@Test func aPeopleFileThatWontReadIsNeverWrittenOver() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    try FileManager.default.createDirectory(at: people.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let damaged = Data("{ not json".utf8)
    try damaged.write(to: people.url)
    #expect(throws: (any Error).self) {
        try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false,
                         voices: [Voices.voice("Speaker 1", Voices.print(1))], names: ["Speaker 1": "Mira"], me: nil)
    }
    #expect(try Data(contentsOf: people.url) == damaged)
}

@Test(.timeLimit(.minutes(1))) func aDamagedPeopleFileDoesntStopAMeetingBeingProcessed() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    try FileManager.default.createDirectory(at: people.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: people.url)
    let directory = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    let turns = try await MeetingPostProcessor.run(directory: directory, options: voiceOptions(people))
    #expect(!turns.isEmpty)
    #expect(try Data(contentsOf: people.url) == Data("{ not json".utf8))
}

@Test func aCallsMicIsYouWhateverItsLaneIsCalled() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    // The You lane renamed to a nickname: still this Mac's person, not someone new.
    try people.learn(meetingID: "m1", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("You", Voices.print(5), track: .microphone)], names: ["You": "Ana R"], me: "Ana Ruiz")
    #expect(people.people().map(\.isMe) == [true])
    #expect(people.people().first?.name == "Ana Ruiz")
}

@Test func learningAMeetingAgainKeepsItsUnchangedSamples() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    let voices = [Voices.voice("Speaker 1", Voices.print(1))]
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices, names: ["Speaker 1": "Mira"], me: nil)
    let before = try #require(people.people().first?.samples.first?.id)
    try people.learn(meetingID: "m1", title: "Sync", startedAt: Date(), inPerson: false, voices: voices, names: ["Speaker 1": "Mira"], me: nil)
    #expect(people.people().first?.samples.first?.id == before)
}

@Test func nearMissesInsideAddressesAndCodeAreLeftAlone() {
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Mira Patel"])
    #expect(vocabulary.correct("see https://Mirra.dev for it") == "see https://Mirra.dev for it")
    #expect(vocabulary.correct("ask Mirra about it") == "ask Mira about it")
}

@Test func yourVoiceFromACallJoinsThePersonAlreadyNamedAfterYou() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let people = store(root)
    // In the room, a voice was named Ana Ruiz before any call.
    try people.learn(meetingID: "room", title: "Conversation", startedAt: Date(), inPerson: true,
                     voices: [Voices.voice("Speaker 1", Voices.print(5), track: .microphone)], names: ["Speaker 1": "Ana Ruiz"], me: nil)
    let ana = try #require(people.people().first)
    // Then a call says this Mac's person is Ana Ruiz.
    try people.learn(meetingID: "call", title: "Call", startedAt: Date(), inPerson: false,
                     voices: [Voices.voice("You", Voices.print(5), track: .microphone)], names: [:], me: "Ana Ruiz")
    #expect(people.people().count == 1)
    #expect(people.people().first?.id == ana.id)
    #expect(people.people().first?.isMe == true)
}

@Test func aMergedLaneIsNamedOnceThroughWhicheverVoiceMatched() {
    // Speaker 2 merged into unnamed Speaker 1; only Speaker 2 matched someone.
    let names = ["Speaker 2": "Speaker 1"]
    #expect(VoiceMatching.waitsForName("Speaker 2", names: names))
    let mira = MeetingVoices.Match(personID: UUID(), name: "Mira", similarity: 0.9, named: true)
    let weaker = MeetingVoices.Match(personID: UUID(), name: "Jonas", similarity: 0.82, named: true)
    let best = VoiceMatching.bestPerLane(["Speaker 2": mira, "Speaker 1": weaker], names: names)
    #expect(best.count == 1)
    #expect(best["Speaker 2"]?.name == "Mira")
}

@Test func aNameWrittenDownOnPurposeIsNeverTakenForANearMiss() {
    let terms = [DictionaryEntry(spelling: "Jonah Hill", aliases: ["Jona Hill"]), DictionaryEntry(spelling: "iPhone")]
    let vocabulary = MeetingVocabulary(dictionary: terms, names: ["Jonas Berg"])
    #expect(vocabulary.correct("ask Jona Hill tomorrow") == "ask Jonah Hill tomorrow")
    #expect(vocabulary.correct("my Iphne works") == "my iPhone works")
}

@Test(.timeLimit(.minutes(1))) func aMeetingWhoseAttributionWontReadDoesntStopLearning() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let people = PeopleStore(meetingsRoot: meetings)
    let damaged = try twoVoiceCall(in: meetings, name: "2026-11-15 100000 Sync", participants: ["Mira Patel"])
    let healthy = try twoVoiceCall(in: meetings, name: "2026-11-16 100000 Sync", participants: ["Mira Patel"])
    let off = MeetingStore(root: meetings, options: voiceOptions(people, enabled: false))
    for directory in [damaged, healthy] { try Fixtures.age(directory); _ = try await off.process(directory.lastPathComponent) }
    try await off.renameSpeaker(healthy.lastPathComponent, from: "Speaker 1", to: "Mira Patel")
    try Data("[ not json".utf8).write(to: damaged.appendingPathComponent(MeetingStorage.attributedFile))
    _ = try await MeetingStore(root: meetings, options: voiceOptions(people)).learnVoices()
    #expect(people.people().map(\.name) == ["Mira Patel"])
}

@Test func aNameWithAnApostropheIsLeftAsWritten() {
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Sean O'Neill", "Neil Park"])
    #expect(vocabulary.correct("ask O'Neill tomorrow") == "ask O'Neill tomorrow")
}

@Test func aMergedLaneKeepsItsDestinationWhenOnlyTheMergedVoiceHasAVoiceprint() {
    // Speaker 2 merged into Speaker 1; only Speaker 2 had enough speech for a voiceprint.
    var names = ["Speaker 2": "Speaker 1"]
    MeetingPostProcessor.nameVoice(shownAs: "Speaker 2", "Mira Patel", names: &names, before: names, labels: ["Speaker 2"])
    #expect(names == ["Speaker 1": "Mira Patel", "Speaker 2": "Mira Patel"])
}
