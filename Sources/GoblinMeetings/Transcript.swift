import Foundation
import GoblinEngines

public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
}

/// One transcribed chunk of one track, on the meeting's timeline.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var track: MeetingTrack
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TranscriptWord]
    public var decodeMilliseconds: Double
    /// Seconds into the meeting when the line was ready, for measuring live delay.
    public var emittedAt: Double?
}

/// A speaker-attributed turn in the final transcript.
public struct TranscriptTurn: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID = UUID()
    /// The name shown: speakers.json's name for `label`, or the label itself.
    public var speaker: String
    /// What the post-processor called this voice ("You", "Speaker 2", or a 1:1 participant's name).
    /// Nil on a rendered turn that joined two labels a person merged into one name.
    public var label: String? = nil
    public var track: MeetingTrack
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TranscriptWord]
    /// Seconds of talking in the turn, when it joins lines with pauses between them; nil means `end - start`.
    public var spoken: Double? = nil

    public init(id: UUID = UUID(), speaker: String, label: String? = nil, track: MeetingTrack, start: Double, end: Double,
                text: String, words: [TranscriptWord] = [], spoken: Double? = nil) {
        self.id = id
        self.speaker = speaker
        self.label = label
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.spoken = spoken
    }

    /// How long this voice talked in the turn, without the pauses between the lines it joins.
    public var talkSeconds: Double { spoken ?? max(0, end - start) }
}

enum WordAssembly {
    /// Lays the recognised text's words over Parakeet's word-piece timings by consuming pieces
    /// until each word's characters are covered, so word boundaries come from the text.
    static func words(from result: TranscriptionResult, offset: Double) -> [TranscriptWord] {
        let pieces = result.tokens.map { token in
            (chars: token.text.replacingOccurrences(of: "▁", with: "").filter { !$0.isWhitespace }.count,
             start: token.startSeconds, end: token.endSeconds)
        }
        var words: [TranscriptWord] = []
        var index = 0
        for word in result.text.split(whereSeparator: \.isWhitespace) {
            var needed = word.count
            var start: Double?
            var end = words.last.map { $0.end - offset } ?? 0
            while needed > 0, index < pieces.count {
                if pieces[index].chars > 0 {
                    start = start ?? pieces[index].start
                    end = pieces[index].end
                    needed -= pieces[index].chars
                }
                index += 1
            }
            words.append(TranscriptWord(text: String(word), start: offset + (start ?? end), end: offset + end))
        }
        return words
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
}

extension Array {
    /// Inserts after every element that starts at or before it, so lines from two tracks that finish decoding out of
    /// order still read in time order. Usually an append: it looks from the end.
    public mutating func insert(_ element: Element, byStart start: (Element) -> Double) {
        let at = start(element)
        var index = endIndex
        while index > startIndex, start(self[index - 1]) > at { index -= 1 }
        insert(element, at: index)
    }
}
