import Foundation
import GoblinEngines
import Synchronization
import Testing
@testable import GoblinMeetings

/// An engine that decodes nothing until released, so chunks pile up behind the first.
private final class StuckEngine: PCMSpeechEngine, @unchecked Sendable {
    let identifier = "stuck"
    let maximumWindowSamples = 16_000 * 30
    private let released = Mutex(false)

    func prepare() async throws {}
    func unload() async {}
    func release() { released.withLock { $0 = true } }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { TranscriptionResult(text: "") }

    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        return TranscriptionResult(text: "")
    }
}

/// An engine with no model: every chunk fails, as offline without a downloaded Parakeet.
private struct OfflineEngine: PCMSpeechEngine {
    struct Offline: Error, LocalizedError { var errorDescription: String? { "The Internet connection appears to be offline." } }
    let identifier = "offline"
    let maximumWindowSamples = 16_000 * 30
    func prepare() async throws { throw Offline() }
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { throw Offline() }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult { throw Offline() }
}

/// Loads, then fails on every chunk.
private struct BrokenEngine: PCMSpeechEngine {
    let identifier = "broken"
    let maximumWindowSamples = 16_000 * 30
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { throw OfflineEngine.Offline() }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult { throw OfflineEngine.Offline() }
}

private func chunk(_ track: MeetingTrack, at second: Double, seconds: Double = 1) -> SpeechChunk {
    SpeechChunk(track: track, startSample: Int(second * MeetingAudio.sampleRate),
                samples: [Float](repeating: 0.1, count: Int(seconds * MeetingAudio.sampleRate)))
}

@Test func aFullQueueLeavesChunksForAfterTheCall() async throws {
    let engine = StuckEngine()
    let deferred = Mutex<[(DeferredChunk, DeferralReason)]>([])
    let transcriber = MeetingTranscriber(engine: engine, maximumBacklog: 2, onSegment: { _ in }, onError: { _ in },
                                         onDeferred: { chunk, reason in deferred.withLock { $0.append((chunk, reason)) } })
    for second in 0..<4 { transcriber.submit(chunk(.system, at: Double(second))) }
    #expect(transcriber.backlog == 2)
    let behind = deferred.withLock { $0 }
    #expect(behind.map(\.0.startSample) == [32_000, 48_000])
    #expect(behind.allSatisfy { $0.1 == .behind })
    engine.release()
    await transcriber.finish()
    #expect(transcriber.backlog == 0)
}

@Test func chunksTheModelFailsOnAreLeftWithTheReason() async throws {
    let deferred = Mutex<[(DeferredChunk, DeferralReason)]>([])
    let transcriber = MeetingTranscriber(engine: OfflineEngine(), onSegment: { _ in Issue.record("nothing is transcribed") },
                                         onError: { _ in },
                                         onDeferred: { chunk, reason in deferred.withLock { $0.append((chunk, reason)) } })
    transcriber.submit(chunk(.microphone, at: 2))
    transcriber.submit(chunk(.system, at: 3))
    await transcriber.finish()
    let failed = deferred.withLock { $0 }
    #expect(failed.map(\.0) == [DeferredChunk(track: .microphone, startSample: 32_000, sampleCount: 16_000),
                                DeferredChunk(track: .system, startSample: 48_000, sampleCount: 16_000)])
    #expect(failed.allSatisfy { $0.1 == .failed("The Internet connection appears to be offline.") })
}

@Test func abandoningHandsBackWhatsStillQueued() async throws {
    let engine = StuckEngine()
    let transcriber = MeetingTranscriber(engine: engine, onSegment: { _ in }, onError: { _ in })
    for second in 0..<3 { transcriber.submit(chunk(.system, at: Double(second))) }
    try await Task.sleep(for: .milliseconds(30))
    let left = transcriber.abandon()
    #expect(left.map(\.startSample) == [0, 16_000, 32_000])
    #expect(transcriber.backlog == 0)
    engine.release()
    await transcriber.finish()
}

/// A meeting whose live transcript left one mic chunk (2–3 s) for after the call.
private func meetingWithDeferredSpeech(in root: URL) throws -> URL {
    let directory = try Fixtures.meeting(in: root, name: "deferred", seconds: 6, segments: [Fixtures.segment(.system, "hello there", at: 0.5)])
    try (String(decoding: try JSONEncoder().encode(DeferredChunk(track: .microphone, startSample: 32_000, sampleCount: 16_000)), as: UTF8.self) + "\n")
        .write(to: directory.appendingPathComponent(MeetingStorage.deferredFile), atomically: true, encoding: .utf8)
    return directory
}

@Test func deferredSpeechIsTranscribedFromTheAudioWhenTheMeetingIsProcessed() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try meetingWithDeferredSpeech(in: root)
    var options = Fixtures.options(spans: [])
    let asked = Mutex<[(MeetingTrack, Int, Int, String?)]>([])
    options.transcribeLater = { chunks, recognition in
        asked.withLock { $0 += chunks.map { ($0.track, $0.startSample, $0.samples.count, recognition.language) } }
        return try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition)
    }
    let store = MeetingStore(root: root, options: options)
    let turns = try await store.process(directory.lastPathComponent)
    #expect(asked.withLock { $0.map(\.0) } == [.microphone])
    #expect(asked.withLock { $0.map(\.1) } == [32_000])
    #expect(asked.withLock { $0.map(\.2) } == [16_000])
    #expect(turns.map(\.speaker) == ["Them", "You"])
    #expect(turns.last?.text == "alpha1 beta1")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.deferredFile).path))
    // Written into segments.jsonl, so processing again doesn't transcribe it twice.
    let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
    #expect(segments.map(\.text) == ["hello there", "alpha1 beta1"])
}

