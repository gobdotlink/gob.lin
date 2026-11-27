import Foundation

/// Reading marks for review (MeetingMark itself and writing live in MeetingMarks.swift).
extension MeetingMark {
    /// marks.jsonl in a meeting folder, oldest first. Lines that don't parse are skipped, and a blank label is no label.
    public static func read(_ directory: URL) -> [MeetingMark] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(MeetingStorage.marksFile), encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [MeetingMark] {
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(MeetingMark.self, from: Data($0.utf8)) }
            .filter { $0.t.isFinite && $0.t >= 0 }
            .map { mark in
                var mark = mark
                if mark.label?.trimmingCharacters(in: .whitespaces).isEmpty == true { mark.label = nil }
                return mark
            }
            .sorted { $0.t < $1.t }
    }
}

/// One voice across the whole meeting: the stretches it talked, for the review timeline.
public struct MeetingLane: Sendable, Hashable, Identifiable {
    /// Back-to-back turns by the same voice, drawn as one block and played as one clip.
    public struct Stretch: Sendable, Hashable, Identifiable {
        public var id: UUID { turnIDs[0] }
        public var start: Double
        public var end: Double
        public var track: MeetingTrack
        public var turnIDs: [UUID]
    }

    public var id: String { name }
    /// The displayed name, which is also what `MeetingStore.renameSpeaker` takes.
    public var name: String
    /// This Mac's person: the microphone's own voice on a call, or a voice someone named "You".
    public var isYou: Bool
    /// A voice nobody has named yet ("Speaker 3").
    public var needsName: Bool
    public var stretches: [Stretch]
    public var talkSeconds: Double

    /// Heard on this Mac's microphone and never through the call: on a call, someone beside you.
    public var isOnMicrophoneOnly: Bool { !stretches.isEmpty && stretches.allSatisfy { $0.track == .microphone } }
}

public enum MeetingTimeline {
    /// Turns closer than this join into one stretch.
    public static let joinGap = 1.5

