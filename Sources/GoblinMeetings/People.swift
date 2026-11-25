import Foundation
import os

/// Someone gob.lin knows by voice: a name and voice samples from the meetings they were named in.
public struct Person: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// The person at this Mac: their voice is the mic on calls, and "You" in the room.
    public var isMe: Bool
    public var samples: [VoiceSample]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, isMe: Bool = false, samples: [VoiceSample] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.samples = samples
        self.createdAt = createdAt
    }

    /// Meetings this person was heard in, newest first.
    public var meetingIDs: [String] {
        var seen: [String] = []
        for sample in samples.sorted(by: { $0.heardAt > $1.heardAt }) where !seen.contains(sample.meetingID) { seen.append(sample.meetingID) }
        return seen
    }

    public var lastHeard: Date? { samples.map(\.heardAt).max() }
    public var secondsHeard: Double { samples.reduce(0) { $0 + $1.seconds } }
}

/// One voice of one meeting, kept as its voiceprint. The audio isn't copied: the clip plays from the meeting while the
/// meeting keeps its audio.
public struct VoiceSample: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var meetingID: String
    public var meetingTitle: String
    /// What the meeting's post-processor called the voice ("Speaker 2", "You").
    public var label: String
    public var track: MeetingTrack
    /// When the meeting started.
    public var heardAt: Date
    public var seconds: Double
    public var clipStart: Double
    public var clipEnd: Double
    /// In the room or on a call: in-person samples come from the laptop's mic, call samples from the call's audio.
    public var inPerson: Bool
    public var embedding: [Float]
    /// The name the meeting gave the voice when it was learned. While the meeting still calls the voice that, the sample
    /// stays with whoever holds it now, so a rename or merge made in People survives the meeting being learned again.
    public var learnedAs: String? = nil

    public init(id: UUID = UUID(), meetingID: String, meetingTitle: String, label: String, track: MeetingTrack, heardAt: Date,
                seconds: Double, clipStart: Double, clipEnd: Double, inPerson: Bool, embedding: [Float]) {
        self.id = id
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.label = label
        self.track = track
        self.heardAt = heardAt
        self.seconds = seconds
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.inPerson = inPerson
        self.embedding = embedding
    }
}

public enum PeopleError: Error, LocalizedError, Equatable {
    case notFound
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .notFound: "That person isn't in People any more."
        case .emptyName: "A name needs at least one letter."
        }
    }
}

