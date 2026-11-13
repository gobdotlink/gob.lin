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
    let developmentLog: DevelopmentLog
    private let readSystemEnvironment: Bool

    var hasWarning: Bool { !activeFailures.isEmpty }
    var warnings: [DiagnosticFailure] { DiagnosticArea.allCases.compactMap { activeFailures[$0] } }
    var warningMessage: String? {
        events.reversed().first { activeFailures[$0.failure.area] == $0.failure }?.failure.message ?? warnings.first?.message
    }

    init(environment: DiagnosticEnvironment? = nil, logDirectory: URL? = nil) {
        developmentLog = DevelopmentLog(directory: logDirectory)
        developmentLog.record(.appStarted, area: .application)
        readSystemEnvironment = environment == nil
        if let environment { self.environment = environment }
        else { refresh() }
    }

    func report(_ failure: DiagnosticFailure, operation: UUID? = nil) {
        if operation == nil, activeFailures[failure.area] == failure { return }
        var details = DevelopmentDetails()
        details.failure = failure
        developmentLog.record(.failure, area: failure.area, severity: .error, operation: operation, details: details)
        guard activeFailures[failure.area] != failure else { return }
        activeFailures[failure.area] = failure
        events.append(DiagnosticEvent(failure: failure))
        if events.count > DiagnosticsReport.maximumEvents { events.removeFirst(events.count - DiagnosticsReport.maximumEvents) }
        Logger(subsystem: GoblinMetadata.bundleIdentifier + "." + failure.area.rawValue, category: "failure")
            .error("\(failure.message, privacy: .public)")
    }

    func resolve(_ area: DiagnosticArea) {
        if activeFailures.removeValue(forKey: area) != nil { developmentLog.record(.recovered, area: area) }
    }

    func recordTimings(_ timings: DictationTimings) {
        latestTimings = timings
        var details = DevelopmentDetails()
        details.timings = timings
        developmentLog.record(.timings, area: .application, details: details)
        let message = DiagnosticsReport.timingLines(timings).joined(separator: " · ")
        Logger(subsystem: GoblinMetadata.bundleIdentifier + ".performance", category: "dictation")
            .info("\(message, privacy: .public)")
    }

    typealias Microphones = (names: [String], defaultName: String?)

    /// Device discovery goes through CoreAudio, which can stall; callers on the main actor fetch it elsewhere.
    nonisolated static func discoverMicrophones() -> Microphones {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return (discovery.devices.map(\.localizedName), AVCaptureDevice.default(for: .audio)?.localizedName)
    }

    func refresh(permissions: PermissionModel.Snapshot? = nil, secureInput: Bool? = nil, engineStatus: DiagnosticEngineStatus? = nil,
                 microphones: Microphones? = nil) {
        guard readSystemEnvironment else { return }
        let microphone = permissions?.microphone ?? AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibility = permissions?.accessibility ?? AXIsProcessTrusted()
        let inputMonitoring = permissions?.inputMonitoring ?? CGPreflightListenEventAccess()
        let microphones = microphones ?? Self.discoverMicrophones()
        let previous = environment
        let current = DiagnosticEnvironment(microphonePermission: Self.permissionStatus(microphone),
            accessibilityPermission: accessibility ? .granted : .denied,
            inputMonitoringPermission: inputMonitoring ? .granted : .denied,
            microphoneNames: microphones.names,
            defaultMicrophoneName: microphones.defaultName,
            secureInput: secureInput ?? IsSecureEventInputEnabled(),
            engineStatus: engineStatus ?? environment.engineStatus,
            historySync: environment.historySync)
        if current != previous { environment = current }
        if previous.microphonePermission != environment.microphonePermission || previous.accessibilityPermission != environment.accessibilityPermission || previous.inputMonitoringPermission != environment.inputMonitoringPermission {
            var details = DevelopmentDetails()
            details.microphone = environment.microphonePermission
            details.accessibility = environment.accessibilityPermission
            details.inputMonitoring = environment.inputMonitoringPermission
            developmentLog.record(.permissionSnapshot, area: .permissions, details: details)
        }
        if previous.secureInput != environment.secureInput {
            var details = DevelopmentDetails()
            details.secureInput = environment.secureInput
            developmentLog.record(.secureInputChanged, area: .secureInput, details: details)
        }
        if microphone != .authorized { report(.microphonePermissionMissing) }
        else if environment.microphoneNames.isEmpty { report(.microphoneUnavailable) }
        else if [.microphonePermissionMissing, .microphoneUnavailable].contains(activeFailures[.microphone]) { resolve(.microphone) }
        if !accessibility { report(.requiredPermissionsMissing) }
        else if activeFailures[.permissions] == .requiredPermissionsMissing { resolve(.permissions) }
        if environment.secureInput { report(.secureInputEnabled) }
        else if activeFailures[.secureInput] == .secureInputEnabled { resolve(.secureInput) }
    }

    func setHistorySync(_ status: DiagnosticHistorySync) {
        environment.historySync = status
    }

    func copyDiagnostics(includeDeviceNames: Bool = false) {
        let report = diagnosticsText(includeDeviceNames: includeDeviceNames)
        NSPasteboard.general.clearContents()
        copyMessage = NSPasteboard.general.setString(report, forType: .string) ? "Diagnostics copied." : "The clipboard could not accept diagnostics. Try again."
    }

    private func diagnosticsText(includeDeviceNames: Bool) -> String {
        let report = DiagnosticsReport.render(environment: environment, activeFailures: warnings,
            events: events, timings: latestTimings, includeDeviceNames: includeDeviceNames)
        let build = developmentLog.build
        return report + "\n\nDevelopment logs: \(logStatus)\nBuild: \(build.build) (\(build.configuration)) · \(build.buildID)\nSource: \(build.sourceRevision) · modified: \(build.sourceModified)\nBuilt at: \(build.builtAt)\nLaunch: \(developmentLog.launchID) · PID: \(getpid())\n" + crashReportSummary
    }

    var logStatus: String { developmentLog.lastError ?? "Up to 3 MiB of lifecycle events are kept locally across launches." }
    private var crashDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true) }
    private var crashReports: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: crashDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Array(urls.filter { url in
            let name = url.lastPathComponent
            return (name.hasPrefix("GoblinApp-") || name.hasPrefix("GoblinApp_") || name.hasPrefix("Goblin-")) && ["ips", "crash"].contains(url.pathExtension)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(5))
    }
    private var crashReportSummary: String {
        let candidates = crashReports.map { $0.lastPathComponent }
        return "\nmacOS crash report candidates (match timestamp and PID):\n" + (candidates.isEmpty ? "None found" : candidates.joined(separator: "\n")) + "\nFull crash reports are excluded; inspect before sharing separately."
    }

    func revealLogs() {
        if !NSWorkspace.shared.open(developmentLog.directory) { copyMessage = "Log folder could not be opened. " + logStatus }
    }

    func revealCrashReports() {
        if let latest = crashReports.first { NSWorkspace.shared.activateFileViewerSelecting([latest]) }
        else { NSWorkspace.shared.open(crashDirectory) }
    }

    func exportLogs(includeDeviceNames: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "goblin-diagnostics.txt"
        panel.title = "Export recent development logs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportLogs(to: url, includeDeviceNames: includeDeviceNames)
            copyMessage = "Diagnostics and recent logs exported."
        } catch { copyMessage = "Logs could not be exported. Check the destination and try again." }
    }

    func exportLogs(to url: URL, includeDeviceNames: Bool = false) throws {
        let text = diagnosticsText(includeDeviceNames: includeDeviceNames) + "\n\nRecent development events (oldest first):\n" + (try developmentLog.recentText())
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