    /// "Speaker 3": what the post-processor calls a voice it couldn't name.
    public static func isUnnamed(_ name: String) -> Bool {
        name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// One lane per displayed speaker: you first, then named voices by talk time, then unnamed ones in the order the
    /// post-processor numbered them. On a call you're the microphone's own voice, whatever it's been named; others
    /// heard on a shared microphone, and every voice in the room, are you only by the name "You".
    public static func lanes(_ turns: [TranscriptTurn], kind: MeetingKind = .call) -> [MeetingLane] {
        var lanes: [String: MeetingLane] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where turn.end >= turn.start {
            var lane = lanes[turn.speaker] ?? MeetingLane(name: turn.speaker, isYou: false, needsName: isUnnamed(turn.speaker),
                                                           stretches: [], talkSeconds: 0)
            lane.isYou = lane.isYou || turn.speaker == MeetingPostProcessor.microphoneLabel
                || (kind == .call && turn.track == .microphone && turn.label == MeetingPostProcessor.microphoneLabel)
            lane.talkSeconds += turn.talkSeconds
            if var last = lane.stretches.last, last.track == turn.track, turn.start - last.end <= joinGap {
                last.end = max(last.end, turn.end)
                last.turnIDs.append(turn.id)
                lane.stretches[lane.stretches.count - 1] = last
            } else {
                lane.stretches.append(.init(start: turn.start, end: turn.end, track: turn.track, turnIDs: [turn.id]))
            }
            lanes[turn.speaker] = lane
        }
        return lanes.values.sorted { a, b in
            if a.isYou != b.isYou { return a.isYou }
            if a.needsName != b.needsName { return !a.needsName }
            if a.needsName { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return (a.talkSeconds, b.name) > (b.talkSeconds, a.name)
        }
    }

    /// A voice starting this soon after another voice stopped mid-sentence may be the diarizer splitting one
    /// person's speech, not a new person talking.
    public static let pickupGap = 0.5

    /// Up to `count` of a voice's turns to listen to: its longest lines of three words or more, in meeting order.
    /// Lines from a run of this voice that took over mid-sentence from another voice come last: when a quiet voice had
    /// two of those as its longest lines, both were someone else, and the voice was named after them.
    public static func clips(of speaker: String, in turns: [TranscriptTurn], count: Int = 3) -> [TranscriptTurn] {
        let ordered = turns.sorted { $0.start < $1.start }
        var pickups = Set<UUID>()
        var runIsPickup: [MeetingTrack: Bool] = [:]
        var lastOfTheirs: [MeetingTrack: Int] = [:]
        for (index, turn) in ordered.enumerated() where turn.speaker == speaker {
            // A turn soon after this voice's last one, with nobody else between, continues its run and keeps its verdict.
            let continues = lastOfTheirs[turn.track].map { last in
                turn.start - ordered[last].end <= joinGap
                    && !ordered[(last + 1)..<index].contains { $0.track == turn.track && $0.speaker != speaker }
            } ?? false
            if !continues {
                let before = ordered[..<index].last { $0.track == turn.track && $0.speaker != speaker }
                runIsPickup[turn.track] = before.map { turn.start - $0.end <= pickupGap && !endsASentence($0.text) } ?? false
            }
            if runIsPickup[turn.track] == true { pickups.insert(turn.id) }
            lastOfTheirs[turn.track] = index
        }
        let theirs = ordered.filter { $0.speaker == speaker }
        let wordy = theirs.filter { $0.text.split(separator: " ").count >= 3 }
        let pool = wordy.isEmpty ? theirs : wordy
        let ranked = pool.sorted { a, b in
            let (aPickup, bPickup) = (pickups.contains(a.id), pickups.contains(b.id))
            if aPickup != bPickup { return !aPickup }
            return (a.end - a.start, b.start) > (b.end - b.start, a.start)
        }
        return Array(ranked.prefix(count)).sorted { $0.start < $1.start }.map { shortened($0) }
    }

    /// A clip plays at most this long: a turn in the shown transcript can be a minute-long paragraph.
    public static let longestClip = 15.0

    /// The start of a long turn, cut at the last word that ends within `longestClip`. A turn without word timings, or a
    /// short one, is left as it is.
    static func shortened(_ turn: TranscriptTurn) -> TranscriptTurn {
        guard turn.end - turn.start > longestClip, !turn.words.isEmpty else { return turn }
        let kept = turn.words.filter { $0.end <= turn.start + longestClip }
        guard let last = kept.last, kept.count < turn.words.count else { return turn }
        var clip = turn
        clip.words = kept
        clip.end = last.end
        // The shown text keeps the transcript's corrections ("Eye phone" → "iPhone"), so it's cut by share of words
        // rather than rebuilt from what was heard.
        let shown = turn.text.split(whereSeparator: \.isWhitespace)
        let share = shown.count == turn.words.count ? kept.count
            : max(1, Int((Double(shown.count) * Double(kept.count) / Double(turn.words.count)).rounded()))
        clip.text = shown.prefix(share).joined(separator: " ") + "…"
        clip.spoken = nil
        return clip
    }

    static func endsASentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".?!…".contains(last)
    }

    /// Axis labels every 5 or 10 minutes (every minute under 10 minutes), starting at zero.
    public static func ticks(duration: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let step: Double = duration > 1_800 ? 600 : duration > 600 ? 300 : 60
        return stride(from: 0, to: duration, by: step).map { $0 }
    }

    /// Axis labels thinned to clean clock intervals so consecutive labels stay at least `minimumSpacing` points
    /// apart across `width`. Stretches, marks, and the playhead remain positioned on the true duration scale.
    public static func ticks(duration: Double, width: Double, minimumSpacing: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let base: Double = duration > 1_800 ? 600 : duration > 600 ? 300 : 60
        guard width > 0, minimumSpacing > 0 else { return ticks(duration: duration) }
        let needed = max(base, duration * minimumSpacing / width)
        let candidates: [Double] = [60, 120, 300, 600, 900, 1_200, 1_800, 3_600, 7_200, 10_800, 14_400, 21_600, 28_800, 43_200]
        let step: Double
        if let match = candidates.first(where: { $0 >= needed }) {
            step = match
        } else {
            var doubled = candidates.last!
            while doubled < needed { doubled *= 2 }
            step = doubled
        }
        return stride(from: 0, to: duration, by: step).map { $0 }
    }

    /// "4:02" under an hour, "1:04:02" over it.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "42 min", or "40 s" for under a minute.
    public static func length(_ seconds: Double) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds.rounded()))) s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// A name "Who's this?" offers for an unnamed voice, with why.
public struct SpeakerSuggestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var reason: String
}

public enum SpeakerSuggestions {
    /// People the call's participant list says were there whose names no voice has yet. Never this Mac's own person.
    public static func suggestions(lanes: [MeetingLane], participants: MeetingParticipants, limit: Int = 3) -> [SpeakerSuggestion] {
        var taken = Set(lanes.map { $0.name.lowercased() })
        if let me = participants.me { taken.insert(me.lowercased()) }
        var result: [SpeakerSuggestion] = []
        for name in participants.others where !taken.contains(name.lowercased()) {
            taken.insert(name.lowercased())
            result.append(SpeakerSuggestion(name: name, reason: "In the call's participant list, and no voice has their name yet."))
        }
        return Array(result.prefix(limit))
    }

    /// People the call's participant list says were there whom no voice is named after yet, in the list's order.
    /// Never this Mac's own person.
    public static func unmatched(lanes: [MeetingLane], participants: MeetingParticipants) -> [String] {
        let heard = Set(lanes.map { $0.name.lowercased() })
        return participants.others.filter { !heard.contains($0.lowercased()) }
    }

