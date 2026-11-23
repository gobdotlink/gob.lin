import AVFoundation
import CoreAudio
import Foundation
import GoblinCore
import GoblinEngines

/// Which mic meetings record, remembered across meetings. Chosen in the Sidekick.
public enum MeetingMicrophonePreference: Codable, Equatable, Sendable {
    /// The mic the call app has open; in person, dictation's ranking.
    case sameAsCall
    /// This mic, whatever the call app uses, while it's connected and can hear.
    case device(MicrophoneRanking.Entry)

    public static let key = "meetings.microphone"

    public static func load(_ defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .sameAsCall
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The mic a meeting records, and why.
public struct MeetingMicrophone: Sendable, Equatable {
    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        /// Picked in the Sidekick.
        case picked
        /// The mic the call app has open.
        case call
        /// Dictation's ranking: in person, or while the call app's mic can't be read.
        case ranking

        public var description: String {
            switch self {
            case .picked: "picked"
            case .call: "same as the call"
            case .ranking: "from the ranking"
            }
        }
    }

    public let device: AudioInputDevice
    public let reason: Reason

    public init(device: AudioInputDevice, reason: Reason) {
        self.device = device
        self.reason = reason
    }

    /// Your pick while it's connected and can hear; else the mic the call app has open; else, while the call app holds
    /// none for a moment (it's switching mics), the one it had; else dictation's ranking. Never a built-in mic the closed
    /// lid has silenced. Opening the system default instead is how a Bluetooth headset's mic gets opened under a call
    /// that uses another mic, which switches the headset to its call profile and the call's sound with it.
    static func choose(preference: MeetingMicrophonePreference, connected: [AudioInputDevice], callDevices: [AudioDeviceID],
                       current: MeetingMicrophone?, ranked: () -> AudioInputDevice?) -> MeetingMicrophone? {
        let usable = connected.filter { !$0.silencedByLid }
        if case .device(let entry) = preference, let device = match(entry, in: usable) { return MeetingMicrophone(device: device, reason: .picked) }
        if let device = callDevices.lazy.compactMap({ id in usable.first { $0.id == id } }).first {
            return MeetingMicrophone(device: device, reason: .call)
        }
        if let current, current.reason == .call, let device = usable.first(where: { $0.uid == current.device.uid }) {
            return MeetingMicrophone(device: device, reason: .call)
        }
        return ranked().map { MeetingMicrophone(device: $0, reason: .ranking) }
    }

    /// The same mic by UID, or by product and name once it moved to another USB port and got a new UID.
    public static func match(_ entry: MicrophoneRanking.Entry, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        devices.first { $0.uid == entry.uid } ?? devices.first { entry.model != nil && $0.model == entry.model && $0.name == entry.name }
    }

    /// The input devices the processes of `bundleIDs` have open. Apple's voice processing opens a private aggregate
    /// around the real mic, so an aggregate's sub-devices stand for it.
    static func callDevices(bundleIDs: [String]) -> [AudioDeviceID] {
        guard !bundleIDs.isEmpty else { return [] }
        return AudioProcess.all()
            .filter { process in process.bundleID.map { id in bundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") } } ?? false }
            .flatMap { CoreAudioProperty.objects($0.objectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) }
            .flatMap { device in
                let inside = CoreAudioProperty.objects(device, kAudioAggregateDevicePropertyActiveSubDeviceList)
                return inside.isEmpty ? [device] : inside
            }
    }
}

/// The meeting's own microphone, separate from dictation's capture session. It opens one device by its ID, never the
/// system default through an engine, and checks every second that it's still the mic `MeetingMicrophone.choose`
/// picks: when you pick another in the Sidekick, or the call app switches mics, it moves. When the device goes away or
/// changes under it, it reopens rather than ending the recording.
public final class MicrophoneCapture: @unchecked Sendable {
    /// How often, and how far apart, a reopen is tried after the device changes: the new device can take a moment to
    /// accept a client.
    static let restartAttempts = 20
    static let restartInterval: TimeInterval = 0.5
    /// After the quick attempts fail, how often the mic is tried again while the recording lasts.
    static let slowRestartInterval: TimeInterval = 5
    /// How often the mic is checked against your pick and the call app's, and for silence.
    static let followInterval: TimeInterval = 1

    private let callBundleIDs: [String]
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Opening, reopening and the once-a-second check.
    private let queue = DispatchQueue(label: "gob.lin.meetings.microphone", qos: .userInitiated)
    private var unit: AudioInputUnit?
    private var sink: Sink?
    /// The mic open now, or being reopened.
    private var current: MeetingMicrophone?
    private var follower: DispatchSourceTimer?
    private var handler: (@Sendable (CapturedBuffer) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var onProblem: (@Sendable (MeetingCaptureProblem) -> Void)?
    /// Set by `stop`. A mic that finishes opening after it is closed at once and never kept.
    private var stopped = false
    /// Counts reopens, so a retry left over from an earlier change gives up when a newer one begins.
    private var generation = 0
    /// The silence last reported, so each change is said once.
    private var silence: InputSilence?

    /// `target` is the call's: its processes are where the call app's mic is read from. In person, `.none`.
    public init(call target: SystemAudioTarget = .none, defaults: UserDefaults = .standard) {
        if case .app(let bundleIDs, _) = target { callBundleIDs = bundleIDs } else { callBundleIDs = [] }
        self.defaults = defaults
    }

    /// The mic being recorded, and why.
    public var inUse: MeetingMicrophone? { lock.withLock { current } }

    public func start(onEvent: @escaping @Sendable (String) -> Void,
                      onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void = { _ in },
                      handler: @escaping @Sendable (CapturedBuffer) -> Void) throws {
        let attempt = lock.withLock { () -> Int in
            self.handler = handler
            self.onEvent = onEvent
            self.onProblem = onProblem
            stopped = false
            return generation
        }
        try queue.sync { try open(generation: attempt) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.followInterval, repeating: Self.followInterval)
        timer.setEventHandler { [weak self] in self?.follow() }
        guard lock.withLock({ () -> Bool in
            guard !stopped else { return false }
            follower = timer
            return true
        }) else { return }
        timer.resume()
    }

    public func stop() {
        let (unit, follower) = lock.withLock { () -> (AudioInputUnit?, DispatchSourceTimer?) in
            stopped = true
            generation += 1
            defer { self.unit = nil; sink = nil; self.follower = nil; handler = nil; onProblem = nil }
            return (self.unit, self.follower)
        }
        follower?.cancel()
        unit?.close()
    }

    /// On `queue`: opens the mic `choose` picks now, for `generation`. It's kept only while that is still the current
    /// generation and nothing stopped it.
    private func open(generation expected: Int) throws {
        let (previous, deliver) = lock.withLock { (current, handler) }
        guard let choice = choose(current: previous) else { throw MeetingCaptureError.microphone("no microphone that can hear is connected") }
        let unit: AudioInputUnit
        do { unit = try AudioInputUnit(device: choice.device) } catch {
            throw MeetingCaptureError.microphone("\(choice.device.name): \(error.localizedDescription)")
        }
        let sink = Sink(deliver: deliver) { [weak self] sink in self?.broke(sink) }
        unit.observeChanges { [weak self, weak sink] in if let sink { self?.broke(sink) } }
        do { try unit.start(delivering: sink) } catch {
            unit.close()
            throw MeetingCaptureError.microphone("\(choice.device.name): \(error.localizedDescription)")
        }
        let (kept, replaced) = lock.withLock { () -> (Bool, AudioInputUnit?) in
            guard !stopped, generation == expected else { return (false, nil) }
            defer { self.unit = unit; self.sink = sink; current = choice }
            return (true, self.unit)
        }
        replaced?.close()
        guard kept else {
            unit.close()
            throw MeetingCaptureError.microphone("stopped while starting")
        }
        lock.withLock { onEvent }?("microphone started: \(choice.device.name), \(choice.reason), \(Int(unit.format.sampleRate)) Hz, \(unit.format.channelCount) ch")
    }

    private func choose(current: MeetingMicrophone?) -> MeetingMicrophone? {
        let connected = (try? AudioInputDevices.list()) ?? []
        return MeetingMicrophone.choose(preference: .load(defaults), connected: connected,
                                        callDevices: MeetingMicrophone.callDevices(bundleIDs: callBundleIDs), current: current) {
            let ranking = MicrophoneRanking.load(defaults: defaults) ?? MicrophoneRanking()
            return try? AudioInputDevices.resolve(ranking, keeping: { !$0.silencedByLid }).device
        }
    }

    /// On `queue`, every second: moves to the mic it should be on when that changed, reopens one that stopped, and says
    /// when the open one sends only silence. Nothing while a reopen is retrying; the retries own the mic then.
    private func follow() {
        let (unit, sink, current, event, problem) = lock.withLock { (stopped ? nil : self.unit, self.sink, self.current, onEvent, onProblem) }
        guard let unit, let sink, let current else { return }
        if !unit.isHealthy {
            event?("microphone \(current.device.name) stopped; reopening")
            reopen()
            return
        }
        if let next = choose(current: current), next != current {
            guard next.device.uid != current.device.uid else {
                lock.withLock { if self.sink === sink { self.current = next } }
                return
            }
            event?("microphone: moving to \(next.device.name), \(next.reason)")
            reopen()
            return
        }
        let cause = sink.silence(device: AudioInputDevices.deviceSilence(current.device, channelCount: unit.format.channelCount))
        guard cause != silence else { return }
        silence = cause
        event?(cause.map { "microphone \(current.device.name) is silent: \($0)" } ?? "microphone \(current.device.name) hears sound again")
        problem?(.microphoneSilence(cause))
    }

    /// The open device changed under the stream, stopped rendering or went away. From any thread.
    private func broke(_ sink: Sink) {
        queue.async { [weak self] in
            guard let self, lock.withLock({ self.sink === sink && !stopped }) else { return }
            lock.withLock { onEvent }?("microphone configuration changed; reopening")
            reopen()
        }
    }

    /// On `queue`: closes the mic and opens the one `choose` picks now, retrying for as long as the recording lasts.
    private func reopen() {
        let (unit, attempt) = lock.withLock { () -> (AudioInputUnit?, Int) in
            defer { self.unit = nil; sink = nil }
            generation += 1
            return (self.unit, generation)
        }
        unit?.close()
        retry(generation: attempt, failures: 0)
    }

    /// Quickly at first, then every few seconds for as long as the recording lasts, so a mic that comes back is picked
    /// up again. Gives up once the capture is stopped or another change has started its own retries.
    private func retry(generation attempt: Int, failures: Int) {
        let (current, event, problem) = lock.withLock { (!stopped && generation == attempt, onEvent, onProblem) }
        guard current else { return }
        do {
            try open(generation: attempt)
            if failures >= Self.restartAttempts { problem?(.microphoneRestored) }
        } catch {
            guard lock.withLock({ !stopped && generation == attempt }) else { return }
            if failures + 1 == Self.restartAttempts {
                event?("microphone reopen failed: \(error.localizedDescription); trying every \(Int(Self.slowRestartInterval)) s")
                problem?(.microphoneLost)
            }
            let delay = failures + 1 < Self.restartAttempts ? Self.restartInterval : Self.slowRestartInterval
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.retry(generation: attempt, failures: failures + 1)
            }
        }
    }
}

/// One open mic's audio, mixed to mono for the track, and how long it has sent nothing but zeros.
private final class Sink: AudioInputSink, @unchecked Sendable {
    private let deliver: (@Sendable (CapturedBuffer) -> Void)?
    private let broke: @Sendable (Sink) -> Void
    private let lock = NSLock()
    private var heardSound = false
    /// When the current unbroken run of zeros began, on the host clock.
    private var zeroSince: Double?

    init(deliver: (@Sendable (CapturedBuffer) -> Void)?, broke: @escaping @Sendable (Sink) -> Void) {
        self.deliver = deliver
        self.broke = broke
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        guard let deliver, let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            let pointer = channels[channel]
            for frame in 0..<frames { mono[frame] += pointer[frame] / Float(count) }
        }
        let host = time.flatMap { $0.isHostTimeValid ? HostClock.seconds($0.hostTime) : nil } ?? HostClock.now
        let sound = mono.contains { $0 != 0 }
        lock.withLock {
            if sound { heardSound = true; zeroSince = nil } else if zeroSince == nil { zeroSince = host }
        }
        deliver(CapturedBuffer(samples: mono, sampleRate: buffer.format.sampleRate, hostSeconds: host))
    }

    func interrupt(_ kind: AudioCaptureFailure.Kind, file: StaticString, line: UInt) { broke(self) }
    func inputBroke() { broke(self) }
    func stopWaits(through end: UInt64) -> Bool { false }

    /// Why this mic can't be heard now, if it can't: what the device says about itself, else a long run of exact zeros,
    /// which a working mic never sends even in a silent room.
    func silence(device: InputSilence?) -> InputSilence? {
        lock.withLock {
            let streak = zeroSince.map { HostClock.now - $0 }
            return InputSilenceMonitor.cause(device: device, receivingInput: true, streak: streak,
                                             leading: heardSound ? nil : streak, heardSound: heardSound)
        }
    }
}

/// Something that went wrong with capture mid-recording, or came right again, for the controller to say.
public enum MeetingCaptureProblem: Sendable, Equatable {
    /// The mic stopped and couldn't be reopened; the call's sound may still be recording.
    case microphoneLost
    case microphoneRestored
    /// The open mic is muted, at zero volume or sending only zeros; nil once it's heard again.
    case microphoneSilence(InputSilence?)
    /// The call's sound stopped arriving and the tap couldn't be rebuilt.
    case systemAudioLost
    case systemAudioRestored
}
