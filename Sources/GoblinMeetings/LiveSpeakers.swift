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

    /// Up to here the model has decided who was talking.
    var placedUntil: Double { time(frames) }

    /// The closed spans, and the ones still going cut at `placedUntil`.
    var spans: [DiarizedSpan] {
        closed + open.filter { frames - $0.value >= Self.shortestFrames }
            .map { DiarizedSpan(speaker: $0.key, start: time($0.value), end: placedUntil) }
            .sorted { $0.start < $1.start }
    }

    /// One chunk's probabilities, `frameCount` frames of `speakers` each. Returns the spans it closed.
    mutating func add(_ probabilities: [Float], frameCount: Int, speakers: Int) -> [DiarizedSpan] {
        var finished: [DiarizedSpan] = []
        for offset in 0..<frameCount {
            let frame = frames + offset
            for slot in 0..<speakers {
                let active = probabilities[offset * speakers + slot] > Self.threshold
                if active {
                    let first = open[slot] ?? frame
                    open[slot] = first
                    if frame + 1 - first == Self.shortestFrames, !arrival.contains(slot) { arrival.append(slot) }
                } else if let first = open.removeValue(forKey: slot), frame - first >= Self.shortestFrames {
                    finished.append(DiarizedSpan(speaker: slot, start: time(first), end: time(frame)))
                }
            }
        }
        frames += frameCount
        closed += finished
        return finished
    }

    private func time(_ frame: Int) -> Double { origin + Double(frame) * Self.frameSeconds }
}

