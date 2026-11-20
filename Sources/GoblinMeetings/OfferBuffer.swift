import AVFoundation
import Foundation
import GoblinEngines

/// One track's capture: the mic, or the call's sound. `MicrophoneCapture` and `SystemAudioTap`; tests use fakes.
public protocol MeetingAudioSource: AnyObject, Sendable {
    func start(onEvent: @escaping @Sendable (String) -> Void,
               onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void,
               handler: @escaping @Sendable (CapturedBuffer) -> Void) throws
    func stop()
}

extension MicrophoneCapture: MeetingAudioSource {}
extension SystemAudioTap: MeetingAudioSource {}

/// What a call says while "Record this call?" is up, held in memory only, so a yes can keep the start of the call.
/// Both tracks are captured as they arrive, at most `maximumSeconds` of each with the oldest dropped first; the call
/// window's mute state is read into a probe with no folder; the speech model starts loading.
///
/// It has no folder and no file, and writes nothing anywhere. A yes hands the running captures, the buffered audio and
/// the probe to a `MeetingSession` (`MeetingSession.start(handingOver:)`). Anything else is `discard`, which stops the
/// captures and the probe at once and drops every sample; the last reference going does the same.
public final class OfferBuffer: @unchecked Sendable {
    public static let maximumSeconds: TimeInterval = 120

    /// Both permissions the buffer needs are already granted. Starting a capture without them would raise macOS's
    /// prompt, and an offer must never do that.
    public static var permitted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SystemAudioPermission.current == .allowed
    }

    /// The captures running for an offer, the first sample either has buffered, and where the recording's timeline
    /// starts once they're handed over.
    struct Heard {
        let firstHost: Double?
        let microphone: (any MeetingAudioSource)?
        let system: (any MeetingAudioSource)?
    }

    private enum State { case listening, handedOver, discarded }

    private let lock = NSLock()
    private var state = State.listening
    private var microphone: (any MeetingAudioSource)?
    private var system: (any MeetingAudioSource)?
    private var probe: AccessibilityProbe?
    private var dictationSpans: [(start: Date, end: Date)] = []
    private let engine: (any PCMSpeechEngine)?
    private let relay: OfferRelay
    private var starting: Task<Void, Never>?
    /// The speech model loading, started with the captures.
    private(set) var preparation: Task<Void, Never>?

    /// Nothing runs until `start`. `probe` is an `AccessibilityProbe` made without a folder.
    public init(microphone: (any MeetingAudioSource)?, system: (any MeetingAudioSource)?, probe: AccessibilityProbe?,
                engine: (any PCMSpeechEngine)?, maximumSeconds: TimeInterval = OfferBuffer.maximumSeconds) {
        self.microphone = microphone
        self.system = system
        self.probe = probe
        self.engine = engine
        relay = OfferRelay(maximumSeconds: maximumSeconds)
    }

    deinit { discard() }

    /// Starts both captures off the caller's thread, the probe, and the speech model's loading. A capture that won't
    /// start is left out; the recording starts its own for that track, as without an offer.
    public func start() {
        lock.withLock {
            guard state == .listening, starting == nil else { return }
            let relay = relay
            starting = Task.detached(priority: .userInitiated) { [self] in
                for track in [MeetingTrack.system, .microphone] {
                    guard let source = lock.withLock({ state == .listening ? (track == .system ? system : microphone) : nil }) else { continue }
                    do {
                        try source.start(onEvent: { relay.event($0) }, onProblem: { relay.problem($0) },
                                         handler: { relay.receive($0, on: track) })
                    } catch {
                        relay.event("\(track.rawValue) didn't start at the offer: \(error.localizedDescription)")
                        lock.withLock { if track == .system { system = nil } else { microphone = nil } }
                        continue
                    }
                    // Discarded while it started: `discard` may have stopped it before it was running, so stop it again.
                    if lock.withLock({ state == .discarded }) { source.stop() }
                }
            }
            probe?.start()
            if let engine {
                // Loaded by the time anyone answers. A no cancels a load that hasn't got going; one that finished stays
                // loaded, to idle out as usual.
                preparation = Task.detached(priority: .utility) { try? await engine.prepare() }
            }
        }
    }

    /// No: stops both captures and the probe, and drops every buffered sample, mute change and dictation. Once the
    /// captures are handed over, only a probe nobody claimed is stopped. Safe to call more than once.
    public func discard() {
        let (sources, probe, wasListening) = lock.withLock { () -> ([any MeetingAudioSource], AccessibilityProbe?, Bool) in
            defer { self.probe = nil; dictationSpans = [] }
            guard state == .listening else { return ([], self.probe, false) }
            state = .discarded
            defer { microphone = nil; system = nil }
            return ([microphone, system].compactMap { $0 }, self.probe, true)
        }
        // Handed over, the relay is the session's now, and so is the model the offer began loading.
        if wasListening {
            relay.close()
            // A load still waiting to begin (for dictation to finish switching models, say) mustn't begin after the no.
            preparation?.cancel()
        }
        for source in sources { source.stop() }
        probe?.stop()
    }

    /// The probe, for the recording to attach to its folder, if it reads the app with `pid`; after this, `discard`
    /// leaves it running. One reading another process (the app restarted since the offer) stays, to be discarded.
    public func claimProbe(pid: pid_t) -> AccessibilityProbe? {
        lock.withLock {
            guard let probe, probe.pid == pid else { return nil }
            defer { self.probe = nil }
            return probe
        }
    }

    /// A gob.lin dictation that ended while the offer was up, so the recording leaves its words out too. Still taken
    /// once the captures are handed over: the recording reads these after it has started, and a take can end meanwhile.
    public func noteDictation(start: Date, end: Date) {
        lock.withLock { if state != .discarded { dictationSpans.append((start, end)) } }
    }

    /// The dictations noted so far, oldest first.
    public var dictations: [(start: Date, end: Date)] { lock.withLock { dictationSpans } }

    /// Once both captures have started, or failed to.
    func whenStarted() async { await lock.withLock { starting }?.value }

    /// Seconds of one track held now, for tests.
    func heldSeconds(_ track: MeetingTrack) -> Double { relay.heldSeconds(track) }

    /// The buffers held now, oldest first, for tests.
    func held(_ track: MeetingTrack) -> [CapturedBuffer] { relay.held(track) }

    /// For the recording that takes over: once the captures have started, stops dropping old audio and says where the
    /// recording's timeline starts, so its track recorders can be made before `handOver`. Nil once discarded.
    func freeze() async -> Heard? {
        await whenStarted()
        guard let sources = lock.withLock({ state == .listening ? (microphone, system) : nil }) else { return nil }
        return Heard(firstHost: relay.freeze(), microphone: sources.0, system: sources.1)
    }

    /// Hands the running captures over: the buffered audio goes to `microphone` and `system` in order, then every
    /// live buffer after it, under one lock, so nothing is lost or repeated between them. Events and capture problems
    /// heard before go first, with the time they happened. The session stops the captures from here on.
    func handOver(microphone deliverMicrophone: @escaping @Sendable (CapturedBuffer) -> Void,
                  system deliverSystem: @escaping @Sendable (CapturedBuffer) -> Void,
                  onEvent: @escaping @Sendable (Date, String) -> Void,
                  onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void) -> Bool {
        let handed = lock.withLock { () -> Bool in
            guard state == .listening else { return false }
            state = .handedOver
            microphone = nil
            system = nil
            return true
        }
        guard handed else { return false }
        relay.route(.init(microphone: deliverMicrophone, system: deliverSystem, onEvent: onEvent, onProblem: onProblem))
        return true
    }
}

