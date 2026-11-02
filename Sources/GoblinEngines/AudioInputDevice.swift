import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import GoblinCore
import IOKit

public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    /// Product name and USB IDs. Unlike a USB UID, it stays the same when the device moves to another port.
    public let model: String?
    public let kind: MicrophoneKind
    /// A built-in microphone cut off by the closed lid: it still lists, but records only silence.
    public let silencedByLid: Bool

    public init(id: AudioDeviceID, uid: String, name: String, model: String? = nil, kind: MicrophoneKind = .other, silencedByLid: Bool = false) {
        self.id = id; self.uid = uid; self.name = name; self.model = model; self.kind = kind; self.silencedByLid = silencedByLid
    }
}

extension AudioInputDevice {
    public var facts: MicrophoneFacts { MicrophoneFacts(uid: uid, name: name, model: model, kind: kind, silencedByLid: silencedByLid) }
}

/// The inputs and the system default at one moment.
public struct AudioInputSnapshot: Sendable, Equatable {
    public let devices: [AudioInputDevice]
    public let defaultUID: String?
}

public struct AudioInputResolution: Sendable, Equatable {
    public let device: AudioInputDevice
    /// The ranking entry that chose the device.
    public let position: Int
    public let viaSystemDefault: Bool

    public init(device: AudioInputDevice, position: Int = 0, viaSystemDefault: Bool = false) {
        self.device = device; self.position = position; self.viaSystemDefault = viaSystemDefault
    }
}

