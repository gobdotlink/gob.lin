import Foundation
import GoblinCore
import Testing
@testable import GoblinMeetings

/// The rules that make a finished transcript read well: flicker smoothing, paragraphs, words said across an unmute,
/// and names and terms spelled the way the person spells them.

private func turn(_ label: String, _ text: String, at start: Double, track: MeetingTrack = .system) -> TranscriptTurn {
    let words = Fixtures.words(text, at: start)
    return TranscriptTurn(speaker: label, label: label, track: track, start: words.first?.start ?? start,
                          end: words.last?.end ?? start, text: text, words: words)
}

@Test func aBrokenOffPieceGoesBackToTheVoiceWhoseSentenceItIs() {
    // "…with your | roadmap. But | it'd be great…": the diarizer flickered to another voice for two words.
    let turns = [turn("Speaker 1", "put a plan in place with your", at: 0),
                 turn("Speaker 2", "roadmap. But", at: 2.3),
                 turn("Speaker 1", "it'd be great to get introductions", at: 3.2)]
    let smoothed = MeetingPostProcessor.smoothFlicker(turns)
    #expect(smoothed.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 1"])
}

@Test func aReplySaidOverSomeoneStaysWithWhoeverSaidIt() {
    let turns = [turn("Speaker 1", "and then we ship it to", at: 0),
                 turn("Speaker 2", "Mm-hmm.", at: 2),
                 turn("Speaker 1", "everyone on the list", at: 2.6)]
    #expect(MeetingPostProcessor.smoothFlicker(turns).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
}

@Test func aShortTurnAfterAFinishedSentenceIsSomeoneElseTalking() {
    let turns = [turn("Speaker 1", "That's the plan.", at: 0),
                 turn("Speaker 2", "Year of founding?", at: 1.2),
                 turn("Speaker 1", "Twenty twenty one.", at: 2.4)]
    #expect(MeetingPostProcessor.smoothFlicker(turns).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
}

@Test func flickerIsJudgedOnEachTrackAlone() {
    // Your mic line between them doesn't hide that the remote voice never stopped.
    let turns = [turn("Speaker 1", "we could move the launch to", at: 0),
                 turn("You", "right", at: 1.6, track: .microphone),
                 turn("Speaker 2", "next", at: 2.2),
                 turn("Speaker 1", "week if design is ready", at: 2.6)]
    let smoothed = MeetingPostProcessor.smoothFlicker(turns)
    #expect(smoothed.filter { $0.track == .system }.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 1"])
    #expect(smoothed[1].speaker == "You")
}

@Test func onePersonsLinesBecomeAParagraphUntilSomeoneElseTalks() {
    let turns = [turn("Sam", "First thought.", at: 0), turn("Sam", "Second thought.", at: 3.5),
                 turn("Ana", "Agreed.", at: 6), turn("Sam", "Third.", at: 7.5)]
    let merged = MeetingPostProcessor.merge(turns, by: \.speaker, joining: .paragraphs)
    #expect(merged.map(\.speaker) == ["Sam", "Ana", "Sam"])
    #expect(merged[0].text == "First thought. Second thought.")
    // Talk time leaves out the pause between the lines.
    #expect(abs(merged[0].talkSeconds - (turns[0].talkSeconds + turns[1].talkSeconds)) < 1e-9)
    #expect(merged[0].talkSeconds < merged[0].end - merged[0].start)
}

@Test func aLongPauseOrALongMonologueStartsANewParagraph() {
    let paused = MeetingPostProcessor.merge([turn("Sam", "One.", at: 0), turn("Sam", "Two.", at: 8)], by: \.speaker, joining: .paragraphs)
    #expect(paused.count == 2)
    let lines = (0..<40).map { turn("Sam", "and another point here", at: Double($0) * 3) }
    let monologue = MeetingPostProcessor.merge(lines, by: \.speaker, joining: .paragraphs)
    #expect(monologue.count > 1)
    #expect(monologue.allSatisfy { $0.end - $0.start <= MeetingPostProcessor.Joining.paragraphs.longest })
}

