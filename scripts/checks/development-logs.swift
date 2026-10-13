import Foundation
import GoblinCore

// Console-only export integration with fixture environment; no app, mic, clipboard, or TCC actions.
@main
struct DevelopmentLogsCheck {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-export-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = DiagnosticEnvironment(microphonePermission: .granted, accessibilityPermission: .denied,
            inputMonitoringPermission: .granted, microphoneNames: ["PRIVATE DEVICE NAME"], defaultMicrophoneName: "PRIVATE DEVICE NAME")
        let model = DiagnosticsModel(environment: environment, logDirectory: directory.appendingPathComponent("logs"))
        let launch = model.developmentLog.launchID.uuidString
        model.report(.rewrite(.configuration("PRIVATE CREDENTIAL AND TRANSCRIPT")))
        for _ in 0..<5 { model.report(.rewriteConfiguration) }
        var text = try model.developmentLog.recentText()
        precondition(text.split(separator: "\n").count == 2, "Repeated active failures must not flood logs")
        model.clearRecentErrors()
        precondition(model.events.isEmpty && model.hasWarning)
        let afterClear = try model.developmentLog.recentText()
        precondition(afterClear == text, "Clearing the UI error list must preserve persistent events")
        model.resolve(.rewrite)
        model.recordTimings(DictationTimings(rewriteMilliseconds: 12))
        let next = DiagnosticsModel(environment: environment, logDirectory: model.developmentLog.directory)
        let export = directory.appendingPathComponent("export.txt")
        try next.exportLogs(to: export)
        text = try String(contentsOf: export, encoding: .utf8)
        precondition(text.contains(launch) && text.contains(next.developmentLog.launchID.uuidString))
        precondition(text.contains("Build:") && text.contains("Source:") && text.contains("macOS crash report candidates"))
        precondition(!text.contains("PRIVATE") && !text.contains("/Users/") && !text.contains("Authorization"))
        let attributes = try FileManager.default.attributesOfItem(atPath: export.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        try next.exportLogs(to: export, includeDeviceNames: true)
        text = try String(contentsOf: export, encoding: .utf8)
        precondition(text.contains("PRIVATE DEVICE NAME") && !text.contains("PRIVATE CREDENTIAL"))
        print("Development export check passed: shared diagnostics, deduplication, retained prior launch, build identity, redaction, explicit device-name opt-in, and private export.")
    }

}
