import AVFoundation
import GoblinCore
import GoblinEngines
import SwiftUI

typealias InputDevice = AudioInputDevice

@MainActor
final class AudioPreviewModel: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var level: Double = 0
    @Published private(set) var running = false
    @Published private(set) var ready = false
    @Published var error: String?
    private var previewID: UUID?
    private var sessionID = UUID()
    private let monitorSystem: Bool
    private weak var diagnostics: DiagnosticsModel?

    init(devices: [InputDevice]? = nil, diagnostics: DiagnosticsModel? = nil) {
        self.diagnostics = diagnostics; monitorSystem = devices == nil
        if let devices { self.devices = devices }
    }

    func refresh() {
        guard monitorSystem else { return }
        do { devices = try AudioInputDevices.list() }
        catch {
            self.error = "Could not enumerate microphones."
            log(.deviceEnumerationFailed, severity: .error)
        }
    }

    func start(uid: String) {
        stop(reason: .restart)
        let session = sessionID
        var details = DevelopmentDetails(reason: uid.isEmpty ? .systemDefault : .savedDevice)
        if !uid.isEmpty { details.selectedDevice = diagnostics?.developmentLog.deviceID(uid) }
        log(.previewRequested, details: details)
        guard monitorSystem else { return }
        refresh()
        do {
            previewID = try AudioCaptureService.shared.beginPreview(uid: uid) { [weak self] event in
                guard let self, self.sessionID == session, self.running else { return }
                switch event {
                case .input(let device, let rms):
                    if !self.ready { self.log(.firstBuffer) }
                    self.ready = true; self.level = AudioInputDevices.displayLevel(rms: rms)
                    if device.usedFallback {
                        self.error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept."
                    } else if self.error == "Selected microphone is unavailable; preview uses the system default. Your preference is kept." {
                        self.error = nil
                    }
                case .failed(let failure):
                    self.stop(reason: .configurationChanged)
                    self.error = failure.localizedDescription
                    self.diagnostics?.report(.microphoneCaptureFailed, operation: session)
                }
            }
            running = true; error = nil
            if let device = AudioCaptureService.shared.inputResolution {
                details.resolvedDevice = diagnostics?.developmentLog.deviceID(device.device.uid)
                log(.deviceResolved, details: details)
                if device.usedFallback {
                    error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept."
                    log(.deviceFallback, severity: .warning, details: DevelopmentDetails(reason: .deviceUnavailable))
                }
            }
            log(.engineStarted)
            if diagnostics?.activeFailures[.microphone] == .microphoneCaptureFailed { diagnostics?.resolve(.microphone) }
        } catch {
            self.error = error.localizedDescription
            log(.previewFailed, severity: .error)
            diagnostics?.report((error as? AudioCaptureFailure)?.kind == .permissionMissing ? .microphonePermissionMissing : .microphoneCaptureFailed, operation: session)
        }
    }

    func stop(reason: DevelopmentReason = .user) {
        let hadPreview = previewID != nil
        if let previewID { AudioCaptureService.shared.endPreview(previewID) }
        previewID = nil
        if hadPreview { log(.previewStopped, details: DevelopmentDetails(reason: reason)) }
        sessionID = UUID(); running = false; ready = false; level = 0
    }

    nonisolated static func deviceInputLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        AudioInputDevices.displayLevel(rms: AudioInputDevices.loudestChannelRMS(buffer))
    }

    private func log(_ event: DevelopmentEventName, severity: DevelopmentSeverity = .info, details: DevelopmentDetails = DevelopmentDetails()) {
        diagnostics?.developmentLog.record(event, area: .microphone, severity: severity, operation: sessionID, details: details)
    }
}

struct AudioSettingsView: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var preview: AudioPreviewModel
    @AppStorage("audio.inputDeviceUID") private var selectedUID = ""
    @AppStorage("audio.keepMicrophoneWarm") private var keepMicrophoneWarm = false

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
            Toggle("Keep microphone warm between dictations", isOn: $keepMicrophoneWarm)
            Text("Warm mode keeps the orange microphone indicator on and retains up to half a second of audio in memory before you press the shortcut. It is not saved until recording. With warm mode off, wait for Listening before speaking; first launch and Bluetooth can take longer. Opening a Bluetooth microphone can reduce headphone playback quality.").font(.callout).foregroundStyle(.secondary)
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
