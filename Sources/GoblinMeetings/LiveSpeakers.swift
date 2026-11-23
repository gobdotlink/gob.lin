import FluidAudio
import Foundation
import Synchronization

/// Speaker spans built chunk by chunk from the streaming speaker model, with the after-call pass's threshold and
/// shortest span (`Nemotron3Diarizer.segments`), on the session's clock.
struct LiveSpanBuilder {
    static let threshold: Float = 0.5
    static let frameSeconds = 0.01
    /// 0.2 s: a shorter blip of one voice is noise.
    static let shortestFrames = 20

    /// Session seconds of the model's first frame: later than 0 when audio was let go while the model loaded.
    let origin: Double
    private(set) var frames = 0
    private(set) var closed: [DiarizedSpan] = []
    /// Voices in the order they were first heard for at least the shortest span.
    private(set) var arrival: [Int] = []
    private var open: [Int: Int] = [:]

    init(origin: Double) { self.origin = origin }

    /// How far the model has listened.
    var processedUntil: Double { time(frames) }

    /// Up to here every voice is decided: a voice that has only just started may still turn out to be a span, so its
    /// start is the limit until it does.
    var decidedUntil: Double {
        open.filter { frames - $0.value < Self.shortestFrames }.map { time($0.value) }.min() ?? processedUntil
    }

    /// The closed spans, and the ones still going cut at `processedUntil`.
    var spans: [DiarizedSpan] {
        closed + open.filter { frames - $0.value >= Self.shortestFrames }
            .map { DiarizedSpan(speaker: $0.key, start: time($0.value), end: processedUntil) }
            .sorted { $0.start < $1.start }
    }

    /// One chunk's probabilities, `frameCount` frames of `speakers` each.
    mutating func add(_ probabilities: [Float], frameCount: Int, speakers: Int) {
        for offset in 0..<frameCount {
            let frame = frames + offset
            for slot in 0..<speakers {
                let active = probabilities[offset * speakers + slot] > Self.threshold
                if active {
                    let first = open[slot] ?? frame
                    open[slot] = first
                    if frame + 1 - first == Self.shortestFrames, !arrival.contains(slot) { arrival.append(slot) }
                } else if let first = open.removeValue(forKey: slot), frame - first >= Self.shortestFrames {
                    closed.append(DiarizedSpan(speaker: slot, start: time(first), end: time(frame)))
                }
            }
        }
        frames += frameCount
    }

    private func time(_ frame: Int) -> Double { origin + Double(frame) * Self.frameSeconds }
}

