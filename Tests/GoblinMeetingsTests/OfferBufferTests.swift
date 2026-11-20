import Foundation
import GoblinEngines
import Testing
@testable import GoblinMeetings

// MARK: Fakes

/// A capture that delivers only what the test hands it. `inFlight` delivers through the handler it was started with
/// even after `stop`, as a real capture's callback can when it was already running.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedBuffer) -> Void)?
    private var started: (@Sendable (CapturedBuffer) -> Void)?
    private var counts = (starts: 0, stops: 0)

    var starts: Int { lock.withLock { counts.starts } }
    var stops: Int { lock.withLock { counts.stops } }
    var running: Bool { lock.withLock { handler != nil } }

    func start(onEvent: @escaping @Sendable (String) -> Void, onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void,
               handler: @escaping @Sendable (CapturedBuffer) -> Void) throws {
        lock.withLock { self.handler = handler; started = handler; counts.starts += 1 }
        onEvent("fake capture started")
    }

    func stop() { lock.withLock { handler = nil; counts.stops += 1 } }

    func deliver(_ buffer: CapturedBuffer) { lock.withLock { handler }?(buffer) }

    func inFlight(_ buffer: CapturedBuffer) { lock.withLock { started }?(buffer) }
}

/// The scripted engine, counting how often it was asked to load.
private final class PreparingEngine: PCMSpeechEngine, @unchecked Sendable {
    let identifier = "preparing"
    let maximumWindowSamples = 16_000 * 30
    private let scripted = ScriptedEngine()
    private let counter = Counter()
    var prepares: Int { counter.value }

    /// Set, `prepare` waits here until it's cancelled, as one waiting on dictation's model would.
    var waits = false
    private let cancellations = Counter()
    var cancelled: Int { cancellations.value }

    func prepare() async throws {
        counter.increment()
        guard waits else { return }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        cancellations.increment()
    }
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { TranscriptionResult(text: "") }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        try await scripted.transcribe(samples: samples, options: options)
    }
}

/// Buffer `n` of a track: `count` samples at 16 kHz, all the same level, so the files show which buffer went where.
private func buffer(_ n: Int, host: Double, count: Int = 2_000) -> CapturedBuffer {
    CapturedBuffer(samples: [Float](repeating: level(n), count: count), sampleRate: MeetingAudio.sampleRate, hostSeconds: host)
}

private func level(_ n: Int) -> Float { Float(n % 200 + 20) / 256 }

/// What `level(n)` reads back as from a track's WAV.
private func stored(_ n: Int) -> Float { Float(Int16(level(n) * 32_767)) / 32_768 }

// MARK: Offers

@Test func anOfferKeepsTheNewestTwoMinutesOfEachTrack() async {
    let microphone = FakeSource(), system = FakeSource()
    let offer = OfferBuffer(microphone: microphone, system: system, probe: nil, engine: nil)
    offer.start()
    await offer.whenStarted()
    // 130 one-second buffers on each track: the first ten go, oldest first.
    for n in 0..<130 {
        microphone.deliver(buffer(n, host: 1_000 + Double(n), count: 16_000))
        system.deliver(buffer(n, host: 1_000 + Double(n), count: 16_000))
    }
    for track in MeetingTrack.allCases {
        #expect(offer.heldSeconds(track) == OfferBuffer.maximumSeconds)
        #expect(offer.held(track).first?.hostSeconds == 1_010)
        #expect(offer.held(track).first?.samples.first == level(10))
        #expect(offer.held(track).last?.hostSeconds == 1_129)
    }
    offer.discard()
}

@Test func aDiscardedOfferStopsListeningAndKeepsNothing() async {
    let microphone = FakeSource(), system = FakeSource()
    let probe = AccessibilityProbe(pid: 1, scope: .nothing, readsCallState: true, directory: nil, sessionStart: Date())
    let offer = OfferBuffer(microphone: microphone, system: system, probe: probe, engine: PreparingEngine())
    offer.start()
    await offer.whenStarted()
    #expect(microphone.running && system.running)
    for n in 0..<40 {
        microphone.deliver(buffer(n, host: 1_000 + Double(n) * 0.125))
        system.deliver(buffer(n, host: 1_000 + Double(n) * 0.125))
    }
    probe.updateMute(true, at: Date())
    offer.noteDictation(start: Date().addingTimeInterval(-2), end: Date())
    #expect(offer.heldSeconds(.microphone) == 5)

    offer.discard()
    #expect(!microphone.running && !system.running)
    #expect(offer.held(.microphone).isEmpty && offer.held(.system).isEmpty)
    #expect(offer.dictations.isEmpty)
    #expect(offer.claimProbe(pid: 1) == nil)
    // A callback already under way when the capture stopped is dropped too.
    microphone.inFlight(buffer(40, host: 1_005))
    system.inFlight(buffer(40, host: 1_005))
    #expect(offer.held(.microphone).isEmpty && offer.held(.system).isEmpty)
    // Nothing to hand over: a recording that tried would start from nothing.
    #expect(await offer.freeze() == nil)
    let handed = offer.handOver(microphone: { _ in }, system: { _ in }, onEvent: { _, _ in }, onProblem: { _ in })
    #expect(!handed)
    offer.discard()
    #expect(microphone.stops == 1 && system.stops == 1)
}