@Test func wordsSaidAfterUnmutingStayWhenTheLineStartedWhileMuted() {
    // Muted until 2 s; the line runs from 1 s to 2.5 s.
    let line = Fixtures.segment(.microphone, "sorry I was muted there", at: 1)
    let (kept, removed) = MeetingPostProcessor.removeMuted(line, spans: [0...2])
    #expect(removed)
    // By each word's middle: "muted" starts at 1.9 s but is mostly said after the unmute.
    #expect(kept?.text == "muted there")
    // Entirely muted: nothing left. Never muted: untouched.
    #expect(MeetingPostProcessor.removeMuted(line, spans: [0...10]).0 == nil)
    #expect(MeetingPostProcessor.removeMuted(line, spans: [20...30]) == (line, false))
}

@Test func namesOnTheCallFixNearMissesInTheMiddleOfASentence() {
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Mira Patel", "Jonas Berg", "Will Carter"])
    #expect(vocabulary.correct("I think Mirra can't hear you, Jonah.") == "I think Mira can't hear you, Jonas.")
    // Lower case, sentence starts and ordinary words are left alone.
    #expect(vocabulary.correct("Mirra said the games went well. Well, Jonas agreed.") == "Mirra said the games went well. Well, Jonas agreed.")
    #expect(vocabulary.correct("Oh, Well that works") == "Oh, Well that works")
}

@Test func theDictionarySpellsTermsInMeetings() {
    let terms = [DictionaryEntry(spelling: "Zephyr", aliases: ["Zefir"]), DictionaryEntry(spelling: "kestrel", aliases: ["kestral"])]
    let vocabulary = MeetingVocabulary(dictionary: terms, names: [])
    #expect(vocabulary.correct("so my Zefir reads it") == "so my Zephyr reads it")
    #expect(vocabulary.correct("my Zepyr's thing and the Zephir") == "my Zephyr's thing and the Zephyr")
    #expect(vocabulary.correct("the Kestral queue view") == "the Kestrel queue view")
}

@Test func aCorrectedTurnKeepsItsWordTimings() {
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Mira"])
    let corrected = vocabulary.correct(turn("You", "thanks Mirra for that", at: 4))
    #expect(corrected.text == "thanks Mira for that")
    #expect(corrected.words.map(\.text) == ["thanks", "Mira", "for", "that"])
    #expect(corrected.words.first?.start == 4)
}

@Test func theShownTranscriptUsesTheCallsNamesButTheRecordKeepsWhatWasHeard() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try Fixtures.meeting(in: root, name: "2026-11-17 100000 Standup", seconds: 12,
                                         segments: [Fixtures.segment(.system, "can Mirra hear me now", at: 1)])
    try JSONEncoder().encode(MeetingParticipants(all: ["Mira Patel", "Ana Ruiz"], me: "Ana Ruiz"))
        .write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
    let turns = try await MeetingPostProcessor.run(directory: directory,
                                                   options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 12)]))
    #expect(turns.map(\.text) == ["can Mira hear me now"])
    let attributed = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                                    from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.attributedFile)))
    #expect(attributed.map(\.text) == ["can Mirra hear me now"])
}

@Test func aWhoIsThisClipOfALongParagraphPlaysOnlyItsStart() {
    // A minute of one voice joined into a paragraph: the clip stops at the last word within 15 s.
    let paragraph = turn("Speaker 1", Array(repeating: "and then we", count: 70).joined(separator: " "), at: 10)
    #expect(paragraph.end - paragraph.start > 60)
    let clip = MeetingTimeline.clips(of: "Speaker 1", in: [paragraph]).first!
    #expect(clip.start == paragraph.start)
    #expect(clip.end - clip.start <= MeetingTimeline.longestClip)
    #expect(clip.text.hasSuffix("…"))
    // A short line is untouched.
    let line = turn("Speaker 2", "a short line of speech", at: 2)
    #expect(MeetingTimeline.clips(of: "Speaker 2", in: [line]).first == line)
}

@Test func aliasesKeptToOneProjectNeverRewriteAMeeting() {
    // "sole" means Sol only in that project; a meeting has no project, so the word stays. The spelling still fixes a
    // capitalised near miss of the term itself.
    let scoped = DictionaryEntry(spelling: "Solace", aliases: ["sole ace"], projects: ["kestrel-app"])
    let vocabulary = MeetingVocabulary(dictionary: [scoped], names: [])
    #expect(vocabulary.correct("the sole ace of the deck") == "the sole ace of the deck")
    #expect(vocabulary.correct("we shipped Solase today") == "we shipped Solace today")
}