/// People and their voices, in `gob.lin/People/people.json` beside the Meetings folder. Everything stays on this Mac.
///
/// A meeting's samples are always rebuilt from the meeting as it stands (`learn`), so renaming a voice moves its sample
/// to the new name, and unnaming it takes the sample away: the library follows what the person decided.
public final class PeopleStore: Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Beside people.json; held for every read-modify-write, so the app and the CLI never overwrite each other.
    private var lockURL: URL { url.deletingLastPathComponent().appendingPathComponent(".people.lock") }

    /// Samples kept per person; the oldest go first, so a voice that changed (a new mic, a cold) is learned again.
    public static let samplesPerPerson = 24

    public init(url: URL) { self.url = url.standardizedFileURL }

    /// Next to `meetingsRoot`: `gob.lin/People/people.json` for `gob.lin/Meetings`.
    public convenience init(meetingsRoot: URL = MeetingStorage.root) {
        self.init(url: meetingsRoot.deletingLastPathComponent().appendingPathComponent("People/people.json"))
    }

    struct Document: Codable, Equatable {
        var version = 1
        var people: [Person]
        /// Voices of a meeting someone took out of People ("meeting ID␟label"): learning that meeting again, after a
        /// rename elsewhere in it or an Undo, never puts them back. Cleared when the meeting is processed again or deleted.
        var declined: [String]? = nil
    }

    static func key(_ meetingID: String, _ label: String) -> String { meetingID + "\u{1F}" + label }

    public func people() -> [Person] { lock.withLock { read() } }

    public var isEmpty: Bool { people().isEmpty }

    private func read() -> [Person] { readDocument().people }

    private func readDocument() -> Document { (try? loadDocument()) ?? Document(people: []) }

    /// The document as saved, or an empty one when there's no file yet. A file that's there but won't read or decode is
    /// an error: a change written over it would replace everyone in it with nothing.
    private func loadDocument() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document(people: []) }
        return try JSONDecoder.meeting.decode(Document.self, from: Data(contentsOf: url))
    }

    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var document = document
        document.people.sort { ($0.isMe ? 0 : 1, $0.name.lowercased()) < ($1.isMe ? 0 : 1, $1.name.lowercased()) }
        if document.declined?.isEmpty == true { document.declined = nil }
        try JSONEncoder.pretty.encode(document).write(to: url, options: .atomic)
    }

    /// Reads, changes and writes the whole document, declined voices included, under both locks.
    @discardableResult
    func updateDocument<T>(_ change: (inout Document) throws -> T) throws -> T {
        try lock.withLock { try withFileLock {
            var document = try loadDocument()
            let before = document
            let result = try change(&document)
            if document != before { try write(document) }
            return result
        } }
    }

    /// Reads, changes and writes people.json under the lock.
    @discardableResult
    public func update<T>(_ change: (inout [Person]) throws -> T) throws -> T {
        try updateDocument { document in try change(&document.people) }
    }

    // MARK: Learning from meetings

    /// What a meeting says about voices: each named voice's voiceprint under its name. Replaces whatever this meeting
    /// taught before. `me` is the name of this Mac's person on the call, if the call said.
    public func learn(meetingID: String, title: String, startedAt: Date, inPerson: Bool, voices: [MeetingVoice],
                      names: [String: String], me: String?) throws {
        try updateDocument { document in
            let declined = Set(document.declined ?? [])
            var people = document.people
            var evicted: [String] = []
            defer {
                document.people = people
                if !evicted.isEmpty { document.declined = (document.declined ?? []) + evicted }
            }
            // Who holds each of this meeting's voices now, and under what name the meeting gave it then.
            var held: [String: (person: UUID, learnedAs: String?, sample: UUID)] = [:]
            for person in people {
                for sample in person.samples where sample.meetingID == meetingID {
                    held[sample.label] = (person.id, sample.learnedAs, sample.id)
                }
            }
            for index in people.indices { people[index].samples.removeAll { $0.meetingID == meetingID } }
            for voice in voices where !declined.contains(Self.key(meetingID, voice.label)) {
                let shown = names[voice.label] ?? voice.label
                // On a call the mic's own voice is the person at this Mac, whatever its lane is called ("Will", a
                // nickname), unless that's someone else already in People: the mic was theirs that day. Anyone else
                // heard on a shared mic, and every voice in the room, is whoever they were named, You included.
                let yours = !inPerson && voice.track == .microphone && voice.label == MeetingPostProcessor.microphoneLabel
                    && !people.contains { !$0.isMe && Self.sameName($0.name, shown) }
                let isMe = yours || shown == MeetingPostProcessor.microphoneLabel
                guard isMe || Self.isPersonName(shown) else { continue }
                var sample = VoiceSample(meetingID: meetingID, meetingTitle: title, label: voice.label, track: voice.track,
                                         heardAt: startedAt, seconds: voice.seconds, clipStart: voice.clipStart, clipEnd: voice.clipEnd,
                                         inPerson: inPerson, embedding: voice.embedding)
                sample.learnedAs = shown
                let index: Int
                if let previous = held[voice.label], previous.learnedAs == shown,
                   let owner = people.firstIndex(where: { $0.id == previous.person }) {
                    // The meeting still calls this voice what it did: it stays with whoever People says it is now, as
                    // the same sample, so a People page showing it can still remove it.
                    index = owner
                    sample.id = previous.sample
                } else if isMe {
                    if let existing = people.firstIndex(where: \.isMe) {
                        index = existing
                    } else if let me, let named = people.firstIndex(where: { Self.sameName($0.name, me) }) {
                        // Someone already in People by this Mac's person's name (a voice named in the room): that's you.
                        people[named].isMe = true
                        index = named
                    } else {
                        people.append(Person(name: me ?? Self.defaultMeName, isMe: true))
                        index = people.count - 1
                    }
                } else if let existing = people.firstIndex(where: { !$0.isMe && Self.sameName($0.name, shown) }) {
                    index = existing
                } else if let me = people.firstIndex(where: \.isMe), Self.sameName(people[me].name, shown) {
                    // Someone named a voice after the person at this Mac (in the room, "Will" rather than "You").
                    index = me
                } else {
                    people.append(Person(name: shown))
                    index = people.count - 1
                }
                // Your voice is learned from every call's mic without anyone confirming it, so a mic track that sounds
                // like none of your samples (someone else at the Mac, audio played into the mic) isn't taken as you.
                // A voice someone named You is taken at their word.
                if yours, !Self.fitsYourVoice(sample, people[index]) { continue }
                people[index].samples.append(sample)
                if people[index].samples.count > Self.samplesPerPerson {
                    let sorted = people[index].samples.sorted { $0.heardAt > $1.heardAt }
                    // An old sample let go for space is declined too: learning its meeting again mustn't bring it back
                    // under the name that meeting gave it then, after People has renamed or merged that person.
                    evicted += sorted.dropFirst(Self.samplesPerPerson).map { Self.key($0.meetingID, $0.label) }
                    people[index].samples = Array(sorted.prefix(Self.samplesPerPerson))
                }
            }
            // Someone whose every sample came from this meeting and was just unnamed is no longer known.
            people.removeAll { $0.samples.isEmpty && !$0.isMe }
        }
    }

    /// Takes away everything a deleted meeting taught.
    public func forget(meetingID: String) throws {
        // Nothing learned yet: don't create People just to forget nothing.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try updateDocument { document in
            for index in document.people.indices { document.people[index].samples.removeAll { $0.meetingID == meetingID } }
            document.people.removeAll { $0.samples.isEmpty && !$0.isMe }
            document.declined?.removeAll { $0.hasPrefix(meetingID + "\u{1F}") }
        }
    }

    // MARK: Editing

    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PeopleError.emptyName }
        try update { people in
            guard let index = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.notFound }
            people[index].name = name
        }
    }

    /// Moves every sample of `id` to `target`, for two entries that turned out to be one person.
    public func merge(_ id: UUID, into target: UUID) throws {
        guard id != target else { return }
        try update { people in
            guard let from = people.firstIndex(where: { $0.id == id }), let into = people.firstIndex(where: { $0.id == target }) else {
                throw PeopleError.notFound
            }
            people[into].samples += people[from].samples
            people[into].isMe = people[into].isMe || people[from].isMe
            people.remove(at: from)
        }
    }

    public func removeSample(_ sampleID: UUID, from id: UUID) throws {
        try updateDocument { document in
            guard let index = document.people.firstIndex(where: { $0.id == id }) else { throw PeopleError.notFound }
            for sample in document.people[index].samples where sample.id == sampleID {
                document.declined = (document.declined ?? []) + [Self.key(sample.meetingID, sample.label)]
            }
            document.people[index].samples.removeAll { $0.id == sampleID }
            if document.people[index].samples.isEmpty, !document.people[index].isMe { document.people.remove(at: index) }
        }
    }

    /// Forgets a person and every sample of their voice.
    public func remove(_ id: UUID) throws {
        try updateDocument { document in
            for person in document.people where person.id == id {
                document.declined = (document.declined ?? []) + person.samples.map { Self.key($0.meetingID, $0.label) }
            }
            document.people.removeAll { $0.id == id }
        }
    }

    /// Forgets everyone: Remember voices turned off with Forget Voices.
    public func removeAll() throws {
        try lock.withLock { try withFileLock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } }
    }

    /// An exclusive `flock` on the lock file for the length of `body`, shared with every process using this folder.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockURL.path]) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 { guard errno == EINTR else { throw CocoaError(.fileLocking) } }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    // MARK: Names

    static let defaultMeName = "You"

    /// A name a person gave: not a voice number, not "Them", not a guest on someone else's laptop.
    static func isPersonName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !MeetingTimeline.isUnnamed(trimmed) && trimmed != MeetingPostProcessor.unknownRemoteLabel
            && trimmed != MeetingPostProcessor.microphoneLabel && !SpeakerSuggestions.isGuestName(trimmed)
    }

    /// With this many samples of your voice, a new one has to sound like at least one of them.
    static let yourVoiceSettled = 3
    /// The least a new sample of your voice must match one you already have. Your voice across calls matched 0.88–0.94;
    /// another person on the same mic, at most about 0.5.
    static let yourVoiceFloor: Float = 0.6

    static func fitsYourVoice(_ sample: VoiceSample, _ me: Person) -> Bool {
        let others = me.samples.filter { $0.meetingID != sample.meetingID }
        guard others.count >= yourVoiceSettled else { return true }
        return (others.map { Voiceprint.similarity($0.embedding, sample.embedding) }.max() ?? 1) >= yourVoiceFloor
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}