@Test func replayingDeferredSpeechAgainReplacesItsLinesRatherThanAddingThem() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try meetingWithDeferredSpeech(in: root)
    let deferredURL = directory.appendingPathComponent(MeetingStorage.deferredFile)
    let descriptors = try Data(contentsOf: deferredURL)
    var options = Fixtures.options(spans: [])
    options.transcribeLater = { chunks, recognition in try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition) }
    let store = MeetingStore(root: root, options: options)
    _ = try await store.process(directory.lastPathComponent)
    // A run cut off after segments.jsonl was written but before deferred.jsonl went.
    try descriptors.write(to: deferredURL)
    _ = try await store.process(directory.lastPathComponent)
    let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
    #expect(segments.map(\.text) == ["hello there", "alpha1 beta1"])
}

@Test func speechRecoveredFromDeferredChunksStaysWhenTheirAudioIsGone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try meetingWithDeferredSpeech(in: root)
    let id = directory.lastPathComponent
    let deferredURL = directory.appendingPathComponent(MeetingStorage.deferredFile)
    let descriptors = try Data(contentsOf: deferredURL)
    var options = Fixtures.options(spans: [])
    options.transcribeLater = { chunks, recognition in try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition) }
    _ = try await MeetingStore(root: root, options: options).process(id)

    // A run cut off before deferred.jsonl went, then the audio deleted before Try Again.
    try descriptors.write(to: deferredURL)
    let store = MeetingStore(root: root, options: Fixtures.options(spans: []))
    try await store.deleteAudio(id)
    let turns = try await store.process(id)
    #expect(turns.map(\.text).contains("alpha1 beta1"))
    let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
    #expect(segments.map(\.text) == ["hello there", "alpha1 beta1"])
    #expect(!FileManager.default.fileExists(atPath: deferredURL.path))
}

@Test func deferredSpeechThatCantBeTranscribedFailsTheMeetingUntilTryAgain() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try meetingWithDeferredSpeech(in: root)
    let id = directory.lastPathComponent

    // No speech model at all: not an empty "ready" transcript, but a failure that says what's missing.
    let bare = MeetingStore(root: root, options: Fixtures.options(spans: []))
    await #expect(throws: MeetingProcessingError.untranscribed(seconds: 1, reason: nil)) { try await bare.process(id) }
    #expect(try await bare.summary(id).state == .failed)

    // Offline: the reason comes through, and the chunk stays for the next try.
    var offline = Fixtures.options(spans: [])
    offline.transcribeLater = { chunks, recognition in try await MeetingTranscriber.transcribeAll(chunks, engine: OfflineEngine(), options: recognition) }
    let failing = MeetingStore(root: root, options: offline)
    await #expect(throws: MeetingProcessingError.self) { try await failing.process(id) }
    let failed = try await failing.summary(id)
    #expect(failed.state == .failed)
    #expect(failed.failure == "1 second of speech still needs the speech model, which couldn't run: The Internet connection appears to be offline.")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.deferredFile).path))

    var online = Fixtures.options(spans: [])
    online.transcribeLater = { chunks, recognition in try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition) }
    let working = MeetingStore(root: root, options: online)
    let turns = try await working.process(id)
    #expect(turns.map(\.text).contains("alpha1 beta1"))
    #expect(try await working.summary(id).state == .ready)
}

@Test func theMeetingsLanguageGoesToTheSpeechModel() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try meetingWithDeferredSpeech(in: root)
    let url = directory.appendingPathComponent(MeetingStorage.sessionFile)
    var info = try JSONDecoder.meetingDates.decode(MeetingSessionInfo.self, from: Data(contentsOf: url))
    info.language = "de"
    try JSONEncoder.pretty.encode(info).write(to: url)
    var options = Fixtures.options(spans: [])
    let languages = Mutex<[String?]>([])
    options.transcribeLater = { chunks, recognition in
        languages.withLock { $0.append(recognition.language) }
        return []
    }
    _ = try await MeetingStore(root: root, options: options).process(directory.lastPathComponent)
    #expect(languages.withLock { $0 } == ["de"])
}

@Test func aShortEchoSimulationDoesntCrash() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("short.wav")
    // 20 ms: shorter than the simulated 40 ms echo delay.
    try Fixtures.writeWAV([Float](repeating: 0.2, count: 320), to: system)
    let directory = try await MeetingSimulator.run(system: system, microphone: nil, echoGain: 0.5, engine: ScriptedEngine(),
                                                   title: "Short", root: root.appendingPathComponent("Meetings")) { _ in }
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.sessionFile).path))
}

@Test func aSimulationWhoseChunksFailSaysSoRatherThanReportingATranscript() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("speech.wav")
    try Fixtures.writeWAV([Float](repeating: 0.2, count: 16_000), to: system)
    await #expect(throws: MeetingProcessingError.self) {
        try await MeetingSimulator.run(system: system, microphone: nil, echoGain: 0, engine: BrokenEngine(),
                                       title: "Broken", root: root.appendingPathComponent("Meetings")) { _ in }
    }
}
