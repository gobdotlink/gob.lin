import Foundation
import GoblinEngines
import Synchronization
import Testing
@testable import GoblinMeetings

/// A tone wherever `ranges` say, silence elsewhere: the chunker only needs energy, and the scripted engine supplies words.
/// Plain loops over the ranges: a closure per sample is slow enough unoptimized to hold up other tests on a small machine.
private func tone(_ ranges: [ClosedRange<Double>], seconds: Double, frequency: Double = 220) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * MeetingAudio.sampleRate))
    for range in ranges {
        var index = max(0, Int(range.lowerBound * MeetingAudio.sampleRate) - 1)
        while index < samples.count {
            let time = Double(index) / MeetingAudio.sampleRate
            if time > range.upperBound { break }
            if time >= range.lowerBound { samples[index] = Float(sin(2 * .pi * frequency * time) * 0.3) }
            index += 1
        }
    }
    return samples
}

/// The other side of the 10 s call below: talking at 1–3 s and 6–8 s.
private let otherSide = tone([1.0...3.0, 6.0...8.0], seconds: 10)

/// What the person said into the microphone: one line at 4–5 s.
private let ownSpeech = tone([4.0...5.0], seconds: 10, frequency: 330)

/// A 10 s call on loudspeakers. The other side talks at 1–3 s and 6–8 s; the person at 4–5 s. The microphone hears the
/// person and, 40 ms late and quieter, the other side, and the live transcript took the echo at 6 s for the person's
/// words, heard differently enough that the text filter keeps it.
private func loudspeakerCall(in root: URL, systemSeconds: Double = 10) throws -> URL {
    let directory = try Fixtures.meeting(in: root, name: "call", seconds: 10, segments: [
        Fixtures.segment(.system, "hello there everyone", at: 1.0), Fixtures.segment(.microphone, "yes please", at: 4.1),
        Fixtures.segment(.system, "shall we start", at: 6.0), Fixtures.segment(.microphone, "shell we stark", at: 6.05),
    ])
    let system = systemSeconds == 10 ? otherSide : tone([1.0...3.0, 6.0...8.0], seconds: systemSeconds)
    var microphone = ownSpeech
    for index in 640..<microphone.count where index - 640 < system.count { microphone[index] += 0.2 * system[index - 640] }
    try Fixtures.writeWAV(system, to: directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
    try Fixtures.writeWAV(microphone, to: directory.appendingPathComponent(MeetingStorage.audioFile(.microphone)))
    return directory
}

/// Options with a fake canceller that hands back the person's own speech, and the scripted engine to transcribe it.
private func cancelling(_ canceller: MeetingEchoCanceller? = { microphone, _, _ in Array(ownSpeech.prefix(microphone.count)) },
                        transcribed: Collected? = nil) -> MeetingPostProcessOptions {
    var options = Fixtures.options(spans: [])
    options.echoCanceller = canceller
    options.transcribeLater = { chunks, recognition in
        transcribed?.add(chunks)
        return try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition)
    }
    return options
}

private func report(_ directory: URL) throws -> PostProcessReport {
    try JSONDecoder.meeting.decode(PostProcessReport.self, from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.reportFile)))
}

private func shown(_ turns: [TranscriptTurn]) -> [String] { turns.map { "\($0.speaker): \($0.text)" } }

/// What the speech model was given.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [SpeechChunk] = []
    var value: [SpeechChunk] { lock.withLock { chunks } }
    func add(_ more: [SpeechChunk]) { lock.withLock { chunks += more } }
}

private struct CancellerBroke: Error, LocalizedError { var errorDescription: String? { "the model wouldn't load" } }