/// Matching a meeting's voices against People.
public enum VoiceMatching {
    /// At or above this, with `margin` over anyone else, a voice is named without asking. Your own voice across calls
    /// scored 0.88–0.94; a colleague across two calls 0.83; two different people on one call at most 0.72.
    public static let nameThreshold: Float = 0.80
    /// The best match must beat the next person by this much to be named.
    public static let margin: Float = 0.06
    /// At or above this the voice is suggested in Who's this? instead.
    public static let suggestThreshold: Float = 0.66
    /// Two voices of one meeting this alike are probably one person the diarizer split (a mic change mid-call).
    public static let sameVoiceThreshold: Float = 0.77
    /// What a second sample must score for the closest one to count, once the person has `backingSettled` samples of
    /// that kind. Where the closest sample was the right person a second one scored 0.82 or more; the one sample that
    /// named a colleague You (two people on one call's mic) had 18 others, the nearest at 0.61.
    public static let backingThreshold: Float = 0.70
    static let backingSettled = 3

    /// The best person for each voice, by the closest sample their others bear out. `candidates` limits who a call's
    /// voices can be: on a call with a participant list only those people for a remote voice, and never you. Each
    /// person names at most one voice per track unless two voices both clear the bar: the diarizer splitting someone
    /// in two is more common than two people sounding alike.
    public static func match(_ voices: [MeetingVoice], people: [Person], participants: MeetingParticipants,
                             inPerson: Bool) -> [String: MeetingVoices.Match] {
        let invited = Set(participants.all.map { $0.lowercased() })
        var result: [String: MeetingVoices.Match] = [:]
        for voice in voices {
            // On a call the mic's own voice is you already; remote voices, voices in the room and anyone else heard on
            // a shared mic are matched.
            let besideYou = !inPerson && voice.track == .microphone
            guard !besideYou || voice.label != MeetingPostProcessor.microphoneLabel else { continue }
            let candidates = people.filter { person in
                guard !person.samples.isEmpty else { return false }
                if inPerson { return true }
                // Which of a call's voices is you was settled from the whole microphone, not one closest sample.
                if person.isMe { return false }
                // Someone beside you needn't have joined the call themselves.
                return besideYou || invited.isEmpty || invited.contains(person.name.lowercased())
            }
            let scored = candidates.map { person in (person, similarity(voice, person)) }.sorted { $0.1 > $1.1 }
            guard let best = scored.first, best.1 >= suggestThreshold else { continue }
            let runnerUp = scored.dropFirst().first?.1 ?? -1
            let named = best.1 >= nameThreshold && best.1 - runnerUp >= margin
            result[voice.label] = MeetingVoices.Match(personID: best.0.id, name: best.0.isMe ? MeetingPostProcessor.microphoneLabel : best.0.name,
                                                      similarity: best.1, named: named)
        }
        return result
    }

