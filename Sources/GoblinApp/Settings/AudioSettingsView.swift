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
    @Published private(set) var silenceNotice: String?
    /// The open preview, resolving to its id once the device is running (nil if it failed or was stopped first).
    private var preview: Task<UUID?, Never>?
    private var sessionID = UUID()
    private let monitorSystem: Bool
    private weak var diagnostics: DiagnosticsModel?

    init(devices: [InputDevice]? = nil, diagnostics: DiagnosticsModel? = nil) {
        self.diagnostics = diagnostics; monitorSystem = devices == nil
        if let devices { self.devices = devices }
    }

    /// Lists microphones off the main thread: CoreAudio can stall while devices change.
    func refresh() {
        guard monitorSystem else { return }
        Task {
            let listed = await Task.detached(priority: .userInitiated) { Result { try AudioInputDevices.list() } }.value
            switch listed {
            case .success(let listed): if listed != devices { devices = listed }
            case .failure:
                error = "Could not enumerate microphones."
                log(.deviceEnumerationFailed, severity: .error)
            }
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
        let service = AudioCaptureService.shared
        // Opening the device happens on the capture thread; a stop meanwhile ends whatever it opened.
        preview = Task { [weak self] in
            do {
                let id = try await service.beginPreview(uid: uid) { [weak self] event in
                    guard let self, self.sessionID == session, self.running else { return }
                    switch event {
                    case .input(let device, let rms):
                        if !self.ready { self.log(.firstBuffer); self.ready = true }
                        self.level = AudioInputDevices.displayLevel(rms: rms)
                        if device.usedFallback {
                            self.error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept."
                        } else if self.error == "Selected microphone is unavailable; preview uses the system default. Your preference is kept." {
                            self.error = nil
                        }
                    case .silence(let cause):
                        if self.silenceNotice != cause?.message { self.silenceNotice = cause?.message }
                    case .failed(let failure):
                        self.stop(reason: .configurationChanged)
                        self.error = failure.localizedDescription
                        self.diagnostics?.report(failure.kind == .allZeroStream ? .microphoneMuted : .microphoneCaptureFailed, operation: session)
                    }
                }
                let resolution = await service.inputResolution
                guard let self, self.sessionID == session else { await service.endPreview(id); return nil }
                running = true; error = nil
                if let device = resolution {
                    details.resolvedDevice = diagnostics?.developmentLog.deviceID(device.device.uid)
                    log(.deviceResolved, details: details)
                    if device.usedFallback {
                        error = "Selected microphone is unavailable; preview uses the system default. Your preference is kept."
                        log(.deviceFallback, severity: .warning, details: DevelopmentDetails(reason: .deviceUnavailable))
                    }
                }
                log(.engineStarted)
                if diagnostics?.activeFailures[.microphone] == .microphoneCaptureFailed || diagnostics?.activeFailures[.microphone] == .microphoneMuted { diagnostics?.resolve(.microphone) }
                return id
            } catch {
                guard let self, self.sessionID == session else { return nil }
                self.error = error.localizedDescription
                log(.previewFailed, severity: .error)
                let kind = (error as? AudioCaptureFailure)?.kind
                diagnostics?.report(kind == .permissionMissing ? .microphonePermissionMissing : kind == .allZeroStream ? .microphoneMuted : .microphoneCaptureFailed, operation: session)
                return nil
            }
        }
    }

    func stop(reason: DevelopmentReason = .user) {
        if let preview {
            log(.previewStopped, details: DevelopmentDetails(reason: reason))
            Task { if let id = await preview.value { await AudioCaptureService.shared.endPreview(id) } }
        }
        preview = nil
        sessionID = UUID()
        // Assign only what changed: each published write re-renders the views showing the preview.
        if running { running = false }
        if ready { ready = false }
        if level != 0 { level = 0 }
        if silenceNotice != nil { silenceNotice = nil }
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
        Section {
            LabeledContent("Microphone") {
                HStack {
                    Picker("Microphone", selection: $selectedUID) {
                        Text("Follow system default").tag("")
                        ForEach(preview.devices) { Text($0.name).tag($0.uid) }
                        if !selectedUID.isEmpty, !preview.devices.contains(where: { $0.uid == selectedUID }) { Text("Saved microphone (unavailable)").tag(selectedUID) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Refresh devices", systemImage: "arrow.clockwise") { preview.refresh() }.labelStyle(.iconOnly)
                }
            }
            Toggle(isOn: $keepMicrophoneWarm) {
                Text("Keep microphone warm between dictations")
                Text("Retains up to half a second of audio in memory before you press the shortcut.")
            }
            
        } header: { Text("Input") } footer: {
            Text("Warm mode keeps the orange microphone indicator on; audio is not saved until recording. With warm mode off, wait for Listening before speaking; first launch and Bluetooth can take longer. Opening a Bluetooth microphone can reduce headphone playback quality.")
        }
        Section {
            LevelMeter(level: preview.level)
                .accessibilityElement().accessibilityLabel("Device input level, loudest channel")
                .accessibilityValue(Text(preview.level, format: .percent.precision(.fractionLength(0))))
            LabeledContent {
                Button(preview.running ? "Stop level preview" : "Preview microphone level") {
                    if preview.running { preview.stop() } else { preview.start(uid: selectedUID) }
                }
                .disabled(permissions.snapshot.microphone != .authorized)
            } label: {
                Text("Device input level · loudest channel")
                if preview.running { Text(preview.ready ? "Receiving device input" : "Waiting for the first audio buffer…") }
            }
            if permissions.snapshot.microphone != .authorized {
                LabeledContent("Microphone access") { Button("Allow microphone…") { permissions.request(.microphone) } }
            }
            if let notice = preview.silenceNotice { Label(notice, systemImage: "mic.slash.fill").foregroundStyle(.red) }
            if let error = preview.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        } header: { Text("Level check") } footer: {
            Text("The preview is local and is not saved. Missing devices fall back to the system default without erasing your saved selection.")
        }
        .onAppear { preview.refresh() }
        .onDisappear { preview.stop(reason: .viewClosed) }
        .onChange(of: selectedUID) { _, uid in if preview.running { preview.stop(reason: .selectionChanged); preview.start(uid: uid) } }
        .onChange(of: permissions.snapshot.microphone) { _, status in if status != .authorized { preview.stop(reason: .permissionLost) } }
    }
}

/// LED-style meter: green, then yellow, then red near clipping.
struct LevelMeter: View {
    let level: Double
    private let segments = 36

    var body: some View {
        HStack(spacing: 2) {
        ForEach(0..<segments, id: \.self) { index in
            let position = Double(index) / Double(segments)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(position < 0.7 ? GoblinBrand.moss : position < 0.9 ? LightState.waiting.color : LightState.problem.color)
                .opacity(level > position ? 1 : 0.13)
        }
        }
        .frame(height: 14)
        .padding(.vertical, 4)
    }
}