@Test func aCallsMicrophoneLinesComeFromItsEchoCancelledAudio() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    let transcribed = Collected()
    let turns = try await MeetingStore(root: root, options: cancelling(transcribed: transcribed)).process(directory.lastPathComponent)

    // The echo the live transcript gave the person is gone, and so is their live line: both come from the cleaned audio.
    #expect(shown(turns) == ["Them: hello there everyone", "You: alpha1 beta1", "Them: shall we start"])
    // Cut by the live transcript's chunker, from the cleaned audio, on the session's timeline.
    let chunks = transcribed.value
    #expect(chunks.map(\.startSample) == SpeechChunker.chunks(of: ownSpeech, track: .microphone).map(\.startSample))
    #expect(chunks.map(\.samples.count) == SpeechChunker.chunks(of: ownSpeech, track: .microphone).map(\.samples.count))
    #expect(chunks.allSatisfy { $0.track == .microphone })
    let you = try #require(turns.first { $0.speaker == "You" }), chunk = try #require(chunks.first)
    #expect(you.start >= chunk.startSeconds && you.end <= chunk.startSeconds + Double(chunk.samples.count) / MeetingAudio.sampleRate)

    // Kept beside the live segments, so the transcript's source can be read and a render needs nothing again.
    let saved = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.echoCancelledSegmentsFile))
    #expect(saved.map(\.text) == ["alpha1 beta1"])
    #expect(saved.allSatisfy { $0.track == .microphone })
    let processed = try report(directory)
    #expect(processed.echoCancelled == true)
    #expect(processed.liveMicrophoneWords == 5)
    #expect(processed.echoCancelledMicrophoneWords == 2)
    #expect(processed.echoCancelSeconds != nil && processed.echoTranscribeSeconds != nil)
    #expect(shown(try MeetingPostProcessor.render(directory: directory)) == shown(turns))
}

@Test func echoCancellationLeavesTheRecordingsFilesAsTheyWere() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    let recorded = [MeetingStorage.audioFile(.microphone), MeetingStorage.audioFile(.system), MeetingStorage.segmentsFile,
                    MeetingStorage.sessionFile]
    func contents() throws -> [Data] { try recorded.map { try Data(contentsOf: directory.appendingPathComponent($0)) } }
    let before = try contents()
    _ = try await MeetingStore(root: root, options: cancelling()).process(directory.lastPathComponent)
    #expect(try contents() == before)
}

@Test func theCancellerHearsTheSystemTrackAtTheMicrophonesLength() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // The system track stopped 2 s before the microphone did.
    let directory = try loudspeakerCall(in: root, systemSeconds: 8)
    let heard = Mutex<(microphone: Int, reference: [Float])>((0, []))
    let options = cancelling { microphone, reference, _ in
        heard.withLock { $0 = (microphone.count, reference) }
        return Array(ownSpeech.prefix(microphone.count))
    }
    _ = try await MeetingStore(root: root, options: options).process(directory.lastPathComponent)
    let (microphone, reference) = heard.withLock { $0 }
    let system = try WAVFile.readSamples(directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
    #expect(microphone == 160_000)
    #expect(reference.count == microphone)
    #expect(Array(reference.prefix(system.count)) == system)
    #expect(reference.dropFirst(system.count).allSatisfy { $0 == 0 })
}

/// The transcript a run gives with the live microphone lines, as before echo cancellation.
private func liveTranscript(in root: URL) async throws -> [String] {
    let directory = try loudspeakerCall(in: root.appendingPathComponent("live", isDirectory: true))
    return shown(try await MeetingStore(root: directory.deletingLastPathComponent(), options: Fixtures.options(spans: []))
        .process(directory.lastPathComponent))
}

@Test func aCancellerThatFailsLeavesTheLiveMicrophoneLines() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try await liveTranscript(in: root)
    #expect(live == ["Them: hello there everyone", "You: yes please", "Them: shall we start", "You: shell we stark"])

    for canceller: MeetingEchoCanceller in [{ @Sendable _, _, _ in throw CancellerBroke() },
                                            { @Sendable microphone, _, _ in Array(microphone.dropLast()) }] {
        let meetings = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = try loudspeakerCall(in: meetings)
        let lines = Mutex<[String]>([])
        let turns = try await MeetingStore(root: meetings, options: cancelling(canceller))
            .process(directory.lastPathComponent) { line in lines.withLock { $0.append(line) } }
        #expect(shown(turns) == live)
        #expect(lines.withLock { $0 }.filter { $0.hasPrefix("echo cancellation failed") }.count == 1)
        #expect(try report(directory).echoCancelled == false)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStorage.echoCancelledSegmentsFile).path))
    }
}

