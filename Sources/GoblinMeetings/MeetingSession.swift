import Foundation
import GoblinEngines

/// A call recorded from the call app and the mic, or a conversation in the room recorded from the mic alone.
public enum MeetingKind: String, Codable, Sendable { case call, inPerson }

public struct MeetingSessionInfo: Codable, Sendable {
    public var title: String
    /// Nil in sessions recorded before in-person recording existed, which were all calls.
    public var kind: MeetingKind?
    public var source: String
    public var target: String
    public var startedAt: Date
    public var endedAt: Date?
    public var microphone: TrackStats?
    public var system: TrackStats?
    public var systemFormat: String?
    public var maximumBacklog = 0
    public var decodeMilliseconds: [Double] = []
    /// Which speech model the live transcript used, and whether it was the one dictation had loaded.
    public var speechModel: String?
    /// Dictation takes during the meeting, and the longest one waited behind a meeting chunk.
    public var dictationTakes: Int?
    public var dictationMaximumWaitMilliseconds: Double?
    /// Why recording stopped: "stopped", "call ended", "sleep", "quit".
    public var stopReason: String?
    /// Seconds into the recording when the call app let go of the mic, for a recording that then stopped by itself.
    /// The transcript ends there: the countdown after a call only hears the room.
    public var callEndedAt: Double?
    /// Chunks still waiting for the speech model when the session closed; only a quit leaves any.
    public var untranscribedChunks: Int?
    /// Seconds of speech the live transcript left for after the call (deferred.jsonl): it fell behind, or the speech
    /// model couldn't run.
    public var deferredSeconds: Double?
    /// The recognition language the transcript asks for; nil lets the model detect it.
    public var language: String?

    public init(title: String, source: String, target: String, startedAt: Date) {
        self.title = title
        self.source = source
        self.target = target
        self.startedAt = startedAt
    }
}

extension JSONDecoder {
    public static var meetingDates: JSONDecoder { meeting }
    static var meeting: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// What a recording reports while it runs, for the controller to say.
public enum MeetingSessionProblem: Sendable, Equatable {
    case capture(MeetingCaptureProblem)
    /// A chunk was left for after the call.
    case transcriptDeferred(DeferralReason)
    /// A file of the recording couldn't be written, such as on a full disk: the recording should stop. What was
    /// written before it stays.
    case writeFailed(String)
}

/// One recording: the microphone and system tracks, their live transcript, and the session file.
public final class MeetingSession: @unchecked Sendable {
    public let directory: URL
    /// Chunks held in memory for the live transcript before the rest waits for after the call: about ten minutes of
    /// speech at the chunker's longest cut.
    public static let maximumBacklog = 60

    private let target: SystemAudioTarget
    private let recordMicrophone: Bool
    private let cancelsEchoLive: Bool
    /// Where the meeting mic preference and dictation's ranking are read.
    private let defaults: UserDefaults
    private let engine: any PCMSpeechEngine
    private let recognition: RecognitionOptions
    private let lock = NSLock()
    private var info: MeetingSessionInfo
    private var microphone: TrackRecorder?
    private var system: TrackRecorder?
    private var echo: LiveEchoCanceller?
    private var microphoneCapture: (any MeetingAudioSource)?
    private var tap: (any MeetingAudioSource)?
    private var transcriber: MeetingTranscriber?
    private let segmentsFile: FileHandle
    private let eventsFile: FileHandle
    private var dictationsFile: FileHandle?
    private var deferredFile: FileHandle?
    private var closed = false
    /// Set before a quit abandons the queue, so a chunk decoded after that is left to deferred.jsonl alone.
    private var segmentsClosed = false
    /// The first write that failed: the session's files take nothing after it.
    private var writeFailure: String?
    private let onSegment: @Sendable (TranscriptSegment) -> Void
    private let liveSpeakers: LiveSpeakers?
    private let onEvent: @Sendable (String) -> Void
    private let onProblem: @Sendable (MeetingSessionProblem) -> Void

