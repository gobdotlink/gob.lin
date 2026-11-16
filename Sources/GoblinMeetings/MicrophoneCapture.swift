import AVFoundation
import Foundation

/// The meeting's own microphone input, separate from dictation's capture session.
/// It follows the system default input and restarts itself when the device changes,
/// rather than ending the recording as dictation does.
public final class MicrophoneCapture: @unchecked Sendable {
    /// How often, and how far apart, a restart is tried after the device changes: the new device can take a moment to
    /// accept a client.
    static let restartAttempts = 20
    static let restartInterval: TimeInterval = 0.5
    /// After the quick attempts fail, how often the mic is tried again while the recording lasts.
    static let slowRestartInterval: TimeInterval = 5

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "gob.lin.meetings.microphone-restart", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var handler: (@Sendable (CapturedBuffer) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var onProblem: (@Sendable (MeetingCaptureProblem) -> Void)?
    /// Set by `stop`. An engine that finishes starting after it is stopped at once and never kept.
    private var stopped = false
    /// Counts restarts, so a retry left over from an earlier device change gives up when a newer one begins.
    private var generation = 0

    public init() {}

    public func start(onEvent: @escaping @Sendable (String) -> Void,
                      onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void = { _ in },
                      handler: @escaping @Sendable (CapturedBuffer) -> Void) throws {
        lock.withLock {
            self.handler = handler
            self.onEvent = onEvent
            self.onProblem = onProblem
            stopped = false
        }
        try startEngine(generation: lock.withLock { generation })
    }

    public func stop() {
        let (engine, observer) = lock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?) in
            stopped = true
            generation += 1
            defer { self.engine = nil; self.observer = nil; handler = nil; onProblem = nil }
            return (self.engine, self.observer)
        }
        Self.close(engine, observer)
    }

    private static func close(_ engine: AVAudioEngine?, _ observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    /// Starts an engine for `generation`; it's kept only while that is still the current one and nothing stopped it.
    private func startEngine(generation expected: Int) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingCaptureError.microphone("no input format") }
        let deliver = lock.withLock { handler }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            guard let deliver, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<count {
                let pointer = channels[channel]
                for frame in 0..<frames { mono[frame] += pointer[frame] / Float(count) }
            }
            let host = time.isHostTimeValid ? HostClock.seconds(time.hostTime) : HostClock.now
            deliver(CapturedBuffer(samples: mono, sampleRate: buffer.format.sampleRate, hostSeconds: host))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw MeetingCaptureError.microphone(error.localizedDescription)
        }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { [weak self] _ in self?.restart() }
        // A Stop, or a newer device change, that landed while the engine was starting wins: this engine goes, and
        // nothing keeps the mic open.
        let (kept, replaced) = lock.withLock { () -> (Bool, (AVAudioEngine?, NSObjectProtocol?)) in
            guard !stopped, generation == expected else { return (false, (nil, nil)) }
            defer { self.engine = engine; self.observer = observer }
            return (true, (self.engine, self.observer))
        }
        Self.close(replaced.0, replaced.1)
        guard kept else {
            Self.close(engine, observer)
            throw MeetingCaptureError.microphone("stopped while starting")
        }
        lock.withLock { onEvent }?("microphone started: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    private func restart() {
        let (engine, observer, event, attempt) = lock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?, (@Sendable (String) -> Void)?, Int) in
            defer { self.engine = nil; self.observer = nil }
            generation += 1
            return (self.engine, self.observer, stopped ? nil : onEvent, generation)
        }
        Self.close(engine, observer)
        guard let event else { return }
        event("microphone configuration changed; restarting")
        retry(generation: attempt, failures: 0)
    }

    /// Tries the new device on its own queue, never on the thread that posted the change: quickly at first, then
    /// every few seconds for as long as the recording lasts, so a mic that comes back is picked up again. Gives up
    /// once the capture is stopped or another change has started its own retries.
    private func retry(generation attempt: Int, failures: Int) {
        restartQueue.async { [weak self] in
            guard let self else { return }
            let (current, event, problem) = self.lock.withLock { (!self.stopped && self.generation == attempt, self.onEvent, self.onProblem) }
            guard current else { return }
            do {
                try self.startEngine(generation: attempt)
                if failures >= Self.restartAttempts { problem?(.microphoneRestored) }
            } catch {
                guard self.lock.withLock({ !self.stopped && self.generation == attempt }) else { return }
                if failures + 1 == Self.restartAttempts {
                    event?("microphone restart failed: \(error.localizedDescription); trying every \(Int(Self.slowRestartInterval)) s")
                    problem?(.microphoneLost)
                }
                let delay = failures + 1 < Self.restartAttempts ? Self.restartInterval : Self.slowRestartInterval
                self.restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.retry(generation: attempt, failures: failures + 1)
                }
            }
        }
    }
}

/// Something that went wrong with capture mid-recording, or came right again, for the controller to say.
public enum MeetingCaptureProblem: Sendable, Equatable {
    /// The mic stopped and couldn't be reopened; the call's sound may still be recording.
    case microphoneLost
    case microphoneRestored
    /// The call's sound stopped arriving: the tap couldn't be rebuilt after the output device changed.
    case systemAudioLost
    case systemAudioRestored
}