@Test func aSpeechModelThatFailsOnTheCleanedAudioLeavesTheLiveMicrophoneLines() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try await liveTranscript(in: root)
    let directory = try loudspeakerCall(in: root)
    var options = cancelling()
    options.transcribeLater = { _, _ in throw CancellerBroke() }
    let turns = try await MeetingStore(root: root, options: options).process(directory.lastPathComponent)
    #expect(shown(turns) == live)
    #expect(try report(directory).echoCancelled == false)
}

@Test func withoutASpeechModelOrWithEchoCancellationOffTheTranscriptIsAsBefore() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try await liveTranscript(in: root)
    let called = Counter()
    let canceller: MeetingEchoCanceller = { microphone, _, _ in called.increment(); return microphone }

    var noEngine = cancelling(canceller)
    noEngine.transcribeLater = nil
    var off = cancelling(canceller)
    off.cancelsEcho = false
    for options in [noEngine, off] {
        let meetings = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = try loudspeakerCall(in: meetings)
        #expect(shown(try await MeetingStore(root: meetings, options: options).process(directory.lastPathComponent)) == live)
        let processed = try report(directory)
        #expect(processed.echoCancelled == nil && processed.liveMicrophoneWords == nil)
    }
    #expect(called.value == 0)
    // A test's options, with a diarizer of its own, never fetch the real canceller.
    #expect(Fixtures.options(spans: []).echoCanceller == nil)
}

@Test func aConversationInTheRoomIsntEchoCancelled() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    let url = directory.appendingPathComponent(MeetingStorage.sessionFile)
    var info = try JSONDecoder.meetingDates.decode(MeetingSessionInfo.self, from: Data(contentsOf: url))
    info.kind = .inPerson
    try JSONEncoder.pretty.encode(info).write(to: url)
    let called = Counter()
    _ = try await MeetingStore(root: root, options: cancelling { microphone, _, _ in called.increment(); return microphone })
        .process(directory.lastPathComponent)
    #expect(called.value == 0)
    #expect(!MeetingPostProcessor.cancelsEcho(in: directory))
}

@Test func echoCancellationRunsWhileTheVoicesAreToldApart() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    // The canceller doesn't return until the diarizer has started, and the diarizer notes whether the canceller was
    // still running then: one after the other, in either order, never sets `overlapped`.
    let cancelling = Mutex(false), diarizing = Mutex(false), overlapped = Mutex(false)
    var options = MeetingPostProcessOptions(preset: "offline", diarizer: { _, _ in
        // Waits a while for the canceller to start: it only does before this returns if the two run at once.
        for _ in 0..<3_000 where !cancelling.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        overlapped.withLock { $0 = cancelling.withLock { $0 } }
        diarizing.withLock { $0 = true }
        return DiarizationResult(spans: [])
    }, dictationSpans: { _ in [] }, echoCanceller: { microphone, _, _ in
        cancelling.withLock { $0 = true }
        // Bounded, so running one after the other fails the test rather than hanging it.
        for _ in 0..<3_000 where !diarizing.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        cancelling.withLock { $0 = false }
        return Array(ownSpeech.prefix(microphone.count))
    })
    options.transcribeLater = { chunks, recognition in try await MeetingTranscriber.transcribeAll(chunks, engine: ScriptedEngine(), options: recognition) }
    _ = try await MeetingStore(root: root, options: options).process(directory.lastPathComponent)
    #expect(overlapped.withLock { $0 })
}

@Test func cancellingTheRunStillStopsIt() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    await #expect(throws: CancellationError.self) {
        try await MeetingPostProcessor.run(directory: directory, options: cancelling { _, _, _ in throw CancellationError() })
    }
}