@Test func aNotesSpellingDecisionIsLeftForTheNotesToApply() {
    // Notes offered Mirra → Mira and the person put "Mirra" back: vocabulary correction leaves that word alone.
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Mira Patel"], protecting: ["Mirra"])
    #expect(vocabulary.correct("can Mirra hear me") == "can Mirra hear me")
    // Text around it is still corrected.
    let other = MeetingVocabulary(dictionary: [], names: ["Mira Patel", "Jonas Berg"], protecting: ["Mirra"])
    #expect(other.correct("can Mirra and Jonah hear me") == "can Mirra and Jonas hear me")
}

@Test func aShortWholeReplyStaysWithWhoeverSaidIt() {
    let turns = [turn("Speaker 1", "so the plan is to ship it on", at: 0),
                 turn("Speaker 2", "Thank you.", at: 2.2),
                 turn("Speaker 1", "Thursday with the rest", at: 2.9)]
    #expect(MeetingPostProcessor.smoothFlicker(turns).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
}

@Test func aProtectedPhraseInsideCodeKeepsTheWholeSpanAsWritten() {
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Jonas Berg"], protecting: ["Mirra"])
    #expect(vocabulary.correct("run `Mirra and Jonah tomorrow` now") == "run `Mirra and Jonah tomorrow` now")
}

@Test func aNotesPhraseIsProtectedWhereverTheNotesWouldFindIt() {
    // The notes match "Mirra  Patel" across any run of spaces; protection must find it the same way.
    let vocabulary = MeetingVocabulary(dictionary: [], names: ["Mira Patel"], protecting: ["Mirra  Patel"])
    #expect(vocabulary.correct("ask Mirra Patel now") == "ask Mirra Patel now")
}

@Test func aProtectedPhraseSplitAcrossTwoLinesIsStillLeftAsHeard() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // One voice: "ask Mirra", a two-second pause, "Patel tomorrow". Notes put "Mirra Patel" back.
    let directory = try Fixtures.meeting(in: root, name: "2026-11-17 100000 Standup", seconds: 12,
                                         segments: [Fixtures.segment(.system, "ask Mirra", at: 1),
                                                    Fixtures.segment(.system, "Patel tomorrow", at: 3.6)])
    try JSONEncoder().encode(MeetingParticipants(all: ["Mira Patel", "Jonas Berg", "Ana Ruiz"], me: "Ana Ruiz"))
        .write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
    _ = try await MeetingPostProcessor.run(directory: directory,
                                           options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0, end: 12)]))
    let notes = MeetingNotes(title: nil, summary: "", decisions: [], actionItems: [], sections: [], marks: [],
                             fixes: [MeetingNotes.SpellingFix(heard: "Mirra Patel", meant: "Mira Patel", count: 1, kind: .applied, dismissed: true)],
                             speakers: [:],
                             written: MeetingNotes.Provenance(tool: .codex, model: "test", effort: nil, template: .auto, style: .concise,
                                                              createdAt: Date(), seconds: 1, transcriptHash: MeetingNotesFile.sourceHash(directory),
                                                              promptVersion: MeetingNotesPrompt.version))
    try MeetingNotesFile.write(notes, to: directory)
    let turns = try MeetingPostProcessor.render(directory: directory)
    #expect(turns.map(\.text).joined(separator: " ").contains("Mirra Patel"))
}

@Test func aQuestionBetweenAnotherVoicesLinesStaysWithWhoeverAsked() {
    let turns = [turn("Speaker 1", "we can ship it on", at: 0),
                 turn("Speaker 2", "Which day?", at: 1.6),
                 turn("Speaker 1", "Thursday.", at: 2.4)]
    #expect(MeetingPostProcessor.smoothFlicker(turns).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
}

@Test func aCompleteReplyBetweenAnotherVoicesLinesStaysWithWhoeverSaidIt() {
    let turns = [turn("Speaker 1", "we need it by", at: 0),
                 turn("Speaker 2", "Friday.", at: 1.4),
                 turn("Speaker 1", "That works.", at: 1.9)]
    #expect(MeetingPostProcessor.smoothFlicker(turns).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
}