/// Who's talking on a call's track as it records. The streaming speaker model runs on the call audio; each voice is
/// named from People once it has said enough, otherwise it's "Speaker N" in the order the voices came in, as after the
/// call. The after-call pass decides the names that are kept; these are only shown while recording.
public final class LiveSpeakers: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// A line ending after this isn't placed yet.
        public var placedUntil: Double
        public var spans: [DiarizedSpan]
        /// Each voice's name, by the model's slot.
        public var names: [Int: String]
    }

    /// 2.88 s behind the audio, at the quality of the model card's low-latency profile.
    static let preset = "fast32"
    /// A voice's voiceprint is made, and matched again, as its clean speech passes each of these.
    static let voiceprintSeconds = [VoiceStretches.minimumSeconds, 10, 20]
    /// The call's recent audio, for voiceprints: a span closes a few seconds after the voice starts.
    static let recentSeconds = 60.0
    /// Audio kept while the model downloads or loads; beyond it the oldest is let go and goes unplaced.
    static let waitingSeconds = 600.0

    private let queue = DispatchQueue(label: "gob.lin.meetings.live-speakers", qos: .utility)
    private let voices: MeetingVoiceOptions?
    /// A recorded call replayed has its own voices in People already; those would only match themselves.
    private let excludingMeeting: String?
    private let log: @Sendable (String) -> Void
    private let onUpdate: @Sendable (Snapshot) -> Void

    // Only touched on `queue`.
    private var diarizer: Nemotron3Diarizer?
    private var builder: LiveSpanBuilder?
    private var stopped = false
    private var waiting: [Float] = []
    private var waitingStart = 0.0
    private var recent: [Float] = []
    private var recentStart = 0.0
    private var speech: [Int: [Float]] = [:]
    private var printsMade: [Int: Int] = [:]
    private var named: [Int: String] = [:]
    /// How far into the call each voiceprint that named someone had its speech, for measuring how soon names come.
    private var namedFrom: [String: Double] = [:]
    /// Seconds of speech in the newest voiceprint applied to each voice: voiceprints finish out of order, and an older
    /// one mustn't undo a newer one.
    private var appliedSeconds: [Int: Double] = [:]
    private var namingNow = 0

    /// `voices` names voices from People while its switch is on; without it they stay "Speaker N".
    public init(voices: MeetingVoiceOptions?, excludingMeeting: String? = nil, log: @escaping @Sendable (String) -> Void,
                onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.voices = voices
        self.excludingMeeting = excludingMeeting
        self.log = log
        self.onUpdate = onUpdate
    }

    /// Gets the model, downloading it the first time; audio appended meanwhile waits for it.
    public func start() {
        Task.detached(priority: .utility) { [self] in
            do {
                let files = MeetingSpeakerModel.files(preset: Self.preset)
                try await MeetingPostProcessOptions.acquire(files, named: "the live speaker model", modelDownload: nil, log: log)
                let config = MeetingSpeakerModel.config(preset: Self.preset)
                // Handed over once and only used on `queue` from then on.
                nonisolated(unsafe) let models = try await Nemotron3Models.load(config: config, directory: files.directory)
                queue.async { self.ready(Nemotron3Diarizer(config: config, models: models)) }
            } catch {
                log("live speakers: \(error.localizedDescription)")
            }
        }
    }

    /// The call's track at 16 kHz from the session's start, gaps already filled with silence.
    public func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !stopped else { return }
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
            diarizer = nil
            waiting = []
            recent = []
            speech = [:]
        }
    }

    /// The voice that said most of `segment`'s words, or nil while the model hasn't placed all of it.
    public static func voice(for segment: TranscriptSegment, in snapshot: Snapshot) -> Int? {
        guard snapshot.placedUntil >= segment.end else { return nil }
        // A window around the line keeps this cheap late in a long call; the nearest voice is never far.
        let near = snapshot.spans.filter { $0.end > segment.start - 30 && $0.start < segment.end + 30 }
        let speakers = MeetingPostProcessor.speakers(for: segment, spans: near.isEmpty ? snapshot.spans : near)
        var counts: [Int: Int] = [:]
        for case let speaker? in speakers { counts[speaker, default: 0] += 1 }
        // Ties go to whoever spoke first in the line.
        return speakers.compactMap { $0 }.first { counts[$0] == counts.values.max() }
    }

    private func ready(_ diarizer: Nemotron3Diarizer) {
        guard !stopped else { return }
        log("live speakers ready")
        self.diarizer = diarizer
        builder = LiveSpanBuilder(origin: waitingStart)
        diarizer.appendAudio(waiting)
        waiting = []
        run()
    }

    private func run() {
        guard let diarizer, var builder else { return }
        let results: [Nemotron3ChunkResult]
        do { results = try diarizer.processBufferedAudio() } catch {
            log("live speakers stopped: \(error.localizedDescription)")
            self.diarizer = nil
            return
        }
        guard !results.isEmpty else { return }
        var finished: [DiarizedSpan] = []
        for result in results {
            finished += builder.add(result.probabilities, frameCount: result.frameCount, speakers: result.numSpeakers)
        }
        self.builder = builder
        for span in finished { collect(span, among: builder.spans) }
        emit()
    }

    /// Keeps the stretches of `span` nobody else talked over, for its voice's voiceprint.
    private func collect(_ span: DiarizedSpan, among spans: [DiarizedSpan]) {
        let budget = Self.voiceprintSeconds.last ?? 20
        let have = Double(speech[span.speaker]?.count ?? 0) / MeetingAudio.sampleRate
        guard have < budget else { return }
        let others = spans.filter { $0.speaker != span.speaker && $0.end > span.start && $0.start < span.end }
            .sorted { $0.start < $1.start }
        var pieces: [ClosedRange<Double>] = []
        var cursor = span.start
        for other in others {
            if other.start - cursor >= VoiceStretches.shortestPiece { pieces.append(cursor...other.start) }
            cursor = max(cursor, other.end)
        }
        if span.end - cursor >= VoiceStretches.shortestPiece { pieces.append(cursor...span.end) }
        for piece in pieces {
            let start = Int((piece.lowerBound - recentStart) * MeetingAudio.sampleRate)
            let end = Int((piece.upperBound - recentStart) * MeetingAudio.sampleRate)
            guard start >= 0, end <= recent.count, end > start else { continue }
            speech[span.speaker, default: []] += recent[start..<end]
        }
        let seconds = Double(speech[span.speaker]?.count ?? 0) / MeetingAudio.sampleRate
        let made = printsMade[span.speaker] ?? 0
        if made < Self.voiceprintSeconds.count, seconds >= Self.voiceprintSeconds[made] {
            printsMade[span.speaker] = made + 1
            name(span.speaker, from: speech[span.speaker] ?? [], seconds: seconds, heardBy: span.end)
        }
    }

    /// Matches a voice against People with the after-call rules; a name, once given, stays unless someone else wins.
    private func name(_ slot: Int, from samples: [Float], seconds: Double, heardBy: Double) {
        guard let voices, voices.enabled() else { return }
        namingNow += 1
        Task.detached(priority: .utility) { [self] in
            var match: MeetingVoices.Match?
            do {
                let embedding = try await voices.embed(samples)
                let voice = MeetingVoice(label: "\(slot)", track: .system, seconds: seconds, clipStart: 0, clipEnd: 0,
                                         embedding: embedding)
                let people = voices.people.people().map { person in
                    var person = person
                    person.samples.removeAll { $0.meetingID == excludingMeeting }
                    return person
                }
                match = VoiceMatching.match([voice], people: people, participants: MeetingParticipants(), inPerson: false)["\(slot)"]
                log(String(format: "live voiceprint: voice %d, %.0f s of speech by %.0f s: %@", slot, seconds, heardBy,
                           match.map { String(format: "%@ %.2f%@", $0.name, $0.similarity, $0.named ? "" : " (not named)") } ?? "nobody close"))
            } catch {
                log("live voiceprint: \(error.localizedDescription)")
            }
            let found = match
            queue.async { [self] in
                namingNow -= 1
                guard !stopped, let match = found, match.named else { return }
                namedFrom[match.name] = min(namedFrom[match.name] ?? heardBy, heardBy)
                guard seconds >= appliedSeconds[slot] ?? 0, named[slot] != match.name else { return }
                appliedSeconds[slot] = seconds
                named[slot] = match.name
                emit()
            }
        }
    }

    private func emit() {
        guard let builder else { return }
        var names: [Int: String] = [:]
        for (index, slot) in builder.arrival.enumerated() { names[slot] = named[slot] ?? "Speaker \(index + 1)" }
        onUpdate(Snapshot(placedUntil: builder.placedUntil, spans: builder.spans, names: names))
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
    /// How the live names came out on a recorded call, line by line, next to the names the after-call pass gave.
    public struct Replay: Codable, Sendable {
        public struct Line: Codable, Sendable {
            public var start: Double
            public var live: String
            public var afterCall: String
            public var text: String
        }

        public var callSeconds: Double
        public var replaySeconds: Double
        /// Each name the live speakers gave from People, and how far into the call the speech that named it ended:
        /// live, the name shows a voiceprint's time (well under a second) and the model's 2.9 s after that.
        public var namedAt: [String: Double]
        /// Lines whose live voice is the after-call voice that voice was most often: whether one voice stayed one voice.
        public var sameVoiceShare: Double
        /// Lines named from People live that have that name after the call too.
        public var namedRight: Int
        public var namedWrong: Int
        public var lines: [Line]
    }

    /// Plays a processed call's track through the live speakers as fast as they run, then places its live lines.
    public static func replay(_ directory: URL, voices: MeetingVoiceOptions?,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Replay {
        let samples = try WAVFile.readSamples(directory.appendingPathComponent("\(MeetingTrack.system.fileStem).wav"))
        let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
            .filter { $0.track == .system }
        let turns = try JSONDecoder.meeting.decode([TranscriptTurn].self,
                                                   from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.transcriptFile)))
            .filter { $0.track == .system }
        let latest = Mutex<Snapshot?>(nil)
        let live = LiveSpeakers(voices: voices, excludingMeeting: directory.lastPathComponent, log: log) { snapshot in
            latest.withLock { $0 = snapshot }
        }
        let began = Date()
        live.start()
        // The model first, so none of the call waits past what a live call would hold.
        while await live.onQueue({ $0.diarizer == nil && !$0.stopped }) {
            if Date().timeIntervalSince(began) > 600 { throw ReplayError("The live speaker model didn't load.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        let step = Int(MeetingAudio.sampleRate / 2)
        for start in stride(from: 0, to: samples.count, by: step) {
            live.append(Array(samples[start..<min(samples.count, start + step)]))
        }
        while await live.onQueue({ $0.namingNow > 0 || !$0.waiting.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        let replaySeconds = Date().timeIntervalSince(began)
        let namedAt = await live.onQueue { $0.namedFrom }
        live.stop()

        guard let snapshot = latest.withLock({ $0 }) else { throw ReplayError("The live speaker model placed nothing.") }
        let lines = segments.map { segment in
            let voice = voice(for: segment, in: snapshot)
            let afterCall = turns.max { overlap($0, segment) < overlap($1, segment) }.map(\.speaker) ?? "?"
            return (voice, Replay.Line(start: segment.start, live: voice.flatMap { snapshot.names[$0] } ?? "Them", afterCall: afterCall,
                                text: segment.text))
        }
        var mostOften: [Int: String] = [:]
        for voice in Set(lines.compactMap { $0.0 }) {
            let theirs = lines.filter { $0.0 == voice }.map { $0.1.afterCall }
            mostOften[voice] = Dictionary(grouping: theirs, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        }
        let same = lines.filter { $0.0.map { mostOften[$0] } == $0.1.afterCall }.count
        let named = lines.map { $0.1 }.filter { !MeetingTimeline.isUnnamed($0.live) && $0.live != "Them" }
        return Replay(callSeconds: Double(samples.count) / MeetingAudio.sampleRate, replaySeconds: replaySeconds,
                      namedAt: namedAt, sameVoiceShare: lines.isEmpty ? 0 : Double(same) / Double(lines.count),
                      namedRight: named.filter { $0.live == $0.afterCall }.count,
                      namedWrong: named.filter { $0.live != $0.afterCall }.count, lines: lines.map { $0.1 })
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
