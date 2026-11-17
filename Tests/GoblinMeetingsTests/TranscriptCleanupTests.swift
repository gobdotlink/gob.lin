import Foundation
import GoblinEngines
import Testing
@testable import GoblinMeetings

@Test func wordsTakeTheirTimesFromTheTokensThatSpellThem() {
    let result = TranscriptionResult(text: "Meet at 10.", tokens: [
        TranscriptionToken(text: "▁Me", startSeconds: 0.0, endSeconds: 0.1, confidence: 1),
        TranscriptionToken(text: "et", startSeconds: 0.1, endSeconds: 0.2, confidence: 1),
        TranscriptionToken(text: "▁at", startSeconds: 0.3, endSeconds: 0.4, confidence: 1),
        TranscriptionToken(text: "▁1", startSeconds: 0.5, endSeconds: 0.6, confidence: 1),
        TranscriptionToken(text: "0", startSeconds: 0.6, endSeconds: 0.7, confidence: 1),
        TranscriptionToken(text: ".", startSeconds: 0.7, endSeconds: 0.75, confidence: 1),
    ])
    let words = WordAssembly.words(from: result, offset: 100)
    #expect(words.map(\.text) == ["Meet", "at", "10."])
    #expect(zip(words.map(\.start), [100.0, 100.3, 100.5]).allSatisfy { abs($0 - $1) < 1e-9 })
    #expect(zip(words.map(\.end), [100.2, 100.4, 100.75]).allSatisfy { abs($0 - $1) < 1e-9 })
}

@Test func wordsWithoutTokensSitAtTheOffset() {
    let words = WordAssembly.words(from: TranscriptionResult(text: "hello there"), offset: 4)
    #expect(words.map(\.text) == ["hello", "there"])
    #expect(words.allSatisfy { $0.start == 4 && $0.end == 4 })
}

@Test func aLineRunningPastTheCallsEndKeepsOnlyWhatWasSaidBefore() {
    // Words at 4.4, 4.7, 5.0 and 5.3 s; the call ended at 5.
    let crossing = Fixtures.segment(.microphone, "thanks everyone right then", at: 4.4)
    let kept = MeetingPostProcessor.before(5, crossing)
    #expect(kept?.text == "thanks everyone")
    #expect(kept?.words.count == 2)
    #expect((kept?.end ?? 99) <= 5)
    // Before the end it's untouched; after it, or without word times to cut at, it goes.
    let earlier = Fixtures.segment(.microphone, "said to the call", at: 1)
    #expect(MeetingPostProcessor.before(5, earlier) == earlier)
    #expect(MeetingPostProcessor.before(5, Fixtures.segment(.microphone, "heard afterwards", at: 6)) == nil)
    var untimed = crossing
    untimed.words = []
    #expect(MeetingPostProcessor.before(5, untimed) == nil)
}

@Test func echoOfTheCallIsRemovedEntirely() {
    let system = Fixtures.words("can you hear me", at: 10)
    let (kept, removed) = MeetingPostProcessor.removeEcho(Fixtures.segment(.microphone, "Can you hear me?", at: 10.04), systemWords: system)
    #expect(kept == nil)
    #expect(removed == 4)
}

@Test func aMixedLineKeepsWhatThePersonSaid() {
    let system = Fixtures.words("can you hear me", at: 10)
    var line = Fixtures.segment(.microphone, "can you hear me", at: 10.04)
    line.words += Fixtures.words("yes perfectly", at: 12.5)
    line.text += " yes perfectly"
    line.end = line.words.last!.end
    let (kept, removed) = MeetingPostProcessor.removeEcho(line, systemWords: system)
    #expect(removed == 4)
    #expect(kept?.text == "yes perfectly")
    #expect(kept?.start == 12.5)
}

@Test func aMisheardEchoNextToRealEchoGoesToo() {
    // The call said "okay bye"; the mic heard its own speakers as "Okay, Bob."
    let system = Fixtures.words("okay bye", at: 20)
    let (kept, removed) = MeetingPostProcessor.removeEcho(Fixtures.segment(.microphone, "Okay, Bob.", at: 20.05), systemWords: system)
    #expect(kept == nil)
    #expect(removed == 2)
}

@Test func echoSpreadsAtMostTwoWordsIntoDoubleTalk() {
    let system = Fixtures.words("okay so the plan is", at: 30)
    let (kept, removed) = MeetingPostProcessor.removeEcho(Fixtures.segment(.microphone, "okay I really think", at: 30.02),
                                                         systemWords: system)
    #expect(removed == 3)
    #expect(kept?.text == "think")
}

