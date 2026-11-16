import Foundation

/// When the call app showed this person as muted, in seconds since the session started. The live captions and the
/// final transcript use the same rule: a mic line is left out when its midpoint falls inside a muted span.
public struct MuteTimeline: Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public let t: Double
        public let muted: Bool

        public init(t: Double, muted: Bool) {
            self.t = t
            self.muted = muted
        }
    }

    public private(set) var changes: [Change] = []

    public init(changes: [Change] = []) {
        self.changes = changes.sorted { $0.t < $1.t }
    }

    /// Reads mute.jsonl: one `{"t": seconds, "muted": Bool}` change per line.
    public init(jsonl text: String) {
        self.init(changes: text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Change.self, from: Data($0.utf8)) })
    }

    /// Adds a change; repeating the current state changes nothing.
    public mutating func record(_ muted: Bool, at t: Double) {
        guard changes.last?.muted != muted else { return }
        changes.append(Change(t: t, muted: muted))
        changes.sort { $0.t < $1.t }
    }

    /// The muted stretches; a mute still on lasts to `end`.
    public func spans(end: Double) -> [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = []
        var mutedSince: Double?
        for change in changes {
            if change.muted, mutedSince == nil { mutedSince = change.t }
            if !change.muted, let since = mutedSince { if since < change.t { spans.append(since...change.t) }; mutedSince = nil }
        }
        if let since = mutedSince, since < end { spans.append(since...end) }
        return spans
    }

    /// Whether the call was muted at `t`. A mute that hasn't ended yet runs on indefinitely.
    public func isMuted(at t: Double) -> Bool {
        spans(end: .greatestFiniteMagnitude).contains { $0.contains(t) }
    }

    /// A line the mic heard while the call was muted: it was never said to the meeting.
    public func silences(_ segment: TranscriptSegment) -> Bool {
        segment.track == .microphone && isMuted(at: (segment.start + segment.end) / 2)
    }
}
