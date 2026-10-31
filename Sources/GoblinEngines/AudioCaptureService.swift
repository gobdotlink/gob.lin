import AppKit
import AVFoundation
import Darwin
import Foundation
import GoblinCore

/// The capture service's own thread. CoreAudio calls can take hundreds of
/// milliseconds, or never return while a device misbehaves; off the main thread, that never
/// freezes the menu, windows or overlay.
@globalActor
public actor CaptureActor {
    public static let shared = CaptureActor()
    private let queue = DispatchSerialQueue(label: "app.goblin.capture-engine", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}

/// Shared by dictation and the settings level preview. Event handlers run in order on the processing
/// queue; preview observers run on the main actor.
@CaptureActor
public final class AudioCaptureService {
    public nonisolated static let shared = AudioCaptureService()
    public private(set) var activeSessionID: UUID?
    public private(set) var warmMicrophoneEnabled = false
    public private(set) var inputResolution: AudioInputResolution?
    private var warmRanking = MicrophoneRanking()
    /// What the running take resolves again if its microphone drops out.
    private var sessionRanking = MicrophoneRanking()
    /// Mics that failed to open during the current outage, left out of the next try.
    private var unopenable: Set<AudioDeviceID> = []
    /// A take without input for longer ends, audio kept, rather than coming back with a hole nobody sees.
    private static let outageLimit: Duration = .seconds(2)
    private var input: AudioInputUnit?
    private var processor: CaptureProcessor?
    private var generation = UUID()
    private var sleepObserver: NSObjectProtocol?
    // Set once in init and kept for the process lifetime.
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var previews: [UUID: @MainActor @Sendable (AudioPreviewEvent) -> Void] = [:]
    private var terminalTask: Task<CapturedAudio?, Error>?
    private var cancellationRequested = false
    private var terminalCommitted = false
    private var cancellationWaiters: [CheckedContinuation<Void, Error>] = []
    private var cancellationError: Error?
    private var eventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    /// The silence warning currently published to the session and previews.
    private var silenceCause: InputSilence?

    private nonisolated init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            Task { @CaptureActor in
                guard let self, self.warmMicrophoneEnabled, self.activeSessionID == nil else { return }
                do { try self.openWarm() }
                catch { self.closeInput() }
            }
        }
    }

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("gob.lin/Captures", isDirectory: true)
    }

    public static func recoverRecordings(in directory: URL) throws -> [URL] { try CaptureFile.recover(in: directory) }

    @discardableResult
    public func start(ranking: MicrophoneRanking, directory: URL? = nil,
                      feedback: FeedbackSounds? = nil,
                      feedbackSessionID: UUID? = nil,
                      onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) throws -> UUID {
        guard activeSessionID == nil else { throw AudioCaptureFailure(.alreadyRecording) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        try prepareInput(AudioInputDevices.resolve(ranking))
        sessionRanking = ranking; unopenable = []
        let id = UUID()
        do {
            try processor!.begin(sessionID: id, directory: try directory ?? Self.defaultDirectory(), resolution: inputResolution!,
                                 feedback: feedback, feedbackSessionID: feedbackSessionID, handler: onEvent)
            activeSessionID = id; eventHandler = onEvent; cancellationRequested = false; terminalCommitted = false; cancellationError = nil; silenceCause = nil
            notifyPreviews(.silence(nil))
            try startInput()
            return id
        } catch {
            let failure = processor?.abortStart((error as? AudioCaptureFailure)?.kind ?? .startFailed)
                ?? AudioCaptureFailure(.startFailed)
            // A file created before an unsuccessful open remains recoverable; no speech is claimed.
            activeSessionID = nil; eventHandler = nil
            closeInput()
            throw failure
        }
    }

    public func stop(sessionID: UUID) async throws -> CapturedAudio {
        guard activeSessionID == sessionID, terminalTask == nil, let processor else { throw AudioCaptureFailure(.staleSession) }
        let cutoff = mach_absolute_time()
        let task = Task {
            let start = ContinuousClock.now
            await processor.seal(atHostTime: cutoff)
            let sealed = ContinuousClock.now
            var result = try await processor.finish(sessionID: sessionID, cancel: false)
            let milliseconds = { (duration: Duration) in Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
            result?.stopTiming = CaptureStopTiming(seal: milliseconds(start.duration(to: sealed)), file: milliseconds(sealed.duration(to: .now)),
                                                   buffer: processor.bufferDuration * 1000)
            return result
        }
        terminalTask = task
        defer { finishOwnership() }
        do {
            guard let result = try await task.value else { throw AudioCaptureFailure(.staleSession) }
            if cancellationRequested {
                do { try FileManager.default.removeItem(at: result.fileURL) }
                catch { cancellationError = error; throw error }
                terminalCommitted = true
                await processor.notify(.cancelled(sessionID: sessionID), handler: eventHandler)
                throw CancellationError()
            }
            terminalCommitted = true
            await processor.notify(.finished(result), handler: eventHandler)
            return result
        } catch {
            if cancellationRequested, !terminalCommitted, cancellationError == nil {
                do {
                    try await processor.discardFailedFile(sessionID: sessionID)
                    terminalCommitted = true
                    await processor.notify(.cancelled(sessionID: sessionID), handler: eventHandler)
                } catch { cancellationError = error }
            }
            throw error
        }
    }

    public func cancel(sessionID: UUID) async throws {
        guard activeSessionID == sessionID, let processor else { throw AudioCaptureFailure(.staleSession) }
        guard !terminalCommitted else { throw AudioCaptureFailure(.staleSession) }
        cancellationRequested = true
        processor.pause()
        if terminalTask != nil {
            // The stop owner decides the terminal event and completes deletion before releasing these waiters.
            try await withCheckedThrowingContinuation { cancellationWaiters.append($0) }
            return
        }
        let task = Task { try await processor.finish(sessionID: sessionID, cancel: true) }
        terminalTask = task
        defer { finishOwnership() }
        do {
            _ = try await task.value
            terminalCommitted = true
            await processor.notify(.cancelled(sessionID: sessionID), handler: eventHandler)
        } catch { cancellationError = error; throw error }
    }

    public func setWarmMicrophone(enabled: Bool, ranking: MicrophoneRanking) throws {
        guard activeSessionID == nil else { throw AudioCaptureFailure(.alreadyRecording) }
        warmMicrophoneEnabled = enabled; warmRanking = ranking
        if enabled {
            do { try openWarm() }
            catch { closeInput(); throw error }
        } else if previews.isEmpty { closeInput() }
    }

    @discardableResult
    public func beginPreview(ranking: MicrophoneRanking, onEvent: @escaping @MainActor @Sendable (AudioPreviewEvent) -> Void) throws -> UUID {
        // During a take the preview shows the mic actually recording, whatever the ranking would pick next.
        if activeSessionID == nil { try prepareInput(AudioInputDevices.resolve(ranking)) }
        let id = UUID()
        previews[id] = onEvent
        notifyPreviews(.silence(silenceCause))
        do { try startInput() }
        catch { previews.removeValue(forKey: id); if !warmMicrophoneEnabled && activeSessionID == nil { closeInput() }; throw error }
        return id
    }

    public func endPreview(_ id: UUID) {
        previews.removeValue(forKey: id)
        if previews.isEmpty && activeSessionID == nil {
            if warmMicrophoneEnabled {
                do { try openWarm() } catch { closeInput() }
            } else { closeInput() }
        }
    }

    public func shutdown() async {
        warmMicrophoneEnabled = false; previews.removeAll()
        if let id = activeSessionID { try? await cancel(sessionID: id) }
        closeInput()
    }

    /// Warm mode never holds a Bluetooth microphone open: that would keep headphones at call quality
    /// between dictations. A Bluetooth microphone opens at key-down instead.
    private func openWarm() throws {
        let resolved = try AudioInputDevices.resolve(warmRanking)
        guard resolved.device.kind != .bluetooth else { if previews.isEmpty { closeInput() }; return }
        try prepareInput(resolved); try startInput()
    }

    /// Callers resolve the ranking and current default on every start, even when the previous input is warm.
    private func prepareInput(_ resolved: AudioInputResolution) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        if let input, resolved.device.id == input.device.id, input.isHealthy { inputResolution = resolved; return }
        closeInput()
        let input = try AudioInputUnit(device: resolved.device)
        let token = UUID(); generation = token
        let previewDelivery = CapturePreviewDelivery { [weak self] rms in
            guard let self, self.generation == token, let resolution = self.inputResolution else { return }
            self.notifyPreviews(.input(device: resolution, rms: rms))
        }
        let processor = try CaptureProcessor(format: input.format, resolution: resolved, preview: { rms in
            previewDelivery.update(rms)
        }, onFailure: { [weak self] failure in
            Task { @CaptureActor [weak self] in
                guard let self, self.generation == token else { return }
                self.closeInput(keepProcessor: self.activeSessionID != nil)
                self.notifyPreviews(.failed(failure))
            }
        })
        self.input = input; self.processor = processor; inputResolution = resolved
        watch(input, token: token, processor: processor)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            Task { @CaptureActor in
                guard let self, self.generation == token else { return }
                if self.activeSessionID != nil { processor.interrupt(.systemSleep) }
                else {
                    self.notifyPreviews(.failed(AudioCaptureFailure(.systemSleep)))
                    self.closeInput()
                }
            }
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
        watchdog.setEventHandler { @Sendable [weak self] in
            Task { @CaptureActor in
                guard let self, self.generation == token else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { processor.interrupt(.permissionMissing) }
                // A render failure can arrive before any device notice; this is where it gets rerouted.
                else if processor.inputBroken { self.reroute() }
                else if let failure = processor.watchdogFailure() { processor.interrupt(failure) }
                else { await self.updateSilenceWarning() }
            }
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    private func watch(_ unit: AudioInputUnit, token: UUID, processor: CaptureProcessor) {
        unit.observeChanges { [weak self] in
            Task { @CaptureActor in
                // A notification can repeat a value the open stream already has.
                guard let self, self.generation == token, let input = self.input, input === unit, !input.isHealthy else { return }
                // With a stop already waiting, release it before a close that can block for hundreds of
                // milliseconds; the take gives up its last tenth of a second instead of failing.
                if self.terminalTask == nil { input.closeDelivering() }
                processor.inputBroke()
                self.reroute()
            }
        }
    }

    /// A take outlives its microphone. When the open device dies or changes format, the take moves to
    /// whichever microphone the ranking picks now (the same one reopened, after a format change) and
    /// carries on. Only when nothing opens within the outage limit does it end, with its audio kept, as before.
    private func reroute() {
        guard let processor, processor.inputBroken, let old = input, activeSessionID != nil, terminalTask == nil else { return }
        old.close()
        guard processor.outageFor < Self.outageLimit else { processor.interrupt(.configurationChanged); return }
        let dead = AudioInputDevices.isAlive(old.device.id) ? nil : old.device.id
        var attempted: AudioDeviceID?
        do {
            // Never onto a mic the lid has silenced: that would record zeros with no warning for 15 s.
            let usable: (AudioInputDevice) -> Bool = { $0.id != dead && !$0.silencedByLid }
            let resolved: AudioInputResolution
            do { resolved = try AudioInputDevices.resolve(sessionRanking) { usable($0) && !self.unopenable.contains($0.id) } }
            catch let failure as AudioCaptureFailure where failure.kind == .deviceUnavailable && !unopenable.isEmpty {
                // Every mic is out: one that failed a moment ago (a headset switching modes) may have settled.
                unopenable = []
                resolved = try AudioInputDevices.resolve(sessionRanking, keeping: usable)
            }
            attempted = resolved.device.id
            let unit = try AudioInputUnit(device: resolved.device)
            // Opening can block; a mic that opens after the limit doesn't rescue the take.
            guard processor.outageFor < Self.outageLimit else { throw AudioCaptureFailure(.configurationChanged) }
            try processor.rebind(format: unit.format, resolution: resolved)
            input = unit; inputResolution = resolved
            watch(unit, token: generation, processor: processor)
            try unit.start(delivering: processor)
            unopenable = []
        } catch let failure as AudioCaptureFailure where [.deviceUnavailable, .invalidFormat, .startFailed].contains(failure.kind)
                    && processor.outageFor < Self.outageLimit {
            // A mic that won't open is left out of the next try, and macOS can still name an unplugged mic as
            // default for a moment: the watchdog tries again within the 2 s and three-rebind limits.
            if let attempted { unopenable.insert(attempted) }
            processor.inputBroke()
        } catch {
            processor.interrupt(.configurationChanged)
        }
    }

    /// Publishes the silence warning when it changes. The device read can block briefly;
    /// like every other CoreAudio call here, it stays on the capture thread.
    private func updateSilenceWarning() async {
        guard let processor, let input else { return }
        let snapshot = processor.silenceSnapshot()
        let cause = InputSilenceMonitor.cause(device: AudioInputDevices.deviceSilence(input.device, channelCount: input.format.channelCount),
            receivingInput: snapshot.receivingInput, streak: snapshot.streak, leading: snapshot.leading, heardSound: snapshot.heardSound)
        guard cause != silenceCause else { return }
        silenceCause = cause
        notifyPreviews(.silence(cause))
        // Through the processor queue, so the warning stays in order with frames and levels.
        if let id = activeSessionID { await processor.notify(.silence(sessionID: id, cause: cause), handler: eventHandler) }
    }

    /// In order on the main queue, so a meter never shows a level after its failure.
    private func notifyPreviews(_ event: AudioPreviewEvent) {
        let observers = Array(previews.values)
        guard !observers.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for observer in observers { observer(event) } }
        }
    }

    private func startInput() throws {
        guard let input, let processor else { throw AudioCaptureFailure(.startFailed) }
        try input.start(delivering: processor)
    }

    private func finishOwnership() {
        activeSessionID = nil; terminalTask = nil; eventHandler = nil
        let waiters = cancellationWaiters; cancellationWaiters.removeAll()
        for waiter in waiters {
            if let cancellationError { waiter.resume(throwing: cancellationError) } else { waiter.resume() }
        }
        if let input, input.isHealthy, let processor {
            if warmMicrophoneEnabled && input.device.kind != .bluetooth || !previews.isEmpty {
                processor.resume(); silenceCause = nil
                notifyPreviews(.silence(nil))
            }
            else { closeInput() }
        } else { closeInput() }
    }

    private func closeInput(keepProcessor: Bool = false) {
        generation = UUID(); silenceCause = nil
        notifyPreviews(.silence(nil))
        watchdog?.cancel(); watchdog = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
        processor?.pause()
        input?.close(); input = nil; inputResolution = nil
        if !keepProcessor { processor = nil }
    }
}

// Coalesce levels while UI is busy; a long recording cannot accumulate a callback per buffer.
private final class CapturePreviewDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0.0
    private var pending = false
    private let deliver: @CaptureActor @Sendable (Double) -> Void
    init(deliver: @escaping @CaptureActor @Sendable (Double) -> Void) { self.deliver = deliver }
    func update(_ rms: Double) {
        let schedule = lock.withLock {
            latest = rms
            if pending { return false }
            pending = true; return true
        }
        guard schedule else { return }
        Task { @CaptureActor in
            let rms = self.lock.withLock { self.pending = false; return self.latest }
            self.deliver(rms)
        }
    }
}