    /// How alike a voice and a person are: the closest of their samples, unless the others say that one is a stray.
    /// One sample can be someone else (two people on one microphone, a voice named by mistake), and a name it gave
    /// would be learned and stick. So among samples of one kind, call or room and which track, a second has to come
    /// near the voice too, or the closest is set aside. One voice sounds too different between a call and the room to
    /// ask that across kinds, and with too few of a kind to compare the closest stands.
    static func similarity(_ voice: MeetingVoice, _ person: Person) -> Float {
        struct Kind: Hashable {
            var inPerson: Bool
            var track: MeetingTrack
        }
        var kinds: [Kind: [Float]] = [:]
        for sample in person.samples {
            kinds[Kind(inPerson: sample.inPerson, track: sample.track), default: []].append(Voiceprint.similarity(sample.embedding, voice.embedding))
        }
        return kinds.values.map { kind in
            let closest = kind.sorted(by: >)
            return closest.count < backingSettled || closest[1] >= backingThreshold ? closest[0] : closest[1]
        }.max() ?? -1
    }

    /// Whether the lane a voice is shown in still waits for a name: "Speaker 2", "Them", or merged into one of those.
    public static func waitsForName(_ label: String, names: [String: String]) -> Bool {
        let shown = names[label] ?? label
        return MeetingTimeline.isUnnamed(shown) || shown == MeetingPostProcessor.unknownRemoteLabel
    }