@Test func aCommonWordThatCoincidesWithTheCallIsNotEchoAlone() {
    // The person says "send the notes" while the other side says "go through the plan".
    let system = Fixtures.words("go through the plan", at: 1.4, step: 0.3)
    let line = Fixtures.segment(.microphone, "I will send the notes", at: 1.0, step: 0.3)
    let (kept, removed) = MeetingPostProcessor.removeEcho(line, systemWords: system)
    #expect(removed == 0)
    #expect(kept == line)
    // A lone short line echoing back still goes.
    #expect(MeetingPostProcessor.removeEcho(Fixtures.segment(.microphone, "Bye.", at: 9.03), systemWords: Fixtures.words("bye", at: 9)).0 == nil)
}

@Test func speechWithNothingOnTheCallIsUntouched() {
    let line = Fixtures.segment(.microphone, "let me share my screen", at: 50)
    let (kept, removed) = MeetingPostProcessor.removeEcho(line, systemWords: Fixtures.words("sure go ahead", at: 40))
    #expect(kept == line)
    #expect(removed == 0)
}

@Test func mutedSpansPairChangesAndRunAnOpenMuteToTheEnd() {
    let log = """
    {"t":10,"muted":true}
    not json
    {"t":5,"muted":true}
    {"t":8,"muted":false}
    {"t":9,"muted":false}
    {"t":12,"muted":true}
    """
    #expect(MeetingPostProcessor.mutedSpans(log, end: 20) == [5...8, 10...20])
    #expect(MeetingPostProcessor.mutedSpans("{\"t\":3,\"muted\":true}", end: 2).isEmpty)
    #expect(MeetingPostProcessor.mutedSpans("", end: 20).isEmpty)
}

// MARK: Attribution

@Test func voicesAreNumberedByTheirFirstWords() {
    // Speaker 5 has the first span but says nothing transcribed until after speaker 2.
    let spans = [DiarizedSpan(speaker: 5, start: 0, end: 1), DiarizedSpan(speaker: 2, start: 2, end: 3),
                 DiarizedSpan(speaker: 5, start: 4, end: 5)]
    let turns = MeetingPostProcessor.systemTurns([Fixtures.segment(.system, "first point", at: 2.1),
                                                   Fixtures.segment(.system, "second point", at: 4.1)],
                                                  spans: spans, remote: ["Alex Kim", "Priya Shah"])
    #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    #expect(turns.map(\.label) == ["Speaker 1", "Speaker 2"])
}

@Test func aWordFarFromEverySpanTakesTheNearestSpeaker() {
    let spans = [DiarizedSpan(speaker: 3, start: 0, end: 0.5), DiarizedSpan(speaker: 7, start: 12.5, end: 13)]
    let turns = MeetingPostProcessor.systemTurns([Fixtures.segment(.system, "anyway", at: 10)], spans: spans, remote: [])
    #expect(turns.map(\.speaker) == ["Speaker 1"])
}

@Test func oneVoiceInACallWithOneOtherPersonIsThem() {
    let spans = [DiarizedSpan(speaker: 0, start: 0, end: 5)]
    let turns = MeetingPostProcessor.systemTurns([Fixtures.segment(.system, "hi there", at: 1)], spans: spans, remote: ["Alex Kim"])
    #expect(turns.map(\.speaker) == ["Alex Kim"])
}

@Test func voicesStayNumberedWhenSeveralPeopleCouldBeSpeaking() {
    let spans = [DiarizedSpan(speaker: 0, start: 0, end: 2), DiarizedSpan(speaker: 1, start: 2, end: 4)]
    let turns = MeetingPostProcessor.systemTurns([Fixtures.segment(.system, "one two", at: 0.5), Fixtures.segment(.system, "three four", at: 2.5)],
                                                  spans: spans, remote: ["Alex Kim", "Priya Shah"])
    #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2"])
}