/// Who's talking on a call's track as it records. The streaming speaker model runs on the call audio; each voice is
/// named from People once it has said enough, otherwise it's "Speaker N" in the order the voices came in, as after the
/// call. The after-call pass decides the names that are kept; these are only shown while recording.
public final class LiveSpeakers: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// The model's first second: the audio before it was let go while the model loaded, so it's never placed.
        public var placedFrom: Double
        /// A line ending after this isn't placed yet.
        public var placedUntil: Double
        public var spans: [DiarizedSpan]
        /// Each voice's name, by the model's slot.
        public var names: [Int: String]
        /// Each voice's "Speaker N", for showing while Remember voices is off: the switch can turn off after a snapshot
        /// with names from People is sent, and whoever shows it checks the switch then.
        public var numbered: [Int: String] = [:]
    }

    /// Where a line stands with the speaker model.
    public enum Placement: Equatable, Sendable {
        /// The model hasn't decided all of it yet.
        case waiting
        /// The voice that said most of it.
        case voice(Int)
        /// It was said before the audio the model got, so it stays Them.
        case never
    }

    /// 2.88 s behind the audio, at the quality of the model card's low-latency profile.
    static let preset = "fast32"
    /// One for every call, so a call started while the first download runs waits for that download.
    static let files = MeetingSpeakerModel.files(preset: preset)
    /// A voice's voiceprint is made, and matched again, as its clean speech passes each of these.
    static let voiceprintSeconds = [VoiceStretches.minimumSeconds, 10, 20]
    /// The call's recent audio, for voiceprints.
    static let recentSeconds = 60.0
    /// Audio kept while the model downloads or loads; beyond it the oldest is let go and goes unplaced.
    static let waitingSeconds = 600.0
    /// Further behind the call than this, the log says so once, and again when it has caught up.
    static let behindSeconds = 10.0

    private let queue = DispatchQueue(label: "gob.lin.meetings.live-speakers", qos: .utility)
    private let voices: MeetingVoiceOptions?
    private let log: @Sendable (String) -> Void
    private let onUpdate: @Sendable (Snapshot) -> Void

    // Only touched on `queue`.
    private var diarizer: Nemotron3Diarizer?
    private var builder: LiveSpanBuilder?
    private var stopped = false
    /// The model couldn't download, load or run: the call's audio isn't kept for it any more.
    private var failed = false
    private var behind = false
    private var folder: URL?
    private var waiting: [Float] = []
    private var waitingStart = 0.0
    private var recent: [Float] = []
    private var recentStart = 0.0
    private var speech: [Int: [Float]] = [:]
    /// How far into the call each voice's speech has been looked at for its voiceprint.
    private var collectedUntil: [Int: Double] = [:]
    private var printsMade: [Int: Int] = [:]
    private var named: [Int: String] = [:]
    /// How far into the call the speech that first named each person ended, for measuring how soon names come.
    private var namedFrom: [String: Double] = [:]
    /// Seconds of speech in the newest voiceprint applied to each voice: voiceprints finish out of order, and an older
    /// one mustn't undo a newer one.
    private var appliedSeconds: [Int: Double] = [:]
    private var namingNow = 0

    /// `voices` names voices from People while its switch is on; without it they stay "Speaker N".
    public init(voices: MeetingVoiceOptions?, log: @escaping @Sendable (String) -> Void,
                onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.voices = voices
        self.log = log
        self.onUpdate = onUpdate
    }

    /// Gets the model, downloading it the first time; audio appended meanwhile waits for it.
    public func start() {
        Task.detached(priority: .utility) { [self] in
            do {
                try await MeetingPostProcessOptions.acquire(Self.files, named: "the live speaker model", modelDownload: nil, log: log)
                let config = MeetingSpeakerModel.config(preset: Self.preset)
                // Handed over once and only used on `queue` from then on.
                nonisolated(unsafe) let models = try await Nemotron3Models.load(config: config, directory: Self.files.directory)
                queue.async { self.ready(Nemotron3Diarizer(config: config, models: models)) }
            } catch {
                queue.async { self.fail("live speakers: \(error.localizedDescription)") }
            }
        }
    }

    /// The meeting's folder: its participant list limits who a voice can be, as after the call, and voices People
    /// learned from this same meeting aren't matched against it.
    public func record(in folder: URL) {
        queue.async { self.folder = folder }
    }

    /// The call's track at 16 kHz from the session's start, gaps already filled with silence.
    public func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !stopped, !failed else { return }
            Self.keep(&recent, start: &recentStart, adding: samples, seconds: Self.recentSeconds)
            if let diarizer {
                diarizer.appendAudio(samples)
                run()
            } else {
                Self.keep(&waiting, start: &waitingStart, adding: samples, seconds: Self.waitingSeconds)
            }
        }
    }

    /// Lets the model go, before the after-call pass loads its own.
    public func stop() {
        queue.async { [self] in
            stopped = true
            release()
        }
    }

    /// Where `segment` stands in `snapshot`.
    public static func placement(of segment: TranscriptSegment, in snapshot: Snapshot) -> Placement {
        guard segment.start >= snapshot.placedFrom else { return .never }
        guard snapshot.placedUntil >= segment.end else { return .waiting }
        // A window around the line keeps this cheap late in a long call; the nearest voice is never far.
        let near = snapshot.spans.filter { $0.end > segment.start - 30 && $0.start < segment.end + 30 }
        let speakers = MeetingPostProcessor.speakers(for: segment, spans: near.isEmpty ? snapshot.spans : near)
        var counts: [Int: Int] = [:]
        for case let speaker? in speakers { counts[speaker, default: 0] += 1 }
        // Ties go to whoever spoke first in the line.
        guard let voice = speakers.compactMap({ $0 }).first(where: { counts[$0] == counts.values.max() }) else { return .waiting }
        return .voice(voice)
    }

    private func ready(_ diarizer: Nemotron3Diarizer) {
        guard !stopped, !failed else { return }
        log("live speakers ready")
        self.diarizer = diarizer
        builder = LiveSpanBuilder(origin: waitingStart)
        diarizer.appendAudio(waiting)
        waiting = []
        run()
    }

    private func fail(_ message: String) {
        log(message)
        failed = true
        release()
    }

    private func release() {
        diarizer = nil
        waiting = []
        recent = []
        speech = [:]
    }

    private func run() {
        guard let diarizer, var builder else { return }
        let results: [Nemotron3ChunkResult]
        do { results = try diarizer.processBufferedAudio() } catch {
            fail("live speakers stopped: \(error.localizedDescription)")
            return
        }
        guard !results.isEmpty else { return }
        for result in results { builder.add(result.probabilities, frameCount: result.frameCount, speakers: result.numSpeakers) }
        self.builder = builder
        noteLag(builder)
        collect(builder)
        emit()
    }

    /// Says once when the model falls well behind the call, as sharing the chip with live captions might make it.
    private func noteLag(_ builder: LiveSpanBuilder) {
        let heard = recentStart + Double(recent.count) / MeetingAudio.sampleRate
        let lag = heard - builder.processedUntil
        if !behind, lag > Self.behindSeconds {
            behind = true
            log(String(format: "live speakers are %.0f s behind the call", lag))
        } else if behind, lag < Self.behindSeconds / 2 {
            behind = false
            log("live speakers caught up")
        }
    }

    /// Takes each voice's new speech that nobody talked over, up to where every voice is decided, for its voiceprint.
    /// A voice talking for minutes gets its voiceprints as it goes, not when it stops.
    private func collect(_ builder: LiveSpanBuilder) {
        guard voices?.enabled() == true else { return }
        let budget = Int((Self.voiceprintSeconds.last ?? 20) * MeetingAudio.sampleRate)
        let spans = builder.spans
        let decided = builder.decidedUntil
        for span in spans where span.end > collectedUntil[span.speaker] ?? -1 {
            let slot = span.speaker
            let from = max(span.start, collectedUntil[slot] ?? span.start)
            let to = min(span.end, decided)
            guard to > from else { continue }
            guard (speech[slot]?.count ?? 0) < budget else {
                collectedUntil[slot] = to
                continue
            }
            let others = spans.filter { $0.speaker != slot && $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
            var pieces: [ClosedRange<Double>] = []
            var cursor = from
            for other in others {
                if other.start - cursor >= VoiceStretches.shortestPiece { pieces.append(cursor...other.start) }
                cursor = max(cursor, other.end)
            }
            // A clean tail too short to keep yet, at the edge of what's decided, may grow with the next update: it's
            // looked at again then rather than dropped.
            if to - cursor >= VoiceStretches.shortestPiece { pieces.append(cursor...to) }
            collectedUntil[slot] = to - cursor < VoiceStretches.shortestPiece && to == decided && cursor < to ? cursor : to
            for piece in pieces {
                // Only what's still in memory: the start of a long stretch may have been let go already.
                let start = max(0, Int((piece.lowerBound - recentStart) * MeetingAudio.sampleRate))
                let end = min(recent.count, Int((piece.upperBound - recentStart) * MeetingAudio.sampleRate),
                              start + budget - (speech[slot]?.count ?? 0))
                if end > start { speech[slot, default: []] += recent[start..<end] }
            }
            let seconds = Double(speech[slot]?.count ?? 0) / MeetingAudio.sampleRate
            let made = printsMade[slot] ?? 0
            var reached = made
            while reached < Self.voiceprintSeconds.count, seconds >= Self.voiceprintSeconds[reached] { reached += 1 }
            if reached > made {
                printsMade[slot] = reached
                name(slot, from: speech[slot] ?? [], seconds: seconds, heardBy: to)
            }
        }
    }

    /// Matches a voice against People with the after-call rules; a name, once given, stays unless someone else wins.
    private func name(_ slot: Int, from samples: [Float], seconds: Double, heardBy: Double) {
        guard let voices else { return }
        let folder = folder
        namingNow += 1
        Task.detached(priority: .utility) { [self] in
            var match: MeetingVoices.Match?
            do {
                let embedding = try await voices.embed(samples)
                // Remember voices may have been turned off, and every voice forgotten, while that ran.
                if voices.enabled() {
                    let voice = MeetingVoice(label: "\(slot)", track: .system, seconds: seconds, clipStart: 0, clipEnd: 0,
                                             embedding: embedding)
                    let people = voices.people.people().map { person in
                        var person = person
                        person.samples.removeAll { $0.meetingID == folder?.lastPathComponent }
                        return person
                    }
                    let participants = folder.map(MeetingParticipants.read) ?? MeetingParticipants()
                    match = VoiceMatching.match([voice], people: people, participants: participants, inPerson: false)["\(slot)"]
                    // Without the person's name: a log line outlives Turn Off and Forget.
                    log(String(format: "live voiceprint: voice %d, %.0f s of speech by %.0f s: %@", slot, seconds, heardBy,
                               match.map { String(format: "a person at %.2f%@", $0.similarity, $0.named ? "" : " (not named)") } ?? "nobody close"))
                }
            } catch {
                log("live voiceprint: \(error.localizedDescription)")
            }
            let found = match
            queue.async { [self] in
                namingNow -= 1
                // A contact renamed "Them", "You" or "Speaker 2" in People would read as a side or a placeholder.
                guard !stopped, voices.enabled(), let match = found, match.named, PeopleStore.isPersonName(match.name) else { return }
                namedFrom[match.name] = min(namedFrom[match.name] ?? heardBy, heardBy)
                guard seconds >= appliedSeconds[slot] ?? 0 else { return }
                appliedSeconds[slot] = seconds
                guard named[slot] != match.name else { return }
                named[slot] = match.name
                emit()
            }
        }
    }

    private func emit() {
        guard let builder else { return }
        // With Remember voices off, names from People aren't shown, including ones given before it was turned off.
        let fromPeople = voices?.enabled() == true ? named : [:]
        var names: [Int: String] = [:], numbered: [Int: String] = [:]
        for (index, slot) in builder.arrival.enumerated() {
            numbered[slot] = "Speaker \(index + 1)"
            names[slot] = fromPeople[slot] ?? numbered[slot]
        }
        onUpdate(Snapshot(placedFrom: builder.origin, placedUntil: builder.decidedUntil, spans: builder.spans, names: names,
                          numbered: numbered))
    }

    /// Appends to a rolling buffer, letting the oldest go in steps so it isn't copied on every append.
    private static func keep(_ buffer: inout [Float], start: inout Double, adding samples: [Float], seconds: Double) {
        buffer += samples
        let limit = Int(seconds * MeetingAudio.sampleRate)
        guard buffer.count > limit + limit / 2 else { return }
        let drop = buffer.count - limit
        buffer.removeFirst(drop)
        start += Double(drop) / MeetingAudio.sampleRate
    }
}