    /// The sentence asking before two voices become one while someone on the call has no voice yet, or nil when
    /// nobody is missing: "I heard these as two different voices, and Sam Okafor doesn't have a voice yet."
    public static func mergeWarning(unmatched: [String]) -> String? {
        guard !unmatched.isEmpty else { return nil }
        let names = unmatched.count == 1 ? unmatched[0]
            : unmatched.dropLast().joined(separator: ", ") + " and " + unmatched[unmatched.count - 1]
        return "I heard these as two different voices, and \(names) \(unmatched.count == 1 ? "doesn't" : "don't") have a voice yet."
    }

    /// More voices came through the call than it listed people: someone shared a laptop. Returns how many extra.
    /// People heard beside you on this Mac's microphone didn't come through the call, whether or not it listed them.
    public static func extraVoices(lanes: [MeetingLane], participants: MeetingParticipants) -> Int {
        guard !participants.others.isEmpty else { return 0 }
        let beside = Set(lanes.filter { !$0.isYou && $0.isOnMicrophoneOnly }.map { $0.name.lowercased() })
        let others = participants.others.filter { !beside.contains($0.lowercased()) }.count
        return max(0, lanes.filter { !$0.isYou && !$0.isOnMicrophoneOnly }.count - others)
    }

    /// The name given to a second voice on someone's laptop when nobody types one.
    public static func guestName(on owner: String) -> String {
        "Guest on \(owner)'s laptop"
    }

    /// Whether a name is `guestName`'s: a voice known only by whose laptop it came through.
    public static func isGuestName(_ name: String) -> Bool { name.hasPrefix("Guest on ") && name.hasSuffix("'s laptop") }

    /// "Mira" from "Mira Patel", for "That's Mira".
    public static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

public enum MeetingStopReason {
    /// A file of the recording couldn't be written, such as on a full disk.
    public static let writeFailed = "couldn't save"
}

/// What a row in the meetings list says about a meeting besides its title.
public enum MeetingBadge: String, Sendable, Hashable, CaseIterable {
    case recording, processing, failed, needsNames, stoppedEarly, noAudio

    public var title: String {
        switch self {
        case .recording: "Recording"
        case .processing: "Processing"
        case .failed: "Couldn't finish"
        case .needsNames: "Needs names"
        case .stoppedEarly: "Stopped early"
        case .noAudio: "No audio"
        }
    }

    /// Stop reasons that mean the meeting didn't end on its own or by Stop.
    static let earlyStops: Set<String> = ["sleep", "lid closed", "quit", MeetingStopReason.writeFailed]

    public static func badges(_ meeting: MeetingSummary) -> [MeetingBadge] {
        switch meeting.state {
        case .recording: return [.recording]
        case .processing, .interrupted: return [.processing]
        case .failed, .ready:
            var badges: [MeetingBadge] = []
            if meeting.state == .failed { badges.append(.failed) }
            if meeting.speakers.contains(where: MeetingTimeline.isUnnamed) { badges.append(.needsNames) }
            if meeting.wasInterrupted || meeting.stopReason.map(earlyStops.contains) == true { badges.append(.stoppedEarly) }
            if !meeting.hasAudio { badges.append(.noAudio) }
            return badges
        }
    }

    /// The sentence for a meeting that stopped early, naming when: "Recording stopped at 31:12 because the Mac went to sleep."
    public static func stoppedEarlySentence(_ meeting: MeetingSummary) -> String? {
        guard badges(meeting).contains(.stoppedEarly) else { return nil }
        let at = MeetingTimeline.clock(meeting.duration)
        switch meeting.stopReason {
        case "sleep": return "Recording stopped at \(at) because the Mac went to sleep."
        case "lid closed": return "Recording stopped at \(at) because the lid closed."
        case MeetingStopReason.writeFailed: return "Recording stopped at \(at) because I couldn't save any more of it. I kept everything up to there."
        default: return "Recording stopped at \(at) because gob.lin quit. I kept everything up to there."
        }
    }
}

/// Meetings grouped by the day they started, newest first, as the list shows them.
public struct MeetingDay: Sendable, Identifiable {
    public var id: Date { day }
    public var day: Date
    public var title: String
    public var meetings: [MeetingSummary]
}

extension MeetingDay {
    public static func groups(_ meetings: [MeetingSummary], now: Date = Date(), calendar: Calendar = .current) -> [MeetingDay] {
        var groups: [MeetingDay] = []
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            let day = calendar.startOfDay(for: meeting.startedAt)
            if groups.last?.day == day { groups[groups.count - 1].meetings.append(meeting); continue }
            let title: String
            if calendar.isDate(day, inSameDayAs: now) { title = "Today" }
            else if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
                    calendar.isDate(day, inSameDayAs: yesterday) { title = "Yesterday" }
            else {
                var style = Date.FormatStyle.dateTime.weekday(.wide).month().day()
                style.calendar = calendar
                style.timeZone = calendar.timeZone
                title = day.formatted(style)
            }
            groups.append(MeetingDay(day: day, title: title, meetings: [meeting]))
        }
        return groups
    }
}