@Test func theEchoCancelledLinesStayWhenTheAudioIsGone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    let id = directory.lastPathComponent
    let first = try await MeetingStore(root: root, options: cancelling()).process(id)
    // Try Again after the audio was deleted: nothing can be cancelled again, so what the first run heard stands.
    let store = MeetingStore(root: root, options: cancelling())
    try await store.deleteAudio(id)
    let again = try await store.process(id)
    #expect(shown(again) == shown(first))
    #expect(try report(directory).echoCancelled == true)
    #expect(try report(directory).echoCancelSeconds == nil)
}

@Test func anExportedFixtureKeepsTheEchoCancelledLines() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try loudspeakerCall(in: root)
    let store = MeetingStore(root: root, options: cancelling())
    _ = try await store.process(directory.lastPathComponent)
    let destination = root.appendingPathComponent("fixture", isDirectory: true)
    let files = try await store.exportFixture(directory.lastPathComponent, to: destination)
    #expect(files.contains(MeetingStorage.echoCancelledSegmentsFile))
}

@Test func downloadsSideBySideReportOneFractionThatNeverGoesBack() {
    let reported = Mutex<[Double?]>([])
    let downloads = CombinedDownload { fraction in reported.withLock { $0.append(fraction) } }
    let speaker = downloads.part("speaker", bytes: 300), echo = downloads.part("echo", bytes: 100)
    speaker(0)
    echo(0)
    echo(0.5)
    echo(nil)
    speaker(0.5)
    speaker(nil)
    #expect(reported.withLock { $0 } == [0, 0, 0.125, 0.25, 0.625, nil])
}

/// GoblinEngines' tests check that the pinned files are this bundle.
@Test func theEchoCancellerLoadsTheBundleThatsPinned() {
    #expect(MeetingEchoModel.bundleName == "localvqe-v1.3-4.8M-256ms.mlmodelc")
    #expect(MeetingEchoModel.files.manifestID == "localvqe-v1.3-256ms")
    #expect(MeetingEchoModel.files.downloadBytes > 19_000_000)
}

/// A canceller that subtracts the reference and hands its output back one hop late, as LocalVQE does; it breaks on its
/// `breaksAt`th call.
private actor DelayedSubtraction {
    private var pending: [Float] = []
    private var calls = 0
    private let breaksAt: Int?
    init(breaksAt: Int? = nil) { self.breaksAt = breaksAt }

    func enhance(_ microphone: [Float], _ reference: [Float]) throws -> [Float] {
        calls += 1
        if let breaksAt, calls >= breaksAt { throw CancellerBroke() }
        pending += zip(microphone, reference).map { $0 - $1 }
        let ready = max(0, pending.count - 256)
        defer { pending.removeFirst(ready) }
        return Array(pending.prefix(ready))
    }

    func flush() -> [Float] { defer { pending = [] }; return pending }

    nonisolated var stream: LiveEchoStream {
        LiveEchoStream(enhance: { try await self.enhance($0, $1) }, flush: { await self.flush() })
    }
}

private final class Heard<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    var value: [Item] { lock.withLock { items } }
    func add(_ item: Item) { lock.withLock { items.append(item) } }
}

private func sameChunks(_ got: [SpeechChunk], _ expected: [SpeechChunk]) -> Bool {
    got.count == expected.count && zip(got, expected).allSatisfy { got, expected in
        got.startSample == expected.startSample && got.samples.count == expected.samples.count
            && zip(got.samples, expected.samples).allSatisfy { abs($0 - $1) < 1e-5 }
    }
}