// MARK: Replaying a recorded call

extension LiveSpeakers {
    /// The live speakers' final attribution of a recorded call's saved call-track lines, next to the names the
    /// after-call pass gave them. It's the end state, after every voiceprint has finished, not a moment of the call.
    public struct Replay: Codable, Sendable {
        public struct Line: Codable, Sendable {
            public var start: Double
            public var live: String
            /// Nil when no after-call line overlaps it, so it isn't scored.
            public var afterCall: String?
            public var text: String
        }

        public var callSeconds: Double
        public var replaySeconds: Double
        /// Each name the live speakers gave from People, and how far into the call the speech that named it ended:
        /// live, the name shows a voiceprint's time (well under a second) and the model's 2.9 s after that.
        public var namedAt: [String: Double]
        /// Scored lines whose live voice matches its after-call voice, with each live voice paired to one after-call
        /// voice: a person split in two or two people merged into one both cost lines.
        public var sameVoiceShare: Double
        /// Scored lines named from People live that have that name after the call too, and those that don't.
        public var namedRight: Int
        public var namedWrong: Int
        public var lines: [Line]
    }

    /// Plays a processed call's track through the live speakers as fast as they run, then places its saved lines.
    public static func replay(_ directory: URL, voices: MeetingVoiceOptions?,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Replay {
        let samples = try WAVFile.readSamples(directory.appendingPathComponent("\(MeetingTrack.system.fileStem).wav"))
        let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
            .filter { $0.track == .system }
        let turns = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                                   from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)))
            .filter { $0.track == .system }
        let latest = Mutex<Snapshot?>(nil)
        let live = LiveSpeakers(voices: voices, log: log) { snapshot in latest.withLock { $0 = snapshot } }
        defer { live.stop() }
        live.record(in: directory)
        let began = Date()
        live.start()
        // The model first, so none of the call waits past what a live call would hold.
        while await live.onQueue({ $0.diarizer == nil && !$0.stopped && !$0.failed }) {
            if Date().timeIntervalSince(began) > 600 { throw ReplayError("The live speaker model didn't load.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        let step = Int(MeetingAudio.sampleRate / 2)
        for start in stride(from: 0, to: samples.count, by: step) {
            live.append(Array(samples[start..<min(samples.count, start + step)]))
        }
        while await live.onQueue({ $0.namingNow > 0 || !$0.waiting.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        if await live.onQueue({ $0.failed }) { throw ReplayError("The live speaker model failed; --verbose says why.") }
        let replaySeconds = Date().timeIntervalSince(began)
        let namedAt = await live.onQueue { $0.namedFrom }

        guard let snapshot = latest.withLock({ $0 }) else { throw ReplayError("The live speaker model placed nothing.") }
        let lines = segments.map { segment in
            let placement = placement(of: segment, in: snapshot)
            let voice: Int? = if case .voice(let voice) = placement { voice } else { nil }
            let afterCall = turns.filter { overlap($0, segment) > 0 }.max { overlap($0, segment) < overlap($1, segment) }?.speaker
            return (voice, Replay.Line(start: segment.start, live: voice.flatMap { snapshot.names[$0] } ?? "Them",
                                       afterCall: afterCall, text: segment.text))
        }
        let scored = lines.filter { $0.1.afterCall != nil }
        // Each live voice paired with one after-call voice, most shared lines first.
        var shared: [Pair: Int] = [:]
        for case let (voice?, line) in scored { shared[Pair(voice: voice, afterCall: line.afterCall ?? ""), default: 0] += 1 }
        var pairedVoices = Set<Int>(), pairedNames = Set<String>(), same = 0
        // Ties in a fixed order, so the same call always scores the same.
        for (pair, count) in shared.sorted(by: { ($0.value, $1.key.voice, $1.key.afterCall) > ($1.value, $0.key.voice, $0.key.afterCall) })
        where !pairedVoices.contains(pair.voice) && !pairedNames.contains(pair.afterCall) {
            pairedVoices.insert(pair.voice)
            pairedNames.insert(pair.afterCall)
            same += count
        }
        let named = scored.map { $0.1 }.filter { !MeetingTimeline.isUnnamed($0.live) && $0.live != "Them" }
        return Replay(callSeconds: Double(samples.count) / MeetingAudio.sampleRate, replaySeconds: replaySeconds,
                      namedAt: namedAt, sameVoiceShare: scored.isEmpty ? 0 : Double(same) / Double(scored.count),
                      namedRight: named.filter { $0.live == $0.afterCall }.count,
                      namedWrong: named.filter { $0.live != $0.afterCall }.count, lines: lines.map { $0.1 })
    }

    private struct Pair: Hashable {
        let voice: Int
        let afterCall: String
    }

    struct ReplayError: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func overlap(_ turn: TranscriptTurn, _ segment: TranscriptSegment) -> Double {
        max(0, min(turn.end, segment.end) - max(turn.start, segment.start))
    }

    private func onQueue<T: Sendable>(_ read: @escaping @Sendable (LiveSpeakers) -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: read(self)) } }
    }
}