@Test func anOfferNobodyHoldsStopsListening() async {
    let microphone = FakeSource(), system = FakeSource()
    do {
        let offer = OfferBuffer(microphone: microphone, system: system, probe: nil, engine: nil)
        offer.start()
        await offer.whenStarted()
        microphone.deliver(buffer(0, host: 1_000))
        #expect(microphone.running)
    }
    #expect(!microphone.running && !system.running)
}

@Test func anOfferStartsLoadingTheSpeechModel() async {
    let engine = PreparingEngine()
    let offer = OfferBuffer(microphone: FakeSource(), system: FakeSource(), probe: nil, engine: engine)
    #expect(engine.prepares == 0)
    offer.start()
    await offer.preparation?.value
    #expect(engine.prepares == 1)
    offer.discard()
}

/// A no reaches a load that hasn't begun: the engine checks for it before making a model of its own.
@Test func aDiscardedOfferCancelsALoadStillWaiting() async {
    let engine = PreparingEngine()
    engine.waits = true
    let offer = OfferBuffer(microphone: FakeSource(), system: FakeSource(), probe: nil, engine: engine)
    offer.start()
    let preparation = offer.preparation
    offer.discard()
    await preparation?.value
    #expect(engine.prepares == 1 && engine.cancelled == 1)
}

/// A track whose capture stopped delivering can't keep audio from before the window, or start the recording there.
@Test func aTrackThatStoppedArrivingExpiresWithTheOther() async {
    let microphone = FakeSource(), system = FakeSource()
    let offer = OfferBuffer(microphone: microphone, system: system, probe: nil, engine: nil)
    offer.start()
    await offer.whenStarted()
    // The microphone dies after ten seconds; the call's sound goes on for five minutes.
    for n in 0..<10 { microphone.deliver(buffer(n, host: 1_000 + Double(n), count: 16_000)) }
    for n in 0..<300 { system.deliver(buffer(n, host: 1_000 + Double(n), count: 16_000)) }
    #expect(offer.held(.microphone).isEmpty)
    #expect(offer.held(.system).first?.hostSeconds == 1_180 && offer.heldSeconds(.system) == OfferBuffer.maximumSeconds)
    // The recording would start where the newest two minutes do, not at the dead track's first sample.
    #expect(await offer.freeze()?.firstHost == 1_180)
    offer.discard()
}

/// A yes while both captures keep delivering from their own threads: each track's file is what was heard since the
/// offer and then everything live, in order, once each, on a timeline that starts at the first sample heard.
@Test func anAcceptedOfferRecordsFromItsFirstSampleWithoutAGapOrARepeat() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let microphone = FakeSource(), system = FakeSource()
    let offer = OfferBuffer(microphone: microphone, system: system, probe: nil, engine: nil)
    offer.start()
    await offer.whenStarted()
    // Whole seconds, so every buffer's time and the system track's lead are exact.
    let base = (HostClock.now - 30).rounded(.down)
    func host(_ n: Int) -> Double { base + Double(n) * 0.125 }
    // Five seconds heard before the yes; the call's sound starts 0.625 s after the mic.
    for n in 0..<40 { microphone.deliver(buffer(n, host: host(n))) }
    for n in 5..<40 { system.deliver(buffer(n, host: host(n))) }
    let last = 400
    let live = Task.detached {
        for n in 40..<last {
            microphone.deliver(buffer(n, host: host(n)))
            system.deliver(buffer(n, host: host(n)))
            usleep(1_000)
        }
    }
    let session = try MeetingSession(title: "Accepted", source: "Zoom", target: .app(bundleIDs: ["us.zoom.xos"], processes: []),
                                     engine: ScriptedEngine(), root: root, onSegment: { _ in }, onEvent: { _ in })
    // Frozen and holding both captures, so the session takes them over and never opens a real device.
    let heard = try #require(await offer.freeze())
    #expect(heard.microphone === microphone && heard.system === system)
    let acceptedAt = Date(), acceptedHost = HostClock.now
    try await session.start(handingOver: offer)
    // A dictation that ended while the recording was starting is still there for it to read.
    offer.noteDictation(start: acceptedAt, end: Date())
    #expect(offer.dictations.count == 1)
    offer.discard()
    #expect(offer.dictations.isEmpty)
    await live.value
    let info = await session.stop()

    // The recording starts at the first sample heard, not at the yes.
    let expectedStart = acceptedAt.addingTimeInterval(base - acceptedHost)
    #expect(abs(info.startedAt.timeIntervalSince(expectedStart)) < 0.1)
    let microphoneAudio = try WAVFile.readSamples(session.directory.appendingPathComponent(MeetingStorage.audioFile(.microphone)))
    let systemAudio = try WAVFile.readSamples(session.directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
    let expectedMicrophone = (0..<last).flatMap { [Float](repeating: stored($0), count: 2_000) }
    let expectedSystem = [Float](repeating: 0, count: 10_000) + (5..<last).flatMap { [Float](repeating: stored($0), count: 2_000) }
    #expect(microphoneAudio == expectedMicrophone)
    #expect(systemAudio == expectedSystem)
    #expect(info.microphone?.gaps.isEmpty == true && info.system?.gaps.isEmpty == true)
    #expect(info.microphone?.firstHostOffset == 0)
    #expect(info.system?.paddedLeadSeconds == 0.625)
    // Still running when stopped, so the session stopped them; the offer's discard after the hand-off didn't.
    #expect(microphone.stops == 1 && system.stops == 1)

    // The heard stretch was chunked and transcribed like live audio, from the start of the timeline.
    let segments = try String(contentsOf: session.directory.appendingPathComponent(MeetingStorage.segmentsFile), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8)) }
    #expect(segments.contains { $0.track == .microphone && $0.start < 5 })
    #expect(segments.contains { $0.track == .system && $0.start < 5 })
    let events = try String(contentsOf: session.directory.appendingPathComponent(MeetingStorage.eventsFile), encoding: .utf8)
    #expect(events.contains("fake capture started"))
    #expect(events.contains("s heard before acceptance"))
}

