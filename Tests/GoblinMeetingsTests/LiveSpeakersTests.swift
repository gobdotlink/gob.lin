import Foundation
import Testing
@testable import GoblinMeetings

/// Frames of two voices: slot 0 for `zero`, slot 1 for `one`, as 10 ms frame ranges.
private func probabilities(frames: Int, zero: Range<Int>, one: Range<Int> = 0..<0) -> [Float] {
    (0..<frames).flatMap { frame -> [Float] in
        [zero.contains(frame) ? 0.9 : 0.1, one.contains(frame) ? 0.9 : 0.1]
    }
}

private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

@Test func liveSpansDropBlipsKeepArrivalOrderAndHoldBackAVoiceThatHasOnlyJustStarted() {
    var builder = LiveSpanBuilder(origin: 10)
    // A 0.1 s blip of slot 0 is noise: no span, and it doesn't count as arriving.
    builder.add(probabilities(frames: 20, zero: 5..<15), frameCount: 20, speakers: 2)
    #expect(builder.spans.isEmpty && builder.arrival.isEmpty)
    // Slot 1 talks for 1 s, then slot 0.
    builder.add(probabilities(frames: 280, zero: 130..<260, one: 0..<100), frameCount: 280, speakers: 2)
    #expect(builder.spans.map(\.speaker) == [1, 0])
    #expect(near(builder.spans.first?.start, 10.2) && near(builder.spans.first?.end, 11.2))
    #expect(builder.arrival == [1, 0])
    #expect(near(builder.decidedUntil, 13))

    // Slot 0 starts 0.1 s before the end of the chunk: it may yet be a span, so nothing after its start is decided.
    builder.add(probabilities(frames: 100, zero: 90..<100), frameCount: 100, speakers: 2)
    #expect(near(builder.decidedUntil, 13.9) && near(builder.processedUntil, 14))
    // Once it has lasted 0.2 s it shows as a span up to where the model has got to, and all of it is decided.
    builder.add(probabilities(frames: 20, zero: 0..<20), frameCount: 20, speakers: 2)
    #expect(builder.spans.last?.speaker == 0 && near(builder.spans.last?.start, 13.9) && near(builder.spans.last?.end, 14.2))
    #expect(near(builder.decidedUntil, 14.2))
}

@Test func aLineWaitsUntilPlacedThenTakesTheVoiceOfMostOfItsWords() {
    let spans = [DiarizedSpan(speaker: 1, start: 0, end: 2.1), DiarizedSpan(speaker: 0, start: 2.1, end: 5)]
    // Seven words from 0 s to 2.1 s, then four from 2.1 s: slot 1 said most of it.
    let line = Fixtures.segment(.system, "so the export is still on for us then yes it", at: 0, step: 0.3)
    let snapshot = LiveSpeakers.Snapshot(placedFrom: 0, placedUntil: 2.5, spans: spans, names: [:])
    #expect(LiveSpeakers.placement(of: line, in: snapshot) == .waiting)
    #expect(LiveSpeakers.placement(of: line, in: .init(placedFrom: 0, placedUntil: 5, spans: spans, names: [:])) == .voice(1))
    // Said before the audio the model got: it stays Them.
    #expect(LiveSpeakers.placement(of: line, in: .init(placedFrom: 1, placedUntil: 5, spans: spans, names: [:])) == .never)
}