@Test func speechTwoVoicesCoverEquallyStaysWithWhoeverWasTalking() {
    // Voice 2 talks from 0 s; the diarizer also hears voice 0 under it from 3 s to 9 s. Before, every word both covered
    // went to voice 0 on the tie, across the line break too.
    let spans = [DiarizedSpan(speaker: 2, start: 0, end: 12), DiarizedSpan(speaker: 0, start: 3, end: 9),
                 DiarizedSpan(speaker: 0, start: 14, end: 18)]
    let turns = MeetingPostProcessor.systemTurns([Fixtures.segment(.system, "we built the first version and now we use", at: 0, step: 0.6),
                                                   Fixtures.segment(.system, "the models for route planning", at: 6.5),
                                                   Fixtures.segment(.system, "I'm one of the engineers", at: 14.5)],
                                                  spans: spans, remote: ["Alex Kim", "Priya Shah"])
    #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2"])
    // A short pause in the talker's voice where only the other voice is heard doesn't hand them the rest.
    let paused = [DiarizedSpan(speaker: 2, start: 0, end: 4), DiarizedSpan(speaker: 2, start: 4.4, end: 10),
                  DiarizedSpan(speaker: 0, start: 2, end: 10)]
    #expect(Set(MeetingPostProcessor.speakers(for: Fixtures.segment(.system, "one two three four five six seven eight", at: 3, step: 0.5),
                                              spans: paused, previous: 2)) == [2])
    // A reply straight after someone stops is the replier's from its first word.
    let reply = [DiarizedSpan(speaker: 2, start: 0, end: 4), DiarizedSpan(speaker: 0, start: 4.2, end: 8)]
    #expect(MeetingPostProcessor.speakers(for: Fixtures.segment(.system, "sure thing", at: 4.3), spans: reply, previous: 2) == [0, 0])
    // A blip of the talker's voice inside a word the other voice covers isn't a pause in their turn.
    let blip = [DiarizedSpan(speaker: 2, start: 0, end: 4.9), DiarizedSpan(speaker: 2, start: 5.1, end: 5.2),
                DiarizedSpan(speaker: 0, start: 5, end: 6)]
    #expect(MeetingPostProcessor.dominant(blip, 5, 5.6, previous: 2) == 0)
    // A line far from every span takes the nearest voice, not the last line's.
    let far = [DiarizedSpan(speaker: 2, start: 0, end: 2), DiarizedSpan(speaker: 0, start: 30, end: 32)]
    #expect(MeetingPostProcessor.speakers(for: Fixtures.segment(.system, "and so", at: 26), spans: far, previous: 2) == [0, 0])
    // A word mostly in one voice still goes to it, whoever spoke before.
    let clear = [DiarizedSpan(speaker: 2, start: 0, end: 1.1), DiarizedSpan(speaker: 0, start: 1.1, end: 4)]
    #expect(MeetingPostProcessor.speakers(for: Fixtures.segment(.system, "yes so", at: 0.5, step: 0.8), spans: clear) == [2, 0])
}

@Test func noSpeakerIsEverAQuestionMark() {
    let segments = [Fixtures.segment(.system, "hello", at: 1), TranscriptSegment(track: .system, start: 3, end: 4, text: "hm", words: [],
                                                                                    decodeMilliseconds: 1)]
    for remote in [[], ["Alex Kim"], ["Alex Kim", "Priya Shah"]] {
        for spans in [[], [DiarizedSpan(speaker: 4, start: 0, end: 0.2)]] {
            let turns = MeetingPostProcessor.systemTurns(segments, spans: spans, remote: remote)
            #expect(turns.count == 2)
            #expect(turns.allSatisfy { !$0.speaker.contains("?") && !$0.speaker.isEmpty })
        }
    }
    #expect(MeetingPostProcessor.systemTurns(segments, spans: [], remote: ["Alex Kim", "Priya Shah"]).map(\.speaker) == ["Them", "Them"])
    #expect(MeetingPostProcessor.systemTurns(segments, spans: [], remote: ["Alex Kim"]).map(\.speaker) == ["Alex Kim", "Alex Kim"])
}

@Test func aRunningDictationLeavesTheLiveLineFromKeyDownOn() {
    // Key-down at 1.0 s with the mic still open: the live line keeps only what was said before it.
    let segment = Fixtures.segment(.microphone, "so as I said send the notes", at: 0, step: 0.3)
    let (kept, trimmed) = MeetingPostProcessor.removeDictation(segment, spans: [1.0...Double.greatestFiniteMagnitude])
    #expect(trimmed)
    #expect(kept?.text == "so as I")
    let (none, _) = MeetingPostProcessor.removeDictation(segment, spans: [-2...Double.greatestFiniteMagnitude])
    #expect(none == nil)
}