    /// `recognition` is passed to the speech engine for every chunk: dictation's language, as Parakeet takes it.
    /// `onProblem` hears capture dropping out or coming back, and the live transcript falling behind. `liveSpeakers`
    /// hears the call's track, to tell its voices apart as it records. With `cancelsEchoLive`, a call's microphone has
    /// the call's sound taken out before the live transcript hears it, once the echo canceller is downloaded.
    public init(title: String, source: String, target: SystemAudioTarget, recordMicrophone: Bool = true,
                cancelsEchoLive: Bool = false,
                engine: any PCMSpeechEngine, recognition: RecognitionOptions = .init(language: "en"),
                root: URL = MeetingStorage.root, defaults: UserDefaults = .standard, liveSpeakers: LiveSpeakers? = nil,
                onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                onEvent: @escaping @Sendable (String) -> Void,
                onProblem: @escaping @Sendable (MeetingSessionProblem) -> Void = { _ in }) throws {
        let now = Date()
        directory = try MeetingStorage.newDirectory(title: title, date: now, in: root)
        self.target = target
        self.recordMicrophone = recordMicrophone
        self.cancelsEchoLive = cancelsEchoLive
        self.defaults = defaults
        self.engine = engine
        self.recognition = recognition
        self.onSegment = onSegment
        self.liveSpeakers = target == .none ? nil : liveSpeakers
        self.onEvent = onEvent
        self.onProblem = onProblem
        info = MeetingSessionInfo(title: title, source: source, target: target.description, startedAt: now)
        info.kind = target == .none ? .inPerson : .call
        info.language = recognition.language
        let segmentsURL = directory.appendingPathComponent("segments.jsonl")
        let eventsURL = directory.appendingPathComponent("events.log")
        FileManager.default.createFile(atPath: segmentsURL.path, contents: nil)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        segmentsFile = try FileHandle(forWritingTo: segmentsURL)
        eventsFile = try FileHandle(forWritingTo: eventsURL)
    }

    public var levels: (microphone: Float, system: Float) {
        lock.withLock { (microphone?.level ?? -100, system?.level ?? -100) }
    }

    public var startedAt: Date { lock.withLock { info.startedAt } }

    /// The mic being recorded, and why; nil before capture starts or while none is open.
    public var microphoneInUse: MeetingMicrophone? { (lock.withLock { microphoneCapture } as? MicrophoneCapture)?.inUse }

    /// What capture can't hear right now. Read afresh on every check rather than kept from `onProblem`, whose reports
    /// during an offer's handover can land before the recording is there to show them.
    public var captureTrouble: (microphoneLost: Bool, microphoneSilence: InputSilence?, systemAudioLost: Bool) {
        let (microphone, tap) = lock.withLock { (self.microphoneCapture as? MicrophoneCapture, self.tap as? SystemAudioTap) }
        return (microphone?.isLost ?? false, microphone?.silent, tap?.isLost ?? false)
    }

    public var backlog: Int { lock.withLock { transcriber?.backlog ?? 0 } }

    public var title: String { lock.withLock { info.title } }

    /// Changes the session file's fields, such as the stop reason, before `stop` writes it.
    public func annotate(_ change: (inout MeetingSessionInfo) -> Void) {
        lock.withLock { change(&info) }
    }

    /// Adds a line to the session's events log.
    public func note(_ message: String) { log(message) }

    /// A gob.lin dictation made during the meeting, so the transcript can leave out what the mic heard of it.
    /// Written to `dictations.jsonl` as seconds from the session start: `{"start": 12.3, "end": 15.9}`.
    public func recordDictation(start: Date, end: Date) {
        let startedAt = self.startedAt
        let line: [String: Double] = ["start": start.timeIntervalSince(startedAt), "end": end.timeIntervalSince(startedAt)]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lock.withLock {
            guard !closed else { return }
            if dictationsFile == nil {
                let url = directory.appendingPathComponent(MeetingStorage.liveDictationsFile)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                dictationsFile = try? FileHandle(forWritingTo: url)
            }
            append(data + Data([0x0A]), to: dictationsFile)
        }
    }

