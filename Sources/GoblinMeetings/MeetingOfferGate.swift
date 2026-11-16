import Foundation

/// Ask, Always or Never, per call app. Apps not set are Ask.
public enum MeetingCallPolicy: String, CaseIterable, Sendable, Identifiable {
    case ask, always, never
    public var id: String { rawValue }
}

/// Decides, each time the detector's picture changes or whatever kept an offer back clears, whether a call on the mic should be offered, recorded at once,
/// or left alone, and says why. It keeps no clock and no UI, so a sequence of calls can be replayed in a test.
public struct MeetingOfferGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Ask "Should I record this call?".
        case offer(MeetingCandidate)
        /// The app is set to Always.
        case record(MeetingCandidate)
        /// Nothing to ask; `skipped` says why for each call app on the mic.
        case none
    }

    public enum SkipReason: Equatable, Sendable, CustomStringConvertible {
        /// The app hasn't held the mic long enough yet (2 s; 20 s for Slack) and shows no call window.
        case tooShort
        /// Already offered or recorded; asked again once the app lets go of the mic.
        case alreadyAsked
        /// Set to Never.
        case never
        /// Something else is under way: a recording, processing, another offer, or a recording starting.
        case busy(String)

        public var description: String {
            switch self {
            case .tooShort: "not on the mic long enough yet"
            case .alreadyAsked: "already asked during this call"
            case .never: "set to Never"
            case .busy(let what): "busy: \(what)"
            }
        }
    }

    public struct Skip: Equatable, Sendable {
        public let bundleID: String
        public let reason: SkipReason
    }

    /// Calls already offered or recorded, by bundle ID, until their app lets go of the mic.
    public private(set) var holds: Set<String> = []

    public init() {}

    /// `busy` names what keeps a new offer back, or nil when one may be made.
    public mutating func update(candidates: [MeetingCandidate], busy: String?,
                                policy: (String) -> MeetingCallPolicy) -> (decision: Decision, skipped: [Skip]) {
        // An app that let go of the mic is asked about again on its next call.
        holds = holds.filter { id in candidates.contains { $0.id == id } }
        var skipped: [Skip] = []
        for candidate in candidates {
            let reason: SkipReason?
            if let busy { reason = .busy(busy) }
            else if !candidate.isLikelyMeeting { reason = .tooShort }
            else if holds.contains(candidate.id) { reason = .alreadyAsked }
            else if policy(candidate.id) == .never { reason = .never }
            else { reason = nil }
            if let reason {
                skipped.append(Skip(bundleID: candidate.id, reason: reason))
                continue
            }
            holds.insert(candidate.id)
            return (policy(candidate.id) == .always ? .record(candidate) : .offer(candidate), skipped)
        }
        return (.none, skipped)
    }

    /// A recording of this call started: it now counts as asked, so stopping by hand doesn't bring the question
    /// straight back. Other calls on the mic are still asked about once the recording ends.
    public mutating func hold(_ candidate: MeetingCandidate?) {
        if let candidate { holds.insert(candidate.id) }
    }

    /// Whether the decision must be made again because what kept an offer back has gone: a recording or its processing
    /// ended, an offer was answered, or a recording finished starting. The detector reports only changes in who holds
    /// the mic, so a call that was skipped as busy would otherwise wait for its app to change something.
    public static func blockerCleared(from previous: String?, to current: String?) -> Bool {
        previous != nil && current == nil
    }
}
