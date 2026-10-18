import CoreAudio
import Darwin
import Foundation

/// Own only controls we changed; a user's unmute relinquishes ownership for that route.
struct OutputMuteLease<Control: Hashable> {
    let controls: () -> Set<Control>
    let read: (Control) -> Bool?
    let write: (Control, Bool) -> Bool
    private var observed: Set<Control> = []
    private var muted: Set<Control> = []

    init(controls: @escaping () -> Set<Control>, read: @escaping (Control) -> Bool?,
         write: @escaping (Control, Bool) -> Bool) {
        self.controls = controls; self.read = read; self.write = write
    }

    mutating func update() {
        let current = controls()
        restore(muted.subtracting(current))
        for control in muted where read(control) == false { muted.remove(control) }
        for control in current.subtracting(observed) {
            if read(control) == false, write(control, true) { muted.insert(control) }
        }
        observed = current
    }

    @discardableResult
    mutating func finish() -> Bool { restore(muted); return muted.isEmpty }

    private mutating func restore(_ controls: Set<Control>) {
        for control in controls {
            let value = read(control)
            if value == false || (value == true && write(control, false)) {
                muted.remove(control)
            }
        }
    }
}

struct OutputMuteControl: Hashable {
    let device: AudioDeviceID
    let uid: String
    let element: AudioObjectPropertyElement

    private var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    static func current() -> Set<Self> {
        var controls: Set<Self> = []
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var route = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var device: AudioDeviceID = 0
            var size = UInt32(MemoryLayout.size(ofValue: device))
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &route, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown, let uid = deviceUID(device) else { continue }
            let main = Self(device: device, uid: uid, element: kAudioObjectPropertyElementMain)
            if main.isWritable { controls.insert(main); continue }
            for channel in 0..<channelCount(device) {
                let control = Self(device: device, uid: uid, element: UInt32(channel + 1))
                if control.isWritable { controls.insert(control) }
            }
        }
        return controls
    }

    func read() -> Bool? {
        guard Self.deviceUID(device) == uid else { return nil }
        var address = address, value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout.size(ofValue: value) else { return nil }
        return value != 0
    }

    func write(_ muted: Bool) -> Bool {
        guard Self.deviceUID(device) == uid, isWritable else { return false }
        var address = address, value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }

    private var isWritable: Bool {
        var address = address, writable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address) &&
            AudioObjectIsPropertySettable(device, &address, &writable) == noErr && writable.boolValue
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func channelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// A separate process restores output even if the parent app crashes or is force-quit.
func runOutputMuteHelper() {
    var lease = OutputMuteLease(controls: OutputMuteControl.current, read: { $0.read() }, write: { $0.write($1) })
    defer {
        // A route can briefly stop answering while Bluetooth reconnects.
        for _ in 0..<10 {
            if lease.finish() { break }
            usleep(20_000)
        }
    }
    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    // Check EOF before touching audio: a short or cancelled recording may already be over.
    guard poll(&input, 1, 0) == 0 else { return }
    while true {
        lease.update()
        let result = poll(&input, 1, 100)
        if result > 0 || (result < 0 && errno != EINTR) { return }
    }
}
