import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import GoblinCore
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
    private weak var diagnostics: DiagnosticsModel?

    init(devices: [InputDevice]? = nil, diagnostics: DiagnosticsModel? = nil) {
        self.diagnostics = diagnostics
        monitorSystem = devices == nil
        if let devices { self.devices = devices }
    }

    func refresh() {
        guard monitorSystem else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            error = "Could not enumerate microphones."
            var details = DevelopmentDetails(); details.osStatus = sizeStatus
            log(.deviceEnumerationFailed, severity: .error, details: details); return
        }
        guard size > 0 else { devices = []; return }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = identifiers.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else {
            error = "Could not read microphone devices."
            var details = DevelopmentDetails(); details.osStatus = result
            log(.deviceEnumerationFailed, severity: .error, details: details); return
        }
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
        stop(reason: .restart)
        let session = sessionID
        var selection = DevelopmentDetails(reason: uid.isEmpty ? .systemDefault : .savedDevice)
        if !uid.isEmpty { selection.selectedDevice = diagnostics?.developmentLog.deviceID(uid) }
        log(.previewRequested, details: selection)
        guard monitorSystem else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            fail("Allow Microphone in onboarding before previewing audio.", reason: .permissionMissing); return
        }
        refresh()
        var inventory = DevelopmentDetails(); inventory.deviceCount = devices.count
        log(.devicesEnumerated, details: inventory)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !uid.isEmpty {
            if let device = devices.first(where: { $0.uid == uid }), let unit = input.audioUnit {
                var id = device.id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                selection.osStatus = status
                log(.deviceSelection, severity: status == noErr ? .info : .error, details: selection)
                guard status == noErr else { fail("Could not select that microphone.", reason: .startFailed); return }
                error = nil
            } else {
                error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept."
                selection.reason = .deviceUnavailable
                log(.deviceFallback, severity: .warning, details: selection)
            }
        } else { error = nil }
        var id = AudioDeviceID(0)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        var resolved = DevelopmentDetails()
        if let unit = input.audioUnit {
            resolved.osStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &bytes)
            if resolved.osStatus == noErr, let resolvedUID = Self.string(id, selector: kAudioDevicePropertyDeviceUID) {
                resolved.resolvedDevice = diagnostics?.developmentLog.deviceID(resolvedUID)
            }
        }
        resolved.succeeded = resolved.resolvedDevice != nil
        log(.deviceResolved, severity: resolved.succeeded == true ? .info : .warning, details: resolved)
        let format = input.outputFormat(forBus: 0)
        var formatDetails = DevelopmentDetails()
        formatDetails.channelCount = format.channelCount; formatDetails.sampleRate = format.sampleRate
        log(.inputFormat, details: formatDetails)
        guard format.channelCount > 0, format.sampleRate > 0 else { fail("Microphone has no usable input stream.", reason: .invalidFormat); return }
        log(.tapInstalling)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard buffer.frameLength > 0, buffer.floatChannelData != nil else { return }
            let value = Self.deviceInputLevel(buffer)
            Task { @MainActor in
                guard let self, self.sessionID == session, self.running else { return }
                // This breadcrumb runs on the main actor, once per preview, never on the audio callback.
                if !self.ready { self.log(.firstBuffer) }
                self.level = value.isFinite ? value : 0; self.ready = true
            }
        }
        log(.tapInstalled)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                var details = DevelopmentDetails()
                if self.sessionID == session { details.engineRunning = self.engine?.isRunning }
                self.diagnostics?.developmentLog.record(.configurationChanged, area: .microphone, severity: .warning, operation: session, details: details)
                guard self.sessionID == session, self.running else { return }
                self.stop(reason: .configurationChanged)
                self.error = "Input device changed; preview stopped. Start the preview again to check the new input."
            }
        }
        do {
            log(.engineStarting)
            try engine.start(); self.engine = engine; running = true
            var details = DevelopmentDetails(); details.engineRunning = engine.isRunning
            log(.engineStarted, details: details)
            if diagnostics?.activeFailures[.microphone] == .microphoneCaptureFailed { diagnostics?.resolve(.microphone) }
        }
        catch {
            var details = DevelopmentDetails(reason: .startFailed); details.underlyingError = error
            log(.previewFailed, severity: .error, details: details)
            diagnostics?.report(.microphoneCaptureFailed, operation: session)
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
            input.removeTap(onBus: 0)
            engine.stop()
            log(.previewStopped, details: DevelopmentDetails(reason: .startFailed))
            self.error = "Microphone preview failed: \(error.localizedDescription)"
        }
    }

    func stop(reason: DevelopmentReason = .user) {
        let operation = sessionID
        let hadEngine = engine != nil || running
        if hadEngine { log(.previewStopping, details: DevelopmentDetails(reason: reason)) }
        sessionID = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        ready = false
        level = 0
        if hadEngine { diagnostics?.developmentLog.record(.previewStopped, area: .microphone, operation: operation, details: DevelopmentDetails(reason: reason)) }
    }

    private func log(_ event: DevelopmentEventName, severity: DevelopmentSeverity = .info, details: DevelopmentDetails = DevelopmentDetails()) {
        diagnostics?.developmentLog.record(event, area: .microphone, severity: severity, operation: sessionID, details: details)
    }

    private func fail(_ message: String, reason: DevelopmentReason) {
        error = message
        log(.previewFailed, severity: .error, details: DevelopmentDetails(reason: reason))
        diagnostics?.report(reason == .permissionMissing ? .microphonePermissionMissing : .microphoneCaptureFailed, operation: sessionID)
        log(.previewStopped, details: DevelopmentDetails(reason: reason))
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
        .onDisappear { preview.stop(reason: .viewClosed) }
        .onChange(of: selectedUID) { _, uid in if preview.running { preview.stop(reason: .selectionChanged); preview.start(uid: uid) } }
        .onChange(of: permissions.snapshot.microphone) { _, status in if status != .authorized { preview.stop(reason: .permissionLost) } }
    }
}