    /// Starts capture and the live transcript. With `offer`, the call heard since it was offered comes first: the
    /// timeline starts at its first buffered sample (`startedAt` moves back with it), the buffered audio goes through
    /// the same recorders as live audio, and the offer's running captures carry on into them with nothing lost or
    /// repeated. A track the offer couldn't capture is started here.
    public func start(handingOver offer: OfferBuffer? = nil) async throws {
        let heard = await offer?.freeze()
        let hostNow = HostClock.now, now = Date()
        let hostStart = heard?.firstHost ?? hostNow
        let started = now.addingTimeInterval(hostStart - hostNow)
        // Before the transcriber exists: a model dictation already loaded is ready at once, and that line comes after.
        log("preparing speech model")
        let transcriber = MeetingTranscriber(engine: engine, options: recognition, maximumBacklog: Self.maximumBacklog,
                                             onSegment: { [weak self] segment in self?.record(segment) },
                                             onError: { [weak self] message in self?.log(message) },
                                             onDeferred: { [weak self] chunk, reason in self?.leaveForLater(chunk, reason) },
                                             onReady: { [weak self] in self?.log("speech model ready") })
        let event: @Sendable (String) -> Void = { [weak self] message in self?.log(message) }
        let problem: @Sendable (MeetingCaptureProblem) -> Void = { [weak self] problem in
            self?.log("capture: \(problem)")
            self?.onProblem(.capture(problem))
        }
        let writeFailed: @Sendable (any Error) -> Void = { [weak self] error in
            guard let self else { return }
            lock.withLock { failWrite(error) }
        }
        // An in-person conversation has no call audio: no tap and no system track.
        let inPerson = target == .none
        let submit: @Sendable (SpeechChunk) -> Void = { transcriber.submit($0) }
        let echo = cancelsEchoLive && !inPerson ? LiveEchoCanceller(load: LiveEchoCanceller.localVQE, log: event, onChunk: submit) : nil
        let microphoneSamples: @Sendable ([Float]) -> Void = { echo?.microphone($0) }
        let microphone = try TrackRecorder(track: .microphone, directory: directory, sessionStart: hostStart,
                                           onChunk: echo == nil ? submit : nil, onSamples: microphoneSamples,
                                           onEvent: event, onWriteFailure: writeFailed)
        let onSystemSamples: @Sendable ([Float]) -> Void = { [liveSpeakers] samples in
            liveSpeakers?.append(samples)
            echo?.system(samples)
        }
        let system = inPerson ? nil : try TrackRecorder(track: .system, directory: directory, sessionStart: hostStart,
                                                        onChunk: submit,
                                                        onSamples: onSystemSamples, onEvent: event,
                                                        onWriteFailure: writeFailed)
        let microphoneCapture: any MeetingAudioSource = heard?.microphone ?? MicrophoneCapture(call: target, defaults: defaults)
        let tap: (any MeetingAudioSource)? = inPerson ? nil : heard?.system ?? SystemAudioTap(target: target)
        lock.withLock {
            info.startedAt = started
            self.transcriber = transcriber
            self.microphone = microphone
            self.system = system
            self.echo = echo
            self.microphoneCapture = microphoneCapture
            self.tap = tap
        }
        if let tap, let system, heard?.system == nil {
            try tap.start(onEvent: event, onProblem: problem) { system.append($0) }
        }
        if let tap = tap as? SystemAudioTap { lock.withLock { info.systemFormat = tap.formatDescription } }
        // A mic heard since the offer is running already.
        if heard?.microphone == nil {
            if inPerson {
                // Without the mic there is nothing to record.
                try microphoneCapture.start(onEvent: event, onProblem: problem) { microphone.append($0) }
            } else if recordMicrophone { do {
                try microphoneCapture.start(onEvent: event, onProblem: problem) { microphone.append($0) }
            } catch {
                log("microphone unavailable, recording system audio only: \(error.localizedDescription)")
            } }
        }
        if let offer, heard != nil {
            let handed = offer.handOver(microphone: { microphone.append($0) }, system: { system?.append($0) },
                                        onEvent: { [weak self] date, message in self?.log(message, at: date) }, onProblem: problem)
            if handed { log(String(format: "included %.1f s heard before acceptance", hostNow - hostStart)) }
        }
        // Capture is already running; chunks wait in the transcriber's queue while it loads the model.
        saveInfo()
    }

    /// Stops capture and closes both tracks at once, then waits for the live transcript to catch up. With a
    /// `transcriptDeadline` (a quit), chunks still queued at the deadline are left out and counted instead.
    public func stop(transcriptDeadline: Duration? = nil) async -> MeetingSessionInfo {
        let (tap, microphoneCapture, microphone, system, echo, transcriber) = lock.withLock {
            (self.tap, self.microphoneCapture, self.microphone, self.system, self.echo, self.transcriber)
        }
        tap?.stop()
        microphoneCapture?.stop()
        let microphoneStats = microphone?.finish()
        let systemStats = system?.finish()
        // The microphone's last chunks, once the canceller has had all of both tracks.
        await echo?.finish()
        lock.withLock {
            info.endedAt = Date()
            info.microphone = microphoneStats
            info.system = systemStats
        }
        // The audio is complete on disk before the transcript catches up, so a sleep or a quit here loses nothing.
        saveInfo()
        log("capture stopped; finishing \(transcriber?.backlog ?? 0) queued chunks")
        if let transcriber {
            if let transcriptDeadline {
                // The worker can't be cancelled mid-chunk, so the deadline races it rather than waiting for it.
                let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let answered = NSLock()
                    nonisolated(unsafe) var done = false
                    let answer: @Sendable (Bool) -> Void = { value in
                        let first = answered.withLock { () -> Bool in defer { done = true }; return !done }
                        if first { continuation.resume(returning: value) }
                    }
                    Task { await transcriber.finish(); answer(true) }
                    Task { try? await Task.sleep(for: transcriptDeadline); answer(false) }
                }
                if !finished { leaveQueuedForLater() }
            } else {
                await transcriber.finish()
            }
        }
        // The last lines have their captions; the after-call pass decides who said them, with its own model.
        liveSpeakers?.stop()
        saveInfo()
        lock.withLock {
            closed = true
            try? segmentsFile.close()
            try? dictationsFile?.close()
            try? deferredFile?.close()
            try? eventsFile.close()
        }
        return lock.withLock { info }
    }

