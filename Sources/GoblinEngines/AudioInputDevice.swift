import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String

    public init(id: AudioDeviceID, uid: String, name: String) {
        self.id = id; self.uid = uid; self.name = name
    }
}

public struct AudioInputResolution: Sendable, Equatable {
    public let requestedUID: String
    public let device: AudioInputDevice
    public var usedFallback: Bool { !requestedUID.isEmpty && requestedUID != device.uid }
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
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func resolve(uid: String) throws -> AudioInputResolution {
        let devices = try list()
        if !uid.isEmpty, let device = devices.first(where: { $0.uid == uid }) {
            return AudioInputResolution(requestedUID: uid, device: device)
        }
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              let device = devices.first(where: { $0.id == id }) else { throw AudioCaptureFailure(.deviceUnavailable) }
        return AudioInputResolution(requestedUID: uid, device: device)
    }

    static func select(_ device: AudioInputDevice, input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw AudioCaptureFailure(.deviceUnavailable) }
        var id = device.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioCaptureFailure(.deviceUnavailable)
        }
    }

    static func matchesRunningStream(_ engine: AVAudioEngine, device: AudioInputDevice, format: AVAudioFormat) -> Bool {
        let input = engine.inputNode
        let current = input.inputFormat(forBus: 0)
        guard engine.isRunning, current.sampleRate == format.sampleRate, current.channelCount == format.channelCount,
              input.outputFormat(forBus: 0).isEqual(format), let unit = input.audioUnit else { return false }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr,
              id == device.id else { return false }
        var alive: UInt32 = 0
        var address = property(kAudioDevicePropertyDeviceIsAlive)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr, alive != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) == noErr && running != 0
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

    private static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