/// Where the captures' callbacks land: a bounded buffer per track until the offer is answered, then the session's
/// recorders. The capture threads only ever touch this, under its lock.
final class OfferRelay: @unchecked Sendable {
    struct Route {
        let microphone: @Sendable (CapturedBuffer) -> Void
        let system: @Sendable (CapturedBuffer) -> Void
        let onEvent: @Sendable (Date, String) -> Void
        let onProblem: @Sendable (MeetingCaptureProblem) -> Void
    }

    /// Events kept before the hand-off; a capture restarting every few seconds mustn't grow without end.
    static let eventLimit = 100

    private let lock = NSLock()
    private let maximumSeconds: Double
    private var microphone: [CapturedBuffer] = []
    private var system: [CapturedBuffer] = []
    private var events: [(Date, String)] = []
    private var problems: [MeetingCaptureProblem] = []
    private var current: Route?
    private var frozen = false
    private var closed = false

    init(maximumSeconds: Double) { self.maximumSeconds = maximumSeconds }

    func receive(_ buffer: CapturedBuffer, on track: MeetingTrack) {
        lock.withLock {
            if let current { (track == .microphone ? current.microphone : current.system)(buffer); return }
            guard !closed, buffer.sampleRate > 0, !buffer.samples.isEmpty else { return }
            if track == .microphone { microphone.append(buffer) } else { system.append(buffer) }
            // Once the recording is about to take over, its timeline's start is fixed and nothing more is dropped.
            if !frozen { expire(before: buffer.hostSeconds + Double(buffer.samples.count) / buffer.sampleRate) }
        }
    }

    /// Drops whole buffers from the front of both tracks that began more than `maximumSeconds` before `end`, the end
    /// of the newest sample heard on either. Both, so a track that stopped arriving (its capture died) doesn't keep
    /// audio older than the window, which would also start the recording's timeline minutes before the other track.
    /// Call with the lock held.
    private func expire(before end: Double) {
        let microphoneDrop = microphone.prefix { end - $0.hostSeconds > maximumSeconds }.count
        if microphoneDrop > 0 { microphone.removeFirst(microphoneDrop) }
        let systemDrop = system.prefix { end - $0.hostSeconds > maximumSeconds }.count
        if systemDrop > 0 { system.removeFirst(systemDrop) }
    }

    func event(_ message: String) {
        lock.withLock {
            if let current { current.onEvent(Date(), message); return }
            guard !closed else { return }
            events.append((Date(), message))
            if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
        }
    }

    func problem(_ problem: MeetingCaptureProblem) {
        lock.withLock {
            if let current { current.onProblem(problem); return }
            guard !closed else { return }
            problems.append(problem)
        }
    }

    /// The first buffered sample's host time across both tracks; old audio is no longer dropped after this.
    func freeze() -> Double? {
        lock.withLock {
            frozen = true
            return [microphone.first?.hostSeconds, system.first?.hostSeconds].compactMap { $0 }.min()
        }
    }

    func route(_ route: Route) {
        lock.withLock {
            guard !closed, current == nil else { return }
            for (date, message) in events { route.onEvent(date, message) }
            for problem in problems { route.onProblem(problem) }
            for buffer in microphone { route.microphone(buffer) }
            for buffer in system { route.system(buffer) }
            events = []
            problems = []
            microphone = []
            system = []
            current = route
        }
    }

    /// Drops everything held, and every callback still in flight from here on.
    func close() {
        lock.withLock {
            guard current == nil else { return }
            closed = true
            microphone = []
            system = []
            events = []
            problems = []
        }
    }

    func held(_ track: MeetingTrack) -> [CapturedBuffer] { lock.withLock { track == .microphone ? microphone : system } }

    func heldSeconds(_ track: MeetingTrack) -> Double {
        held(track).reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate }
    }
}
