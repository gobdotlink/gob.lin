import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import SwiftUI

struct InputDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

@MainActor
final class AudioPreviewModel: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var level: Double = 0
    @Published private(set) var running = false
    @Published private(set) var ready = false
    @Published var error: String?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID = UUID()
    private let monitorSystem: Bool

    init(devices: [InputDevice]? = nil) {
        monitorSystem = devices == nil
        if let devices { self.devices = devices }
    }

    func refresh() {
        guard monitorSystem else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { error = "Could not enumerate microphones."; return }
        guard size > 0 else { devices = []; return }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = identifiers.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { error = "Could not read microphone devices."; return }
        devices = identifiers.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = Self.string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, selector: kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(uid: String) {
        stop()
        guard monitorSystem else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { error = "Allow Microphone in onboarding before previewing audio."; return }
        refresh()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !uid.isEmpty {
            if let device = devices.first(where: { $0.uid == uid }), let unit = input.audioUnit {
                var id = device.id
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { error = "Could not select that microphone."; return }
                error = nil
            } else { error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept." }
        } else { error = nil }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { error = "Microphone has no usable input stream."; return }
        let session = sessionID
        // Sendable prevents this audio-thread callback from inheriting MainActor isolation.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            guard buffer.frameLength > 0, buffer.floatChannelData != nil else { return }
            let value = Self.deviceInputLevel(buffer)
            Task { @MainActor in
                guard let self, self.sessionID == session, self.running else { return }
                self.level = value.isFinite ? value : 0; self.ready = true
            }
        }
        do {
            try engine.start(); self.engine = engine; running = true
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == session, self.running else { return }
                    self.stop()
                    self.refresh()
                    self.error = "Audio configuration changed; preview stopped. Start the preview again to reconnect."
                }
            }
        }
        catch { input.removeTap(onBus: 0); self.error = "Microphone preview failed: \(error.localizedDescription)" }
    }

    func stop() {
        sessionID = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        ready = false
        level = 0
    }

    nonisolated static func deviceInputLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var loudestRMS: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var sum: Double = 0
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[buffer.format.isInterleaved ? 0 : channel][frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)])
                sum += sample * sample
            }
            loudestRMS = max(loudestRMS, sqrt(sum / Double(buffer.frameLength)))
        }
        let level = max(0, min(1, (20 * log10(max(0.000001, loudestRMS)) + 60) / 60))
        return level.isFinite ? level : 0
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

struct AudioSettingsView: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var preview: AudioPreviewModel
    @AppStorage("audio.inputDeviceUID") private var selectedUID = ""

    init(permissions: PermissionModel, preview: AudioPreviewModel = AudioPreviewModel()) {
        self.permissions = permissions; self.preview = preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Audio").font(.largeTitle.bold())
            Picker("Microphone", selection: $selectedUID) {
                Text("Follow system default").tag("")
                ForEach(preview.devices) { Text($0.name).tag($0.uid) }
                if !selectedUID.isEmpty, !preview.devices.contains(where: { $0.uid == selectedUID }) { Text("Saved microphone (unavailable)").tag(selectedUID) }
            }
            Button("Refresh devices") { preview.refresh() }
            Text("Device input level · loudest channel").font(.callout).foregroundStyle(.secondary)
            ProgressView(value: preview.level).tint(GoblinBrand.accent).accessibilityLabel("Device input level, loudest channel")
            if preview.running { Text(preview.ready ? "Receiving device input" : "Waiting for the first audio buffer…").foregroundStyle(.secondary) }
            Button(preview.running ? "Stop level preview" : "Preview microphone level") {
                if preview.running { preview.stop() } else { preview.start(uid: selectedUID) }
            }
            .disabled(permissions.snapshot.microphone != .authorized)
            if permissions.snapshot.microphone != .authorized { Button("Allow microphone…") { permissions.request(.microphone) } }
            if let error = preview.error { Text(error).foregroundStyle(.orange) }
            Text("The preview is local and is not saved. Missing devices fall back to the system default without erasing your saved selection.").foregroundStyle(.secondary)
        }.padding(28)
        .onAppear { preview.refresh() }
        .onDisappear { preview.stop() }
        .onChange(of: selectedUID) { _, uid in if preview.running { preview.start(uid: uid) } }
        .onChange(of: permissions.snapshot.microphone) { _, status in if status != .authorized { preview.stop() } }
    }
}