public enum AudioInputDevices {
    public static func list() throws -> [AudioInputDevice] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else { throw AudioCaptureFailure(.deviceUnavailable) }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw AudioCaptureFailure(.deviceUnavailable) }
        let lidClosed = Self.lidClosed()
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  number(id, selector: kAudioDevicePropertyIsHidden) != 1,
                  // Just after an unplug a device can still list for a moment while reporting itself dead.
                  number(id, selector: kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            let kind = Self.kind(transport: number(id, selector: kAudioDevicePropertyTransportType) ?? 0)
            // A headset in the headphone jack shows as the built-in device's external source and still hears.
            let jack = number(id, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput) == 0x656D_6963 // 'emic'
            return AudioInputDevice(id: id, uid: uid, name: name, model: string(id, selector: kAudioDevicePropertyModelUID),
                                    kind: kind, silencedByLid: lidClosed && kind == .builtIn && !jack)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func snapshot() throws -> AudioInputSnapshot {
        let devices = try list()
        let id = defaultInputID()
        return AudioInputSnapshot(devices: devices, defaultUID: devices.first { $0.id == id }?.uid)
    }

    /// Read fresh at every open, so a key press never acts on a stale device list. A reroute narrows the
    /// list: right after an unplug it can still hold the dead device for a moment.
    static func resolve(_ ranking: MicrophoneRanking, keeping usable: (AudioInputDevice) -> Bool = { _ in true }) throws -> AudioInputResolution {
        let listed = try snapshot()
        let snapshot = AudioInputSnapshot(devices: listed.devices.filter(usable), defaultUID: listed.defaultUID)
        guard let choice = ranking.resolve(connected: snapshot.devices.map(\.facts), systemDefault: snapshot.defaultUID),
              let device = snapshot.devices.first(where: { $0.uid == choice.uid }) else { throw AudioCaptureFailure(.deviceUnavailable) }
        return AudioInputResolution(device: device, position: choice.position, viaSystemDefault: choice.viaSystemDefault)
    }

    /// Apple silicon and T2 laptops disconnect the internal microphone in hardware while the lid is closed.
    public static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool { number(id, selector: kAudioDevicePropertyDeviceIsAlive) == 1 }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func kind(transport: UInt32) -> MicrophoneKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: .iPhone
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .virtual
        default: .other
        }
    }

    public static func loudestChannelRMS(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var loudest = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            var sum = 0.0
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[buffer.format.isInterleaved ? 0 : channel][frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)])
                guard sample.isFinite else { continue }
                sum += sample * sample
            }
            loudest = max(loudest, sqrt(sum / Double(buffer.frameLength)))
        }
        return loudest
    }

    public static func displayLevel(rms: Double) -> Double {
        let level = (20 * log10(max(0.000001, rms)) + 60) / 60
        return level.isFinite ? max(0, min(1, level)) : 0
    }

    /// What the device itself says about being silenced. Mute and input volume are optional
    /// controls: many USB and Bluetooth microphones expose neither, and "unsupported" must
    /// never read as "muted". Nil therefore means "the device will not say".
    public static func deviceSilence(_ device: AudioInputDevice, channelCount: AVAudioChannelCount) -> InputSilence? {
        if isInputMuted(device, channelCount: channelCount) == true { return .muted }
        if let volume = inputVolume(device, channelCount: channelCount), volume == 0 { return .volumeAtZero }
        return nil
    }

    /// True only when every readable channel reports mute. Nil when no channel exposes one.
    public static func isInputMuted(_ device: AudioInputDevice, channelCount: AVAudioChannelCount) -> Bool? {
        let values: [UInt32] = controlElements(device.id, selector: kAudioDevicePropertyMute, channelCount: channelCount)
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    /// The loudest readable input volume, 0...1. Nil when no channel exposes one.
    public static func inputVolume(_ device: AudioInputDevice, channelCount: AVAudioChannelCount) -> Float32? {
        let values: [Float32] = controlElements(device.id, selector: kAudioDevicePropertyVolumeScalar, channelCount: channelCount)
        return values.max()
    }

    /// Reads one input control on the main element, falling back to per-channel elements
    /// when the device has no main control. Elements it cannot read are simply absent.
    private static func controlElements<Value>(_ id: AudioDeviceID, selector: AudioObjectPropertySelector, channelCount: AVAudioChannelCount) -> [Value] {
        func read(_ element: AudioObjectPropertyElement) -> Value? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            guard AudioObjectHasProperty(id, &address) else { return nil }
            // Raw storage: a zero value written into an Optional's bytes reads back as nil.
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
            defer { buffer.deallocate() }
            var size = UInt32(MemoryLayout<Value>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!) == noErr,
                  size == MemoryLayout<Value>.size else { return nil }
            return buffer.load(as: Value.self)
        }
        if let main = read(kAudioObjectPropertyElementMain) { return [main] }
        return (0..<channelCount).compactMap { read(AudioObjectPropertyElement($0 + 1)) }
    }

    fileprivate static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func number(_ id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = property(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// A HAL input unit opened on one device before it initializes. An engine input node binds the system
/// default first: with a Bluetooth headset as default, that switches the headset to its call profile and
/// the engine's own default tracking races a later device change, which once stalled the main thread.
final class AudioInputUnit: @unchecked Sendable {
    let device: AudioInputDevice
    /// The device's current rate and channel count, delivered as non-interleaved Float32.
    let format: AVAudioFormat
    private let unit: AudioUnit
    // Render-thread state between start and stop; touched elsewhere only before start.
    private let chunk: AVAudioPCMBuffer
    private let slice: UnsafeMutableAudioBufferListPointer
    private let target: AVAudioFrameCount
    private let hostTicksPerFrame: Double
    private var chunkTime = AudioTimeStamp()
    private var delivered = false
    private var processor: CaptureProcessor?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var started = false
    private var closed = false

    init(device: AudioInputDevice) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioComponentInstance?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { throw AudioCaptureFailure(.deviceUnavailable) }
        // Enable input and disable output before choosing the device, so an input-only device is accepted.
        var enable: UInt32 = 1, disable: UInt32 = 0, id = device.id
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4) == noErr,
              AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr else {
            AudioComponentInstanceDispose(unit); throw AudioCaptureFailure(.deviceUnavailable)
        }
        // Input cannot change rate inside the unit; keep the hardware rate and every channel.
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame),
              case let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, interleaved: false, channelLayout: layout),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hardware.mSampleRate)),
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription, size) == noErr else {
            AudioComponentInstanceDispose(unit); throw AudioCaptureFailure(.invalidFormat)
        }
        self.device = device; self.unit = unit; self.format = format; self.chunk = chunk
        slice = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        target = AVAudioFrameCount(format.sampleRate / 10)
        hostTicksPerFrame = Double(AVAudioTime.hostTime(forSeconds: 1)) / format.sampleRate
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            Unmanaged<AudioInputUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else { close(); throw AudioCaptureFailure(.startFailed) }
    }

    deinit { close(); free(slice.unsafeMutablePointer) }

    func start(delivering processor: CaptureProcessor) throws {
        guard !closed else { throw AudioCaptureFailure(.startFailed) }
        guard !started else { return }
        self.processor = processor
        guard AudioOutputUnitStart(unit) == noErr else { throw AudioCaptureFailure(.startFailed) }
        started = true
    }

    /// Still running on the opened device in its opening format.
    var isHealthy: Bool {
        guard !closed else { return false }
        var running: UInt32 = 0, current = AudioDeviceID(0), alive: UInt32 = 0, hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<UInt32>.size), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioInputDevices.property(kAudioDevicePropertyDeviceIsAlive)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) == noErr && running != 0
            && AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr && current == device.id
            && AudioObjectGetPropertyData(current, &address, 0, nil, &size, &alive) == noErr && alive != 0
            && AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize) == noErr
            && hardware.mSampleRate == format.sampleRate && hardware.mChannelsPerFrame == format.channelCount
    }

    // Off the main queue, so a blocked main thread never holds up a device change.
    private static let listenerQueue = DispatchQueue(label: "app.goblin.capture-device-changes")

    /// Calls `changed` on a private queue when the device goes away or its input format may have changed.
    func observeChanges(_ changed: @escaping @Sendable () -> Void) {
        for (selector, scope) in [(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                                  (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                                  (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)] {
            var address = AudioInputDevices.property(selector, scope: scope)
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            if AudioObjectAddPropertyListenerBlock(device.id, &address, Self.listenerQueue, block) == noErr { listeners.append((address, block)) }
        }
    }

    /// Synchronous: no render callback runs after this returns.
    func close() {
        guard !closed else { return }
        closed = true
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device.id, &address, Self.listenerQueue, block)
        }
        listeners.removeAll()
        AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
    }

    /// Closes, then hands over the batch the device was still filling, so a take moving to another input
    /// keeps the last tenth of a second before the change.
    func closeDelivering() {
        guard !closed else { return }
        close()
        if chunk.frameLength > 0, let processor { deliver(to: processor) }
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let processor, frames > 0 else { return noErr }
        // A sample-time jump ends the chunk early, so the processor sees the gap instead of joined audio.
        // Bluetooth input skips about 100 ms once while its link starts; before any delivery nothing is lost.
        if chunk.frameLength > 0, time.pointee.mSampleTime != chunkTime.mSampleTime + Double(chunk.frameLength) {
            if delivered { deliver(to: processor) } else { chunk.frameLength = 0 }
        }
        guard chunk.frameLength + frames <= chunk.frameCapacity else { processor.interrupt(.bufferOverflow); return kAudioUnitErr_TooManyFramesToProcess }
        if chunk.frameLength == 0 { chunkTime = time.pointee }
        let channels = chunk.floatChannelData!
        for channel in 0..<slice.count {
            slice[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: channels[channel] + Int(chunk.frameLength))
        }
        let status = AudioUnitRender(unit, flags, time, bus, frames, slice.unsafeMutablePointer)
        guard status == noErr else {
            // What this device already delivered into the batch is real audio; keep it before the take moves on.
            if chunk.frameLength > 0 { deliver(to: processor) }
            processor.inputBroke(); return status
        }
        chunk.frameLength += frames
        // Hand over about 100 ms at a time, like an engine tap: backlog bounds downstream assume it. A waiting stop takes
        // the batch at the first cycle past its cutoff rather than holding the take for the rest of it.
        let cycleEnd = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime + UInt64(Double(frames) * hostTicksPerFrame) : 0
        if chunk.frameLength + frames > target || processor.stopWaits(through: cycleEnd) { deliver(to: processor) }
        return noErr
    }

    private func deliver(to processor: CaptureProcessor) {
        // receive copies the samples, so the chunk refills immediately.
        processor.receive(chunk, time: AVAudioTime(audioTimeStamp: &chunkTime, sampleRate: format.sampleRate))
        chunk.frameLength = 0; delivered = true
    }
}
