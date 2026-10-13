import AVFoundation
import GoblinCore

@main
struct PermissionChecks {
    @MainActor static func main() {
        for microphone in [AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
            for accessibility in [false, true] {
                for inputMonitoring in [false, true] {
                    let snapshot = PermissionModel.Snapshot(microphone: microphone,
                        accessibility: accessibility, inputMonitoring: inputMonitoring)
                    precondition(snapshot.ready == (microphone == .authorized && accessibility),
                        "Readiness must require microphone and Accessibility only")
                }
            }
        }

        // Supplied permission snapshots exercise warning transitions without changing any grants.
        let diagnostics = DiagnosticsModel()
        diagnostics.refresh(permissions: .init(microphone: .authorized, accessibility: false, inputMonitoring: true), secureInput: false)
        precondition(diagnostics.activeFailures[.permissions] == .requiredPermissionsMissing)
        diagnostics.refresh(permissions: .init(microphone: .authorized, accessibility: true, inputMonitoring: false), secureInput: false)
        precondition(diagnostics.activeFailures[.permissions] == nil,
            "Missing Input Monitoring must clear a previous Accessibility warning")
        diagnostics.refresh(permissions: .init(microphone: .denied, accessibility: true, inputMonitoring: false), secureInput: false)
        precondition(diagnostics.activeFailures[.microphone] == .microphonePermissionMissing)
        diagnostics.refresh(permissions: .init(microphone: .authorized, accessibility: false, inputMonitoring: false), secureInput: true)
        precondition(diagnostics.activeFailures[.permissions] == .requiredPermissionsMissing)
        precondition(diagnostics.activeFailures[.secureInput] == .secureInputEnabled)
        precondition(!DiagnosticFailure.requiredPermissionsMissing.message.contains("Input Monitoring"))
        let report = DiagnosticsReport.render(environment: diagnostics.environment,
            activeFailures: diagnostics.warnings, events: [], timings: nil)
        precondition(report.contains("Input Monitoring permission (not required): denied"))
        print("Permission checks passed: 16 readiness combinations, Accessibility warning recovery, microphone and Secure Input warnings, informational listen access.")
    }
}
