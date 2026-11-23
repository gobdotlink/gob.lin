import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public enum MeetingCaptureError: Error, LocalizedError {
    case coreAudio(String, OSStatus)
    case noOutputDevice
    case microphone(String)

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "Core Audio failed to \(step) (\(status))."
        case .noOutputDevice: "There is no audio output device to tap."
        case .microphone(let detail): "The microphone could not start: \(detail)"
        }
    }
}

/// What the system-audio track hears.
public enum SystemAudioTarget: Sendable, Hashable, CustomStringConvertible {
    /// Every process except this one.
    case everything
    /// One app and its helpers, followed across restarts by bundle ID.
    case app(bundleIDs: [String], processes: [AudioObjectID])
    /// No system audio: an in-person conversation recorded from the microphone alone.
    case none

    public var description: String {
        switch self {
        case .none: "microphone only"
        case .everything: "all system audio"
        case .app(let bundleIDs, let processes): "app \(bundleIDs.joined(separator: ",")) (\(processes.count) processes)"
        }
    }
}

/// Mono float samples from one capture callback, stamped with the host clock.
public struct CapturedBuffer: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let hostSeconds: Double
}

public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static var now: Double { seconds(mach_absolute_time()) }
}

/// A Core Audio process tap in a private aggregate device. Requires `NSAudioCaptureUsageDescription`;
/// without it macOS delivers silence rather than an error.
public final class SystemAudioTap: @unchecked Sendable {
    /// Quick rebuild attempts after the output device changes, half a second apart and doubling.
    static let rebuildAttempts = 5
    /// Once those fail, how often the tap is tried again while the recording lasts.
    static let slowRebuildInterval: TimeInterval = 10
    /// A running tap calls back every few milliseconds, silence included; this long without a callback, it's rebuilt.
    static let stallTimeout: TimeInterval = 3
    /// Rebuilds that brought no audio back before the controller is told the call's sound is lost.
    static let stallsBeforeLost = 3

