import AppKit
import AVFoundation
import Darwin
import Foundation

/// The capture service's own thread. AVAudioEngine and CoreAudio calls can take hundreds of
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
    private var warmUID = ""
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var processor: CaptureProcessor?
    private var generation = UUID()
    private var configurationObserver: NSObjectProtocol?
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

    private nonisolated init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            Task { @CaptureActor in
                guard let self, self.warmMicrophoneEnabled, self.activeSessionID == nil else { return }
                do { try self.prepareInput(uid: self.warmUID); try self.startEngine() }
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
    public func start(uid: String, directory: URL? = nil,
                      feedback: FeedbackSounds? = nil,
                      feedbackSessionID: UUID? = nil,
                      onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) throws -> UUID {
        guard activeSessionID == nil else { throw AudioCaptureFailure(.alreadyRecording) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        try prepareInput(uid: uid)
        let id = UUID()
        do {
            try processor!.begin(sessionID: id, directory: try directory ?? Self.defaultDirectory(), resolution: inputResolution!,
                                 feedback: feedback, feedbackSessionID: feedbackSessionID, handler: onEvent)
            activeSessionID = id; eventHandler = onEvent; cancellationRequested = false; terminalCommitted = false; cancellationError = nil
            try startEngine()
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
            await processor.seal(atHostTime: cutoff)
            return try await processor.finish(sessionID: sessionID, cancel: false)
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

    public func setWarmMicrophone(enabled: Bool, uid: String) throws {
        guard activeSessionID == nil else { throw AudioCaptureFailure(.alreadyRecording) }
        warmMicrophoneEnabled = enabled; warmUID = uid
        if enabled {
            do { try prepareInput(uid: uid); try startEngine() }
            catch { closeInput(); throw error }
        } else if previews.isEmpty { closeInput() }
    }

    @discardableResult
    public func beginPreview(uid: String, onEvent: @escaping @MainActor @Sendable (AudioPreviewEvent) -> Void) throws -> UUID {
        if activeSessionID != nil {
            let requested = try AudioInputDevices.resolve(uid: uid)
            guard requested.device.id == inputResolution?.device.id else { throw AudioCaptureFailure(.alreadyRecording) }
        } else { try prepareInput(uid: uid) }
        let id = UUID()
        previews[id] = onEvent
        do { try startEngine() }
        catch { previews.removeValue(forKey: id); if !warmMicrophoneEnabled && activeSessionID == nil { closeInput() }; throw error }
        return id
    }

    public func endPreview(_ id: UUID) {
        previews.removeValue(forKey: id)
        if previews.isEmpty && activeSessionID == nil {
            if warmMicrophoneEnabled {
                do { try prepareInput(uid: warmUID); try startEngine() } catch { closeInput() }
            } else { closeInput() }
        }
    }

    public func shutdown() async {
        warmMicrophoneEnabled = false; previews.removeAll()
        if let id = activeSessionID { try? await cancel(sessionID: id) }
        closeInput()
    }

    private func prepareInput(uid: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        // Resolve the UID and current default on every start, even when the previous engine is warm.
        let resolved = try AudioInputDevices.resolve(uid: uid)
        if let engine, let format, let inputFormat, resolved.device.id == inputResolution?.device.id,
           AudioInputDevices.matchesRunningStream(engine, device: resolved.device, format: format, inputFormat: inputFormat) {
            inputResolution = resolved; return
        }
        closeInput()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try AudioInputDevices.select(resolved.device, input: input)
        let format = input.outputFormat(forBus: 0)
        let inputFormat = input.inputFormat(forBus: 0)
        let token = UUID(); generation = token
        let previewDelivery = CapturePreviewDelivery { [weak self] rms in
            guard let self, self.generation == token, let resolution = self.inputResolution else { return }
            self.notifyPreviews(.input(device: resolution, rms: rms))
        }
        let processor = try CaptureProcessor(format: format, resolution: resolved, preview: { rms in
            previewDelivery.update(rms)
        }, onFailure: { [weak self] failure in
            Task { @CaptureActor [weak self] in
                guard let self, self.generation == token else { return }
                self.closeInput(keepProcessor: self.activeSessionID != nil)
                self.notifyPreviews(.failed(failure))
            }
        })
        self.engine = engine; self.format = format; self.inputFormat = inputFormat; self.processor = processor; inputResolution = resolved
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, time in processor.receive(buffer, time: time) }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
            Task { @CaptureActor in
                guard let self, self.generation == token, let engine = self.engine else { return }
                // Selecting a device can deliver a delayed notification after its stream is already healthy.
                guard !AudioInputDevices.matchesRunningStream(engine, device: resolved.device, format: format, inputFormat: inputFormat) else { return }
                processor.interrupt(.configurationChanged)
            }
        }
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
                else if let failure = processor.watchdogFailure() { processor.interrupt(failure) }
            }
        }
        self.watchdog = watchdog
        watchdog.resume()
        engine.prepare()
    }

    /// In order on the main queue, so a meter never shows a level after its failure.
    private func notifyPreviews(_ event: AudioPreviewEvent) {
        let observers = Array(previews.values)
        guard !observers.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for observer in observers { observer(event) } }
        }
    }

    private func startEngine() throws {
        guard let engine else { throw AudioCaptureFailure(.startFailed) }
        if !engine.isRunning { try engine.start() }
    }

    private func finishOwnership() {
        activeSessionID = nil; terminalTask = nil; eventHandler = nil
        let waiters = cancellationWaiters; cancellationWaiters.removeAll()
        for waiter in waiters {
            if let cancellationError { waiter.resume(throwing: cancellationError) } else { waiter.resume() }
        }
        if let engine, engine.isRunning, let processor {
            if warmMicrophoneEnabled || !previews.isEmpty { processor.resume() }
            else { closeInput() }
        } else { closeInput() }
    }

    private func closeInput(keepProcessor: Bool = false) {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
        processor?.pause()
        engine?.inputNode.removeTap(onBus: 0); engine?.stop()
        engine = nil; format = nil; inputFormat = nil; inputResolution = nil
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