    /// One match per shown lane, the closest: a lane merged from two voices is named once, through either of them.
    public static func bestPerLane(_ matches: [String: MeetingVoices.Match], names: [String: String]) -> [String: MeetingVoices.Match] {
        var best: [String: (label: String, match: MeetingVoices.Match)] = [:]
        for (label, match) in matches {
            let lane = names[label] ?? label
            if let current = best[lane], current.match.similarity >= match.similarity { continue }
            best[lane] = (label, match)
        }
        return Dictionary(uniqueKeysWithValues: best.values.map { ($0.label, $0.match) })
    }

    /// Pairs of unnamed voices in one meeting that sound like the same person, most alike first.
    public static func sameVoice(_ voices: [MeetingVoice]) -> [(String, String, Float)] {
        var pairs: [(String, String, Float)] = []
        for (index, a) in voices.enumerated() {
            for b in voices[(index + 1)...] where a.track == b.track {
                let similarity = Voiceprint.similarity(a.embedding, b.embedding)
                if similarity >= sameVoiceThreshold { pairs.append((a.label, b.label, similarity)) }
            }
        }
        return pairs.sorted { $0.2 > $1.2 }
    }
}

/// What voiceprints say on a meeting's page.
public enum VoiceSuggestions {
    /// Shown names that matching filled in, and still stand.
    public static func namedFromVoice(_ voices: MeetingVoices, names: [String: String]) -> Set<String> {
        Set(voices.matches.compactMap { label, match in match.named && names[label] == match.name ? match.name : nil })
    }

    /// For each voice still waiting for a name, who it sounds like: people in People first, then another voice of the
    /// same meeting it may be the other half of.
    public static func suggestions(_ voices: MeetingVoices, names: [String: String], people: [Person]) -> [String: [SpeakerSuggestion]] {
        func shown(_ label: String) -> String { names[label] ?? label }
        var result: [String: [SpeakerSuggestion]] = [:]
        func add(_ suggestion: SpeakerSuggestion, to label: String) {
            let key = shown(label)
            guard MeetingTimeline.isUnnamed(key) || key == MeetingPostProcessor.unknownRemoteLabel, suggestion.name != key, !(result[key] ?? []).contains(where: { $0.name == suggestion.name }) else { return }
            result[key, default: []].append(suggestion)
        }
        for (label, match) in voices.matches.sorted(by: { $0.value.similarity > $1.value.similarity }) where !match.named {
            // By who it is, not the name saved with the match: People may have renamed, merged or forgotten them since.
            guard let person = people.first(where: { $0.id == match.personID }) else { continue }
            let name = person.isMe ? MeetingPostProcessor.microphoneLabel : person.name
            let meetings = person.meetingIDs.count
            let heard = meetings > 1 ? "from \(meetings) meetings" : meetings == 1 ? "from another meeting" : "in People"
            let who = person.isMe ? "you" : SpeakerSuggestions.firstName(name)
            add(SpeakerSuggestion(name: name, reason: "Sounds like \(who), \(heard)."), to: label)
        }
        for (a, b, _) in VoiceMatching.sameVoice(voices.voices) {
            add(SpeakerSuggestion(name: shown(b), reason: "Sounds like the same voice as \(shown(b)) in this meeting."), to: a)
            add(SpeakerSuggestion(name: shown(a), reason: "Sounds like the same voice as \(shown(a)) in this meeting."), to: b)
        }
        return result
    }
}