/// Mute changes read while the offer was up move onto the recording's clock, so the mic's words said while muted in
/// that stretch are left out like any others.
@Test func muteReadDuringAnOfferLandsOnTheRecordingsTimeline() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let offeredAt = Date(timeIntervalSince1970: 2_000_000)
    let probe = AccessibilityProbe(pid: 1, scope: .nothing, readsCallState: true, directory: nil, sessionStart: offeredAt)
    probe.updateMute(false, at: offeredAt.addingTimeInterval(1))
    probe.updateMute(true, at: offeredAt.addingTimeInterval(10))
    probe.updateMute(false, at: offeredAt.addingTimeInterval(20))
    probe.updateMute(true, at: offeredAt.addingTimeInterval(30))

    // The oldest 5 s of audio were dropped, so the recording's timeline starts 5 s after the offer.
    let start = offeredAt.addingTimeInterval(5)
    probe.attach(directory: directory, sessionStart: start, rawLog: true)
    probe.updateMute(false, at: start.addingTimeInterval(40))
    let muteURL = directory.appendingPathComponent(MeetingStorage.muteFile)
    let text = try String(contentsOf: muteURL, encoding: .utf8)
    #expect(text == "{\"t\":0.00,\"muted\":false}\n{\"t\":5.00,\"muted\":true}\n{\"t\":15.00,\"muted\":false}\n"
        + "{\"t\":25.00,\"muted\":true}\n{\"t\":40.00,\"muted\":false}\n")
    #expect(probe.muteTimeline == MuteTimeline(jsonl: text))
    // The raw log starts at the yes: nothing the window said during the offer is in it.
    #expect(try String(contentsOf: directory.appendingPathComponent(MeetingStorage.accessibilityFile), encoding: .utf8).isEmpty)

    // Live captions and the saved transcript use the same spans.
    let spans = MeetingPostProcessor.mutedSpans(muteURL, end: 60)
    #expect(spans == [5...15, 25...40])
    #expect(probe.muteTimeline.silences(Fixtures.segment(.microphone, "said while muted", at: 6)))
    #expect(!probe.muteTimeline.silences(Fixtures.segment(.system, "the other side", at: 6)))
    #expect(!probe.muteTimeline.silences(Fixtures.segment(.microphone, "said to the call", at: 16)))
    // Word by word across the unmute at 15 s: only what was said after it stays.
    let across = Fixtures.segment(.microphone, "one two three four five six", at: 12, step: 1)
    let (kept, silenced) = MeetingPostProcessor.removeMuted(across, spans: spans)
    #expect(silenced)
    #expect(kept?.text == "four five six")
}

@Test func aProbeForAnotherProcessIsNotHandedOver() {
    let probe = AccessibilityProbe(pid: 41, scope: .nothing, readsCallState: true, directory: nil, sessionStart: Date())
    let offer = OfferBuffer(microphone: nil, system: nil, probe: probe, engine: nil)
    #expect(offer.claimProbe(pid: 42) == nil)
    #expect(offer.claimProbe(pid: 41) === probe)
    #expect(offer.claimProbe(pid: 41) == nil)
}