@Test func theLiveTranscriptHearsTheMicrophoneWithTheCallTakenOutOnTheSameTimeline() async {
    let own = tone([1.0...2.0, 4.0...5.0], seconds: 6, frequency: 330)
    let call = tone([2.5...3.5], seconds: 6)
    let heard = zip(own, call).map { $0 + $1 }
    let chunks = Heard<SpeechChunk>()
    let canceller = LiveEchoCanceller(load: { DelayedSubtraction().stream }, log: { _ in }, onChunk: chunks.add)
    // The call's track arrives in bigger, later pieces than the microphone's, as a tap and a mic do.
    var microphone = 0, system = 0
    while microphone < heard.count || system < call.count {
        if microphone < heard.count {
            canceller.microphone(Array(heard[microphone..<min(microphone + 1_000, heard.count)]))
            microphone += 1_000
        }
        if microphone > system + 3_000 || microphone >= heard.count, system < call.count {
            canceller.system(Array(call[system..<min(system + 3_000, call.count)]))
            system += 3_000
        }
    }
    await canceller.finish()
    #expect(sameChunks(chunks.value, SpeechChunker.chunks(of: own, track: .microphone)))
}

@Test func theMicrophonesSpeakerModelGetsTheCleanedAudioWholeAndInOrderOrTheMicAsHeard() async {
    let own = tone([1.0...2.0, 4.0...5.0], seconds: 6, frequency: 330)
    let call = tone([2.5...3.5], seconds: 6)
    let heard = zip(own, call).map { $0 + $1 }
    // With the call taken out, whole and in order from the session's first sample, so its voices land on the lines.
    let cleaned = Heard<[Float]>()
    let canceller = LiveEchoCanceller(load: { DelayedSubtraction().stream }, log: { _ in }, onSamples: cleaned.add, onChunk: { _ in })
    for start in stride(from: 0, to: heard.count, by: 1_600) {
        canceller.microphone(Array(heard[start..<min(start + 1_600, heard.count)]))
        canceller.system(Array(call[start..<min(start + 1_600, call.count)]))
    }
    await canceller.finish()
    let samples = cleaned.value.flatMap { $0 }
    #expect(samples.count == own.count)
    #expect(zip(samples, own).allSatisfy { abs($0 - $1) < 1e-5 })

    // As heard when the canceller isn't there, still every sample once.
    let raw = Heard<[Float]>()
    let without = LiveEchoCanceller(load: { nil }, log: { _ in }, onSamples: raw.add, onChunk: { _ in })
    without.microphone(heard)
    await without.finish()
    #expect(raw.value.flatMap { $0 } == heard)
}

@Test func aStalledCallTrackPairsWithSilenceAndAMissingOrBrokenCancellerPassesTheMicrophoneThrough() async {
    // The microphone waits for the call's sound as far as it has come, and goes on against silence when told it stalled.
    var pairing = EchoPairing()
    pairing.addMicrophone([Float](repeating: 0.1, count: 48_000))
    pairing.addReference([Float](repeating: 0.2, count: 16_000))
    #expect(pairing.take(all: false)?.reference == [Float](repeating: 0.2, count: 16_000))
    #expect(pairing.take(all: false) == nil)
    #expect(pairing.take(all: true)?.reference == [Float](repeating: 0, count: 32_000))

    // The canceller breaks partway: the transcript gets the same speech chunks, at the same samples, as from the
    // microphone as heard.
    let heard = tone([1.0...2.0, 4.0...5.0], seconds: 6, frequency: 330)
    let chunks = Heard<SpeechChunk>()
    let log = Heard<String>()
    let canceller = LiveEchoCanceller(load: { DelayedSubtraction(breaksAt: 8).stream }, log: log.add, onChunk: chunks.add)
    for start in stride(from: 0, to: heard.count, by: 1_600) {
        canceller.microphone(Array(heard[start..<min(start + 1_600, heard.count)]))
        canceller.system([Float](repeating: 0, count: min(1_600, heard.count - start)))
    }
    await canceller.finish()
    #expect(sameChunks(chunks.value, SpeechChunker.chunks(of: heard, track: .microphone)))
    #expect(log.value.contains { $0.hasPrefix("live echo cancellation stopped") })

    // Not downloaded: as heard from the start.
    let unloaded = Heard<SpeechChunk>()
    let without = LiveEchoCanceller(load: { nil }, log: { _ in }, onChunk: unloaded.add)
    without.microphone(heard)
    await without.finish()
    #expect(sameChunks(unloaded.value, SpeechChunker.chunks(of: heard, track: .microphone)))
}
