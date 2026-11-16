import Foundation
import Synchronization
import Testing
@testable import GoblinEngines

/// A stand-in for Parakeet: one decode at a time, first come first served, like `ParakeetSpeechEngine`'s gate.
private actor FIFOEngine {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var order: [String] = []

    /// `hold`, when given, decides how long the decode takes instead of `milliseconds`.
    func decode(_ name: String, milliseconds: Int, hold: (@Sendable () async -> Void)? = nil) async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        order.append(name)
        if let hold { await hold() } else { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Opens once; everything waiting on it carries on.
private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Test func backgroundJobsWaitForEveryTakeToEnd() async throws {
    let gate = SpeechPriorityGate()
    let take = gate.beginForeground()
    let started = Mutex(false)
    let job = Task { try await gate.runBackground { started.withLock { $0 = true } } }
    try await Task.sleep(for: .milliseconds(50))
    #expect(started.withLock { $0 } == false)
    gate.endForeground(take)
    try await job.value
    #expect(started.withLock { $0 })
    #expect(gate.snapshot.deferredJobs == 1)
}

@Test func aTakeStartedDuringAMeetingChunkGoesNext() async throws {
    let gate = SpeechPriorityGate()
    let engine = FIFOEngine()
    // Each wait, with when it was reported: the wait can't be longer than the time from key-down to then.
    let waits = Mutex<[(milliseconds: Double, at: ContinuousClock.Instant)]>([])
    gate.observeWaits { wait in waits.withLock { $0.append((wait, .now)) } }
    let (decoding, signal) = AsyncStream.makeStream(of: Void.self)
    let release = Latch()
    // The meeting's worker: chunks one after another, each through the gate. The first decodes until released, so
    // key-down lands inside it however slowly the machine runs.
    let holdFirst: @Sendable () async -> Void = {
        signal.yield()
        await release.wait()
    }
    let meeting = Task {
        for index in 0..<3 {
            let hold: (@Sendable () async -> Void)? = index == 0 ? holdFirst : nil
            try await gate.runBackground { await engine.decode("chunk\(index)", milliseconds: 120, hold: hold) }
        }
    }
    for await _ in decoding { break }
    // Key-down while chunk0 decodes: the take's own decodes queue in the engine right behind it.
    let keyDown = ContinuousClock.now
    let take = gate.beginForeground()
    let dictation = Task {
        await engine.decode("dictation-preview", milliseconds: 20)
        await engine.decode("dictation-final", milliseconds: 20)
    }
    try await Task.sleep(for: .milliseconds(40))
    await release.release()
    await dictation.value
    // While the take is still inserting, no chunk starts.
    try await Task.sleep(for: .milliseconds(150))
    #expect(await engine.order == ["chunk0", "dictation-preview", "dictation-final"])
    gate.endForeground(take)
    try await meeting.value
    #expect(await engine.order == ["chunk0", "dictation-preview", "dictation-final", "chunk1", "chunk2"])
    let report = gate.snapshot
    #expect(report.takes == 1 && report.takesBehindBackground == 1)
    // Behind the one chunk that was running and nothing more: at least the 40 ms it ran on after key-down, and no
    // longer than key-down to the moment that chunk ended and the wait was reported.
    let wait = try #require(waits.withLock { $0.first })
    let bound = keyDown.duration(to: wait.at)
    let boundMilliseconds = Double(bound.components.seconds) * 1_000 + Double(bound.components.attoseconds) / 1e15
    #expect(waits.withLock { $0.count } == 1)
    #expect(wait.milliseconds >= 40 && wait.milliseconds <= boundMilliseconds)
    #expect(report.maximumWaitMilliseconds == wait.milliseconds)
}

@Test func takesThatStartWhileNothingDecodesWaitForNothing() async throws {
    let gate = SpeechPriorityGate()
    let take = gate.beginForeground()
    gate.endForeground(take)
    try await gate.runBackground {}
    let report = gate.snapshot
    #expect(report.takes == 1 && report.takesBehindBackground == 0 && report.maximumWaitMilliseconds == 0)
}

@Test func aCancelledJobLeavesTheQueue() async throws {
    let gate = SpeechPriorityGate()
    let take = gate.beginForeground()
    let job = Task { try await gate.runBackground { Issue.record("a cancelled job must not run") } }
    try await Task.sleep(for: .milliseconds(30))
    job.cancel()
    await #expect(throws: CancellationError.self) { try await job.value }
    gate.endForeground(take)
    // The gate is free again for the next job.
    try await gate.runBackground {}
}

@Test func shutdownReleasesBackgroundWork() async throws {
    let gate = SpeechPriorityGate()
    gate.beginForeground()
    gate.beginForeground()
    let job = Task { try await gate.waitForQuiet() }
    try await Task.sleep(for: .milliseconds(30))
    gate.endAllForeground()
    try await job.value
    #expect(!gate.isForegroundActive)
}