    /// Stops the live transcript where it is and writes what's still queued to deferred.jsonl, to be transcribed from
    /// the audio when the meeting is processed. A quit's deadline does this; a quit during a Stop that is still waiting
    /// on the transcript (or on the speech model's download) calls it too, so nothing queued is lost when the app goes.
    public func leaveQueuedForLater() {
        // One hold of the lock from abandoning the queue to the last descriptor written: a Stop already waiting on
        // the transcript can't close deferred.jsonl partway through.
        let left = lock.withLock { () -> Int? in
            guard !closed, !segmentsClosed, let transcriber else { return nil }
            segmentsClosed = true
            let left = transcriber.abandon()
            for chunk in left { writeDeferred(chunk) }
            info.untranscribedChunks = left.count
            return left.count
        }
        guard let left else { return }
        log("closed with \(left) chunks left for processing")
        saveInfo()
    }

    /// Writes a chunk the live transcript won't get to into deferred.jsonl, for processing to transcribe later.
    private func leaveForLater(_ chunk: DeferredChunk, _ reason: DeferralReason) {
        let first = lock.withLock { () -> Bool in
            let first = info.deferredSeconds == nil
            return writeDeferred(chunk) && first
        }
        if first { log("live transcript left a chunk for after the call: \(reason)") }
        onProblem(.transcriptDeferred(reason))
    }

    /// Appends a chunk's descriptor to deferred.jsonl. Call with the lock held.
    @discardableResult
    private func writeDeferred(_ chunk: DeferredChunk) -> Bool {
        guard !closed, let data = try? JSONEncoder().encode(chunk) else { return false }
        if deferredFile == nil {
            let url = directory.appendingPathComponent(MeetingStorage.deferredFile)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            deferredFile = try? FileHandle(forWritingTo: url)
        }
        append(data + Data([0x0A]), to: deferredFile)
        info.deferredSeconds = (info.deferredSeconds ?? 0) + chunk.seconds
        return true
    }

    private func record(_ segment: TranscriptSegment) {
        var segment = segment
        segment.emittedAt = Date().timeIntervalSince(startedAt)
        lock.withLock {
            let backlog = transcriber?.backlog ?? 0
            info.maximumBacklog = max(info.maximumBacklog, backlog)
            info.decodeMilliseconds.append(segment.decodeMilliseconds)
            if !closed, !segmentsClosed, let data = try? JSONEncoder().encode(segment) {
                append(data + Data([0x0A]), to: segmentsFile)
            }
        }
        onSegment(segment)
    }

    private func log(_ message: String, at date: Date = Date()) {
        let line = "\(ISO8601DateFormatter().string(from: date)) \(message)\n"
        lock.withLock { if !closed { append(Data(line.utf8), to: eventsFile) } }
        onEvent(message)
    }

    /// Appends to one of the session's files. Call with the lock held. A full disk throws here, rather than raising
    /// and ending the app.
    private func append(_ data: Data, to handle: FileHandle?) {
        guard let handle, writeFailure == nil else { return }
        do { try handle.write(contentsOf: data) } catch { failWrite(error) }
    }

    /// Reports the first failed write, once. Call with the lock held; the events log isn't written, as it failed too.
    private func failWrite(_ error: any Error) {
        guard writeFailure == nil else { return }
        writeFailure = error.localizedDescription
        onProblem(.writeFailed(error.localizedDescription))
    }

    private func saveInfo() {
        // Whole or not at all: a half-written session.json would hide the meeting's start, end and kind. Written under
        // the lock, so an older copy (a Stop's, during a quit's) never lands after a newer one.
        lock.withLock {
            try? JSONEncoder.pretty.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile), options: .atomic)
        }
    }
}
