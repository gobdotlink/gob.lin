import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import GoblinCore
import os
import SwiftUI

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var environment = DiagnosticEnvironment()
    @Published private(set) var activeFailures: [DiagnosticArea: DiagnosticFailure] = [:]
    @Published private(set) var events: [DiagnosticEvent] = []
    @Published private(set) var latestTimings: DictationTimings?
    @Published private(set) var copyMessage: String?

    var hasWarning: Bool { !activeFailures.isEmpty }
    var warnings: [DiagnosticFailure] { DiagnosticArea.allCases.compactMap { activeFailures[$0] } }
    var warningMessage: String? {
        events.reversed().first { activeFailures[$0.failure.area] == $0.failure }?.failure.message ?? warnings.first?.message
    }

    init() { refresh() }

    func report(_ failure: DiagnosticFailure) {
        guard activeFailures[failure.area] != failure else { return }
        activeFailures[failure.area] = failure
        events.append(DiagnosticEvent(failure: failure))
        if events.count > DiagnosticsReport.maximumEvents { events.removeFirst(events.count - DiagnosticsReport.maximumEvents) }
        Logger(subsystem: GoblinMetadata.bundleIdentifier + "." + failure.area.rawValue, category: "failure")
            .error("\(failure.message, privacy: .public)")
    }

    func resolve(_ area: DiagnosticArea) { activeFailures.removeValue(forKey: area) }

    func recordTimings(_ timings: DictationTimings) {
        latestTimings = timings
        let message = DiagnosticsReport.timingLines(timings).joined(separator: " · ")
        Logger(subsystem: GoblinMetadata.bundleIdentifier + ".performance", category: "dictation")
            .info("\(message, privacy: .public)")
    }

    func refresh(permissions: PermissionModel.Snapshot? = nil, secureInput: Bool? = nil, engineStatus: DiagnosticEngineStatus? = nil) {
        let microphone = permissions?.microphone ?? AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibility = permissions?.accessibility ?? AXIsProcessTrusted()
        let inputMonitoring = permissions?.inputMonitoring ?? CGPreflightListenEventAccess()
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        environment = DiagnosticEnvironment(microphonePermission: Self.permissionStatus(microphone),
            accessibilityPermission: accessibility ? .granted : .denied,
            inputMonitoringPermission: inputMonitoring ? .granted : .denied,
            microphoneNames: discovery.devices.map(\.localizedName),
            defaultMicrophoneName: AVCaptureDevice.default(for: .audio)?.localizedName,
            secureInput: secureInput ?? IsSecureEventInputEnabled(),
            engineStatus: engineStatus ?? environment.engineStatus)
        if microphone != .authorized { report(.microphonePermissionMissing) }
        else if environment.microphoneNames.isEmpty { report(.microphoneUnavailable) }
        else if [.microphonePermissionMissing, .microphoneUnavailable].contains(activeFailures[.microphone]) { resolve(.microphone) }
        if !accessibility || !inputMonitoring { report(.requiredPermissionsMissing) }
        else if activeFailures[.permissions] == .requiredPermissionsMissing { resolve(.permissions) }
        if environment.secureInput { report(.secureInputEnabled) }
        else if activeFailures[.secureInput] == .secureInputEnabled { resolve(.secureInput) }
    }

    func copyDiagnostics(includeDeviceNames: Bool = false) {
        let report = DiagnosticsReport.render(environment: environment, activeFailures: warnings,
            events: events, timings: latestTimings, includeDeviceNames: includeDeviceNames)
        NSPasteboard.general.clearContents()
        copyMessage = NSPasteboard.general.setString(report, forType: .string) ? "Diagnostics copied." : "The clipboard could not accept diagnostics. Try again."
    }

    func clearRecentErrors() { events.removeAll() }

    private static func permissionStatus(_ value: AVAuthorizationStatus) -> DiagnosticPermissionStatus {
        switch value {
        case .authorized: .granted
        case .notDetermined: .notRequested
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
}
