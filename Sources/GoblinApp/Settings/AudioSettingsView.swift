import AVFoundation
import GoblinCore
import GoblinEngines
import SwiftUI

typealias InputDevice = AudioInputDevice

@MainActor
final class AudioPreviewModel: ObservableObject {
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

    init(monitorSystem: Bool = true, diagnostics: DiagnosticsModel? = nil) {
        self.diagnostics = diagnostics; self.monitorSystem = monitorSystem
    }

    /// Opens the microphone the ranking chooses now, the same one a dictation would use.
    func start(ranking: MicrophoneRanking) {
        stop(reason: .restart)
        let session = sessionID
        log(.previewRequested)
        guard monitorSystem else { return }
        running = true
        let service = AudioCaptureService.shared
        // Opening the device happens on the capture thread; a stop meanwhile ends whatever it opened.
        preview = Task { [weak self] in
            do {
                let id = try await service.beginPreview(ranking: ranking) { [weak self] event in
                    guard let self, self.sessionID == session, self.running else { return }
                    switch event {
                    case .input(_, let rms):
                        if !self.ready { self.log(.firstBuffer); self.ready = true }
                        self.level = AudioInputDevices.displayLevel(rms: rms)
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
                error = nil
                if let resolution {
                    var details = DevelopmentDetails(reason: resolution.viaSystemDefault ? .systemDefault : .savedDevice)
                    details.resolvedDevice = diagnostics?.developmentLog.deviceID(resolution.device.uid)
                    log(.deviceResolved, details: details)
                    // A higher-ranked microphone was away or silenced by the lid.
                    if resolution.position > 0 { log(.deviceFallback, details: DevelopmentDetails(reason: .deviceUnavailable)) }
                }
                log(.engineStarted)
                if diagnostics?.activeFailures[.microphone] == .microphoneCaptureFailed || diagnostics?.activeFailures[.microphone] == .microphoneMuted { diagnostics?.resolve(.microphone) }
                return id
            } catch {
                guard let self, self.sessionID == session else { return nil }
                running = false
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
    @ObservedObject var microphones: MicrophonesModel
    @AppStorage("audio.keepMicrophoneWarm") private var keepMicrophoneWarm = false

    var body: some View {
        let entries = Array(microphones.ranking.entries.enumerated()), line = microphones.ranking.line
        Section {
            ForEach(entries.prefix(line + 1), id: \.element.id) { MicrophoneRow(entry: $1, index: $0, microphones: microphones) }
            status
        } header: { Text("Microphones") } footer: {
            Text("Drag to reorder. I use the highest one that's connected.")
        }
        if entries.count > line + 1 {
            Section {
                ForEach(entries.dropFirst(line + 1), id: \.element.id) { MicrophoneRow(entry: $1, index: $0, microphones: microphones) }
            } header: { Text("Only when picked") }
        }
        Section {
            Toggle(isOn: $keepMicrophoneWarm) {
                Text("Keep microphone warm between dictations")
                Text("Retains up to half a second of audio in memory before you press the shortcut.")
            }
        } header: { Text("Input") } footer: {
            Text("Warm mode keeps the orange microphone indicator on; audio is not saved until recording. Bluetooth microphones are never kept warm, so headphones keep their full sound between dictations. With warm mode off, wait for Listening before speaking; first launch and Bluetooth can take longer.")
        }
        Section {
            LevelMeter(level: preview.level)
                .accessibilityElement().accessibilityLabel("Device input level, loudest channel")
                .accessibilityValue(Text(preview.level, format: .percent.precision(.fractionLength(0))))
            LabeledContent {
                Button(preview.running ? "Stop level preview" : "Preview microphone level") {
                    if preview.running { preview.stop() } else { preview.start(ranking: microphones.ranking) }
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
            Text("The preview opens the microphone in use. It's local and is not saved.")
        }
        .onDisappear { preview.stop(reason: .viewClosed) }
        .onChange(of: microphones.choice) { if preview.running { preview.stop(reason: .selectionChanged); preview.start(ranking: microphones.ranking) } }
        .onChange(of: permissions.snapshot.microphone) { _, status in if status != .authorized { preview.stop(reason: .permissionLost) } }
    }

    @ViewBuilder private var status: some View {
        if let device = microphones.inUse {
            if let passed = microphones.passedOver {
                StatusRow(.ready, Text(passed.lidClosed ? "I'm using \(device.name) while the lid is closed."
                                                       : "I'm using \(device.name) until \(passed.entry.name) connects."))
            } else {
                StatusRow(.ready, Text("I'm using \(device.name)."))
            }
        } else {
            StatusRow(.problem, Text("I can't find a microphone to use."))
        }
    }
}

/// One ranked microphone, or the System Default line. Rows drag onto each other; the menu does the
/// same moves for the keyboard and VoiceOver.
private struct MicrophoneRow: View {
    let entry: MicrophoneRanking.Entry
    let index: Int
    @ObservedObject var microphones: MicrophonesModel
    /// Dragged in place of the line's empty UID.
    private static let lineToken = "gob.lin.system-default"

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                StatusLight(state: light)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.isSystemDefault ? "System Default" : microphones.device(entry.uid)?.name ?? entry.name)
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Menu {
                if canUseNow { Button("Use Now") { microphones.pick(entry.uid) } }
                Button("Move Up") { move(to: index - 1) }.disabled(index == 0)
                Button("Move Down") { move(to: index + 1) }.disabled(index == ranking.entries.count - 1)
                if !entry.isSystemDefault {
                    if index < ranking.line { Button("Use Only When Picked") { move(to: ranking.line) } }
                    else { Button("Use Automatically") { move(to: ranking.line) } }
                    if device == nil {
                        Divider()
                        Button("Forget") { microphones.forget(entry.uid) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for \(entry.isSystemDefault ? "System Default" : entry.name)")
        }
        .contentShape(.rect)
        .draggable(entry.isSystemDefault ? Self.lineToken : entry.uid)
        .dropDestination(for: String.self) { items, _ in
            let uid = items.first == Self.lineToken ? "" : items.first
            guard let from = ranking.entries.firstIndex(where: { $0.uid == uid }), from != index else { return false }
            move(from, to: index)
            return true
        }
    }

    private var ranking: MicrophoneRanking { microphones.ranking }
    private var device: InputDevice? { microphones.device(entry.uid) }
    private var inUse: Bool {
        guard let choice = microphones.choice else { return false }
        return entry.isSystemDefault ? choice.viaSystemDefault : !choice.viaSystemDefault && choice.uid == entry.uid
    }
    private var canUseNow: Bool {
        guard !inUse else { return false }
        return entry.isSystemDefault ? microphones.defaultUID != nil : device.map { !$0.silencedByLid } ?? false
    }

    private var light: LightState {
        if inUse { return .ready }
        return device?.silencedByLid == true ? .waiting : .off
    }

    private var caption: String {
        if entry.isSystemDefault {
            return microphones.defaultUID.flatMap(microphones.device).map { "macOS: \($0.name)" } ?? "macOS has no input selected"
        }
        let state = inUse ? "In use" : device == nil ? "Not connected" : device!.silencedByLid ? "Lid closed" : "Connected"
        let kind = (device?.kind ?? entry.kind)?.caption ?? ""
        return kind.isEmpty ? state : "\(kind) · \(state)"
    }

    /// Onto a row below, the moved one takes that row's place; onto a row above, it goes just before it.
    private func move(_ from: Int? = nil, to target: Int) {
        let from = from ?? index
        guard ranking.entries.indices.contains(target) || target == ranking.entries.count else { return }
        microphones.move(fromOffsets: [from], toOffset: from < target ? target + 1 : target)
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
