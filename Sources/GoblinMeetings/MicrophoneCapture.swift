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

    /// The same mic by UID, or by product and name once it moved to another USB port and got a new UID, but only when
    /// exactly one connected mic fits, as the ranking does: two identical mics can't be told apart.
    public static func match(_ entry: MicrophoneRanking.Entry, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        if let device = devices.first(where: { $0.uid == entry.uid }) { return device }
        let same = devices.filter { entry.model != nil && $0.model == entry.model && $0.name == entry.name }
        return same.count == 1 ? same[0] : nil
    }

    /// The input devices the processes of `bundleIDs` have open, each followed by its sub-devices if it's an aggregate.
    /// A visible aggregate is listed and opens as itself; Apple's voice processing opens a private one around the real
    /// mic, which isn't listed, so the mic inside stands for it.
    static func callDevices(bundleIDs: [String]) -> [AudioDeviceID] {
        guard !bundleIDs.isEmpty else { return [] }
        return AudioProcess.all()
            .filter { process in process.bundleID.map { id in bundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") } } ?? false }
            .flatMap { CoreAudioProperty.objects($0.objectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) }
            .flatMap { device in
                let inside = CoreAudioProperty.objects(device, kAudioAggregateDevicePropertyActiveSubDeviceList)
                return [device] + inside
            }
    }
}

/// The meeting's own microphone, separate from dictation's capture session. It opens one device by its ID, never the
/// system default through an engine, and checks every second that it's still the mic `MeetingMicrophone.choose`
/// picks: when you pick another in the Sidekick, or the call app switches mics, it moves. When the device goes away or
/// changes under it, it reopens rather than ending the recording.
public final class MicrophoneCapture: @unchecked Sendable {
    /// Opens in a row without audio arriving before the mic is reported lost; the first ones are half a second apart.
    static let restartAttempts = 20
    static let restartInterval: TimeInterval = 0.5
    /// After that, how often the mic is tried again while the recording lasts.
    static let slowRestartInterval: TimeInterval = 5
    /// How often the mic is checked against your pick and the call app's, and for silence.
    static let followInterval: TimeInterval = 1

    private let callBundleIDs: [String]
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Opening, closing, reopening and the once-a-second check, so the audio unit is never used while it's disposed.
    private let queue = DispatchQueue(label: "gob.lin.meetings.microphone", qos: .userInitiated)
    /// Where each open mic hands its audio, in order across reopens, so nothing downstream runs on the render thread.
    private let delivery = DispatchQueue(label: "gob.lin.meetings.microphone.delivery", qos: .userInteractive)
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
    /// Opens tried since audio last arrived, failed or not: a mic that opens and breaks again before delivering
    /// anything counts as much as one that won't open.
    private var attempts = 0
    /// The mic was reported lost; it's reported restored once audio arrives again.
    private var lost = false
    /// The silence last reported, so each change is said once.
    private var silence: InputSilence?

    /// `target` is the call's: its processes are where the call app's mic is read from. In person, `.none`.
    public init(call target: SystemAudioTarget = .none, defaults: UserDefaults = .standard) {
        if case .app(let bundleIDs, _) = target { callBundleIDs = bundleIDs } else { callBundleIDs = [] }
        self.defaults = defaults
    }

    /// The mic being recorded, and why.
    public var inUse: MeetingMicrophone? { lock.withLock { current } }
    /// The mic stopped and hasn't brought audio back yet.
    public var isLost: Bool { lock.withLock { lost } }
    /// Why the open mic can't be heard, while it can't.
    public var silent: InputSilence? { lock.withLock { silence } }

    /// Throws when no mic will open, in person, where there's nothing else to record. A call keeps trying instead,
    /// and says the mic is lost if none comes, so plugging one in or opening the lid later still records you.
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
        do { try queue.sync { try open(generation: attempt) } } catch {
            guard !callBundleIDs.isEmpty else { throw error }
            onEvent("microphone didn't start: \(error.localizedDescription); trying again")
            queue.asyncAfter(deadline: .now() + Self.restartInterval) { [weak self] in self?.retry(generation: attempt) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.followInterval, repeating: Self.followInterval)
        timer.setEventHandler { [weak self] in self?.follow() }
        // Started before anything can drop it: libdispatch traps when a timer that never started is released.
        timer.resume()
        guard lock.withLock({ () -> Bool in
            guard !stopped else { return false }
            follower = timer
            return true
        }) else { return timer.cancel() }
    }

    /// Closes the mic, keeping the batch it was filling, and returns once everything it heard has been handed over.
    public func stop() {
        let follower = lock.withLock { () -> DispatchSourceTimer? in
            stopped = true
            generation += 1
            defer { self.follower = nil; handler = nil; onProblem = nil }
            return self.follower
        }
        follower?.cancel()
        queue.sync {
            let unit = lock.withLock { () -> AudioInputUnit? in
                defer { self.unit = nil; sink = nil }
                return self.unit
            }
            unit?.closeDelivering()
        }
        delivery.sync {}
    }

    /// On `queue`: opens the mic `choose` picks now, for `generation`. It's kept only while that is still the current
    /// generation and nothing stopped it.
    private func open(generation expected: Int) throws {
        let (previous, deliver) = lock.withLock { () -> (MeetingMicrophone?, (@Sendable (CapturedBuffer) -> Void)?) in
            attempts += 1
            return (current, handler)
        }
        guard let choice = choose(current: previous) else { throw MeetingCaptureError.microphone("no microphone that can hear is connected") }
        let unit: AudioInputUnit
        do { unit = try AudioInputUnit(device: choice.device) } catch {
            throw MeetingCaptureError.microphone("\(choice.device.name): \(error.localizedDescription)")
        }
        let sink = Sink(delivery: delivery, deliver: deliver, heard: { [weak self] in self?.heard() },
                        broke: { [weak self] sink in self?.broke(sink) })
        // A notification can repeat a value the open stream already has; only one that leaves it unhealthy reopens.
        unit.observeChanges { [weak self, weak sink] in if let sink { self?.broke(sink, unlessHealthy: true) } }
        do { try unit.start(delivering: sink) } catch {
            unit.close()
            throw MeetingCaptureError.microphone("\(choice.device.name): \(error.localizedDescription)")
        }
        let (kept, replaced, wasSilent) = lock.withLock { () -> (Bool, AudioInputUnit?, Bool) in
            guard !stopped, generation == expected else { return (false, nil, false) }
            // The new mic and its cleared warning are published together: it hasn't been silent yet, and the next
            // checks say so again if it is.
            defer { self.unit = unit; self.sink = sink; current = choice; silence = nil }
            return (true, self.unit, silence != nil)
        }
        replaced?.closeDelivering()
        guard kept else {
            unit.close()
            throw MeetingCaptureError.microphone("stopped while starting")
        }
        let (event, problem) = lock.withLock { (onEvent, onProblem) }
        event?("microphone started: \(choice.device.name), \(choice.reason), \(Int(unit.format.sampleRate)) Hz, \(unit.format.channelCount) ch")
        if wasSilent { problem?(.microphoneSilence(nil)) }
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
        guard lock.withLock({ () -> Bool in
            guard cause != silence else { return false }
            silence = cause
            return true
        }) else { return }
        event?(cause.map { "microphone \(current.device.name) is silent: \($0)" } ?? "microphone \(current.device.name) hears sound again")
        problem?(.microphoneSilence(cause))
    }

    /// The open device stopped rendering, changed under the stream or went away. From any thread. After a property
    /// notification, `unlessHealthy` keeps a mic that is still running in its opening format.
    private func broke(_ sink: Sink, unlessHealthy: Bool = false) {
        queue.async { [weak self] in
            guard let self, let unit = lock.withLock({ self.sink === sink && !stopped ? self.unit : nil }) else { return }
            if unlessHealthy, unit.isHealthy { return }
            lock.withLock { onEvent }?("microphone configuration changed; reopening")
            reopen()
        }
    }

    /// Audio arrived from the open mic: the next failure starts counting afresh, and a lost mic is back.
    private func heard() {
        let (restored, problem) = lock.withLock { () -> (Bool, (@Sendable (MeetingCaptureProblem) -> Void)?) in
            defer { attempts = 0; lost = false }
            return (lost, onProblem)
        }
        if restored { problem?(.microphoneRestored) }
    }

    /// On `queue`: closes the mic, keeping the batch it was filling, and opens the one `choose` picks now: at once
    /// after a mic that delivered audio, else at the retry pace, for as long as the recording lasts.
    private func reopen() {
        let (unit, attempt) = lock.withLock { () -> (AudioInputUnit?, Int) in
            defer { self.unit = nil; sink = nil }
            generation += 1
            return (self.unit, generation)
        }
        unit?.closeDelivering()
        // That last batch may be the first audio this mic gave, which resets the count: let it land before reading it.
        delivery.sync {}
        let tried = lock.withLock { attempts }
        guard tried > 0 else { return retry(generation: attempt) }
        // It broke before delivering anything: as much a failed attempt as one that wouldn't open.
        noteFailure("the microphone keeps stopping before any audio arrives")
        queue.asyncAfter(deadline: .now() + Self.delay(after: tried)) { [weak self] in self?.retry(generation: attempt) }
    }

    /// Reports the mic lost once `restartAttempts` opens in a row have brought no audio.
    private func noteFailure(_ reason: String) {
        let (losing, event, problem) = lock.withLock { () -> (Bool, (@Sendable (String) -> Void)?, (@Sendable (MeetingCaptureProblem) -> Void)?) in
            let losing = !stopped && !lost && attempts >= Self.restartAttempts
            if losing { lost = true }
            return (losing, onEvent, onProblem)
        }
        guard losing else { return }
        event?("microphone lost: \(reason); trying every \(Int(Self.slowRestartInterval)) s")
        problem?(.microphoneLost)
    }

    private static func delay(after attempts: Int) -> TimeInterval {
        attempts < restartAttempts ? restartInterval : slowRestartInterval
    }

    /// Tries to open a mic, then again at the retry pace until one opens. Gives up once the capture is stopped or
    /// another change has started its own retries. The mic is reported lost once `restartAttempts` opens in a row have
    /// brought no audio, and restored when audio arrives.
    private func retry(generation attempt: Int) {
        guard lock.withLock({ !stopped && generation == attempt }) else { return }
        do {
            try open(generation: attempt)
        } catch {
            let (current, tried) = lock.withLock { (!stopped && generation == attempt, attempts) }
            guard current else { return }
            noteFailure(error.localizedDescription)
            queue.asyncAfter(deadline: .now() + Self.delay(after: tried)) { [weak self] in self?.retry(generation: attempt) }
        }
    }
}

/// One open mic's audio, mixed to mono for the track and handed to `delivery`, and how long it has sent nothing but
/// zeros. `receive` runs on the render thread, so it only copies and hands over.
private final class Sink: AudioInputSink, @unchecked Sendable {
    private let delivery: DispatchQueue
    private let deliver: (@Sendable (CapturedBuffer) -> Void)?
    private let heard: @Sendable () -> Void
    private let broke: @Sendable (Sink) -> Void
    private let lock = NSLock()
    private var delivered = false
    private var heardSound = false
    /// When the current unbroken run of zeros began, on the host clock.
    private var zeroSince: Double?

    init(delivery: DispatchQueue, deliver: (@Sendable (CapturedBuffer) -> Void)?, heard: @escaping @Sendable () -> Void,
         broke: @escaping @Sendable (Sink) -> Void) {
        self.delivery = delivery
        self.deliver = deliver
        self.heard = heard
        self.broke = broke
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        guard deliver != nil, let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            let pointer = channels[channel]
            for frame in 0..<frames { mono[frame] += pointer[frame] / Float(count) }
        }
        let host = time.flatMap { $0.isHostTimeValid ? HostClock.seconds($0.hostTime) : nil } ?? HostClock.now
        let rate = buffer.format.sampleRate
        delivery.async { [self] in handOver(mono, rate: rate, host: host) }
    }

    /// On `delivery`, in order.
    private func handOver(_ samples: [Float], rate: Double, host: Double) {
        guard let deliver else { return }
        let sound = samples.contains { $0 != 0 }
        let first = lock.withLock { () -> Bool in
            if sound { heardSound = true; zeroSince = nil } else if zeroSince == nil { zeroSince = host }
            defer { delivered = true }
            return !delivered
        }
        var buffer = CapturedBuffer(samples: samples, sampleRate: rate, hostSeconds: host)
        buffer.resumes = first
        deliver(buffer)
        if first { heard() }
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