    private let target: SystemAudioTarget
    /// Starting, stopping and rebuilding; the device-change listener runs here too.
    private let queue = DispatchQueue(label: "gob.lin.meetings.system-tap", qos: .userInitiated)
    /// The IO callback, kept apart so a teardown on `queue` never waits behind it.
    private let ioQueue = DispatchQueue(label: "gob.lin.meetings.system-tap.io", qos: .userInteractive)
    /// The output device's format listeners. Apart from `queue`, so removing them there never waits on `queue` itself.
    private let listenerQueue = DispatchQueue(label: "gob.lin.meetings.system-tap.listeners")
    /// When the IO callback last ran, in host ticks; written on `ioQueue`, read by the watchdog.
    private let heartbeat = Heartbeat()
    // Everything below is touched only on `queue`, apart from `start` before the listener exists.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// On the output device the aggregate wraps, for as long as this build lasts.
    private var formatListeners: [(device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// The output device's sample rate when the tap was built. A Bluetooth headset that starts a call changes it, and
    /// the tap built on the old one stops without an error.
    private var builtRate: Float64?
    private var builtAt: Double = 0
    private var watchdog: DispatchSourceTimer?
    /// Rebuilds in a row that brought no audio.
    private var stalls = 0
    private var handler: (@Sendable (CapturedBuffer) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var onProblem: (@Sendable (MeetingCaptureProblem) -> Void)?
    /// Set by `stop`: a listener callback or retry that arrives late never builds another tap.
    private var stopped = false
    /// Counts output device changes, so retries for an older change give up when a newer one begins.
    private var generation = 0
    /// The tap couldn't be rebuilt and the controller was told.
    private var lost = false
    public private(set) var formatDescription = ""

    public init(target: SystemAudioTarget) {
        self.target = target
    }

    public func start(onEvent: @escaping @Sendable (String) -> Void,
                      onProblem: @escaping @Sendable (MeetingCaptureProblem) -> Void = { _ in },
                      handler: @escaping @Sendable (CapturedBuffer) -> Void) throws {
        try queue.sync {
            self.handler = handler
            self.onEvent = onEvent
            self.onProblem = onProblem
            stopped = false
            try build()
        }
        // Rebuild on output device changes (AirPods connecting), since the aggregate wraps the old device.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.generation += 1
            self.onEvent?("output device changed; rebuilding the tap")
            self.rebuild(generation: self.generation, failures: 0)
        }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkAudioArrives() }
        queue.sync {
            outputListener = listener
            watchdog = timer
        }
        timer.resume()
    }

    public func stop() {
        let listener = queue.sync { () -> AudioObjectPropertyListenerBlock? in
            stopped = true
            generation += 1
            watchdog?.cancel()
            watchdog = nil
            defer { outputListener = nil }
            return outputListener
        }
        if let listener {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        // After the listener is gone: a callback already queued sees `stopped` and does nothing.
        queue.sync {
            teardown()
            handler = nil
            onProblem = nil
        }
    }

    /// On `queue`: tears the old tap down and builds a new one, retrying with a backoff, then every few seconds once
    /// the controller has been told the call's sound is lost.
    private func rebuild(generation attempt: Int, failures: Int) {
        guard !stopped, generation == attempt else { return }
        teardown()
        do {
            // Said by the watchdog once audio arrives, not here: a tap can build and still deliver nothing.
            try build()
        } catch {
            if failures + 1 == Self.rebuildAttempts {
                onEvent?("tap rebuild failed: \(error.localizedDescription); trying every \(Int(Self.slowRebuildInterval)) s")
                lost = true
                onProblem?(.systemAudioLost)
            }
            let delay = failures + 1 < Self.rebuildAttempts ? 0.5 * pow(2, Double(failures)) : Self.slowRebuildInterval
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.rebuild(generation: attempt, failures: failures + 1)
            }
        }
    }

    private func makeDescription() -> CATapDescription {
        let description: CATapDescription
        switch target {
        case .everything:
            let me = AudioProcess.objectID(forPID: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: me)
        case .none:
            preconditionFailure("A microphone-only session never builds a tap")
        case .app(let bundleIDs, let processes):
            description = CATapDescription(monoMixdownOfProcesses: processes)
            if !bundleIDs.isEmpty {
                description.bundleIDs = bundleIDs
                description.isProcessRestoreEnabled = true
            }
        }
        description.name = "gob.lin meeting tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func build() throws {
        let description = makeDescription()
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeetingCaptureError.coreAudio("create the process tap", status) }
        tapID = tap

        guard let outputDevice = CoreAudioProperty.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                          kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self),
              let outputUID = CoreAudioProperty.string(outputDevice, kAudioDevicePropertyDeviceUID) else {
            teardown()
            throw MeetingCaptureError.noOutputDevice
        }
        watchFormat(of: outputDevice)
        // The output device is in the aggregate only as its clock. A USB interface or headset also has inputs, and
        // the aggregate lists those streams ahead of the tap's; they are skipped below, so "Them" is only the tap.
        let deviceInputStreams = CoreAudioProperty.objects(outputDevice, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        let tapUID = description.uuid.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "gob.lin meeting capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { teardown(); throw MeetingCaptureError.coreAudio("create the aggregate device", status) }
        aggregateID = device

        guard let format = CoreAudioProperty.scalar(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) else {
            teardown()
            throw MeetingCaptureError.coreAudio("read the tap format", -1)
        }
        formatDescription = "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel) bit"
        let sampleRate = format.mSampleRate
        let deliver = handler
        let heartbeat = heartbeat
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            heartbeat.ticks.store(mach_absolute_time(), ordering: .relaxed)
            guard let deliver else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? HostClock.seconds(inputTime.pointee.mHostTime) : HostClock.now
            guard let mono = Self.mixTap(buffers, skipping: deviceInputStreams), !mono.isEmpty else { return }
            deliver(CapturedBuffer(samples: mono, sampleRate: sampleRate, hostSeconds: host))
        }
        guard status == noErr, let proc else { teardown(); throw MeetingCaptureError.coreAudio("create the IO callback", status) }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { teardown(); throw MeetingCaptureError.coreAudio("start the aggregate device", status) }
        builtAt = HostClock.now
        onEvent?("system tap started: \(target), \(formatDescription)")
    }

    /// On `queue`: rebuilds when the output device's sample rate moves away from the one the tap was built on, as a
    /// Bluetooth headset's does when a call opens its mic. Rate notifications that leave it where it was are ignored,
    /// so building the tap can't set off another build.
    private func watchFormat(of device: AudioObjectID) {
        builtRate = CoreAudioProperty.scalar(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self)
        for (selector, scope) in [(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                                  (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)] {
            var address = CoreAudioProperty.address(selector, scope: scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async { self.formatMayHaveChanged(device) }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
                formatListeners.append((device, address, block))
            }
        }
    }

    private func formatMayHaveChanged(_ device: AudioObjectID) {
        guard !stopped, formatListeners.contains(where: { $0.device == device }),
              let rate = CoreAudioProperty.scalar(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
              rate != builtRate else { return }
        generation += 1
        onEvent?("output device changed to \(Int(rate)) Hz; rebuilding the tap")
        // A headset settles over a few notifications; the last one's rebuild wins.
        let attempt = generation
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.rebuild(generation: attempt, failures: 0) }
    }

    /// On `queue`, every second: a tap that has delivered nothing for `stallTimeout` is rebuilt, and after
    /// `stallsBeforeLost` such rebuilds the controller is told; once audio arrives again it's told that too. While a
    /// build is failing, `rebuild`'s own retries own the tap.
    private func checkAudioArrives() {
        guard !stopped, aggregateID != kAudioObjectUnknown else { return }
        let last = HostClock.seconds(heartbeat.ticks.load(ordering: .relaxed))
        if last > builtAt {
            stalls = 0
            if lost {
                lost = false
                onEvent?("call audio arriving again")
                onProblem?(.systemAudioRestored)
            }
        }
        let quiet = HostClock.now - max(last, builtAt)
        guard quiet >= (lost ? Self.slowRebuildInterval : Self.stallTimeout) else { return }
        stalls += 1
        onEvent?("no call audio for \(Int(quiet)) s; rebuilding the tap")
        if stalls == Self.stallsBeforeLost, !lost {
            lost = true
            onProblem?(.systemAudioLost)
        }
        generation += 1
        rebuild(generation: generation, failures: 0)
    }

    /// The tap's own streams, mixed to mono: the buffers after the output device's `skipping` input streams (the last
    /// one if the list is shorter than expected). Each buffer is read only as far as its own size and channel count.
    static func mixTap(_ buffers: UnsafeMutableAudioBufferListPointer, skipping deviceStreams: Int) -> [Float]? {
        let all = Array(buffers)
        let tap = all.count > deviceStreams ? Array(all[deviceStreams...]) : Array(all.suffix(1))
        return mix(tap)
    }

    /// Averages float buffers, interleaved or not, to one mono channel as long as the shortest of them.
    static func mix(_ buffers: [AudioBuffer]) -> [Float]? {
        let readable = buffers.compactMap { buffer -> (UnsafePointer<Float>, channels: Int, frames: Int)? in
            guard let data = buffer.mData else { return nil }
            let channels = Int(max(buffer.mNumberChannels, 1))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            return (UnsafePointer(data.assumingMemoryBound(to: Float.self)), channels, frames)
        }
        guard let frames = readable.map(\.frames).min() else { return nil }
        let total = Float(readable.reduce(0) { $0 + $1.channels })
        var mono = [Float](repeating: 0, count: frames)
        for (pointer, channels, _) in readable {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += pointer[frame * channels + channel] }
                mono[frame] += sum / total
            }
        }
        return mono
    }

    private func teardown() {
        for listener in formatListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.device, &address, listenerQueue, listener.block)
        }
        formatListeners = []
        builtRate = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The IO callback's last run, shared with the watchdog without a lock.
private final class Heartbeat: Sendable {
    let ticks = Atomic<UInt64>(0)
}
