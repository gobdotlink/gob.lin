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

@Test func liveSpansMatchTheAfterCallRulesAndArrivalOrder() {
    var builder = LiveSpanBuilder(origin: 10)
    // A 0.1 s blip of slot 0 is noise: no span, and it doesn't count as arriving.
    #expect(builder.add(probabilities(frames: 20, zero: 5..<15), frameCount: 20, speakers: 2).isEmpty)
    #expect(builder.arrival.isEmpty)
    // Slot 1 talks for 1 s, then slot 0.
    let closed = builder.add(probabilities(frames: 280, zero: 130..<260, one: 0..<100), frameCount: 280, speakers: 2)
    #expect(closed.map(\.speaker) == [1, 0])
    #expect(near(closed.first?.start, 10.2) && near(closed.first?.end, 11.2))
    #expect(builder.arrival == [1, 0])
    #expect(near(builder.placedUntil, 13))

    // A voice still talking at the end of a chunk shows as a span up to where the model has got to.
    _ = builder.add(probabilities(frames: 100, zero: 50..<100), frameCount: 100, speakers: 2)
    let open = builder.spans.last
    #expect(open?.speaker == 0 && near(open?.start, 13.5) && near(open?.end, 14))
}

@Test func aLineTakesTheVoiceOfMostOfItsWordsOnceItIsPlaced() {
    let spans = [DiarizedSpan(speaker: 1, start: 0, end: 2.1), DiarizedSpan(speaker: 0, start: 2.1, end: 5)]
    // Seven words from 0 s to 2.1 s, then three from 2.1 s: slot 1 said most of it.
    let line = Fixtures.segment(.system, "so the export is still on for us then yes it", at: 0, step: 0.3)
    #expect(LiveSpeakers.voice(for: line, in: .init(placedUntil: 2.5, spans: spans, names: [:])) == nil)
    #expect(LiveSpeakers.voice(for: line, in: .init(placedUntil: 5, spans: spans, names: [:])) == 1)
}
