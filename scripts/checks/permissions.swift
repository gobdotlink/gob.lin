import AVFoundation
import Combine
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
        let allowed = PermissionModel.Snapshot(microphone: .authorized, accessibility: true, inputMonitoring: false)
        let model = PermissionModel(snapshot: allowed, monitorSystem: false)
        var retries = 0
        var callbacks: [String] = []
        model.onRetry = { retries += 1 }
        model.onRevocation = { callbacks.append("revoked:\($0.rawValue)") }
        model.onChange = { _, _ in callbacks.append("changed") }

        var publications = 0
        let publication = model.$snapshot.dropFirst().sink { _ in publications += 1 }
        model.updateSnapshot(allowed)
        precondition(publications == 0 && callbacks.isEmpty, "The once-a-second poll must not republish an unchanged snapshot")
        publication.cancel()

        var listenChanged = allowed
        listenChanged.inputMonitoring = true
        model.updateSnapshot(listenChanged)
        precondition(model.snapshot.ready && model.lastRevoked == nil && callbacks == ["changed"],
            "Informational listen-access changes must not revoke required grants")
        callbacks.removeAll()
        model.updateSnapshot(allowed)
        precondition(model.snapshot.ready && model.lastRevoked == nil && callbacks == ["changed"],
            "Listen-access revocation must remain informational")
        callbacks.removeAll()

        model.reportTapFailure(.creationFailed)
        precondition(model.snapshot == allowed && model.snapshot.ready)
        precondition(model.tapFailure == .creationFailed, "A tap failure must not rewrite a permission status")
        model.checkAgain()
        precondition(retries == 1 && callbacks.isEmpty, "Unchanged grants must still allow an explicit retry")
        model.reportTapWorking()
        precondition(model.tapFailure == nil)
        model.reportTapFailure(.runLoopSourceFailed)
        precondition(model.tapFailure == .runLoopSourceFailed, "Run-loop failure must remain distinct from creation failure")
        model.reportTapWorking()

        for permission in [PermissionModel.Permission.microphone, .accessibility] {
            var revoked = allowed
            switch permission {
            case .microphone: revoked.microphone = .denied
            case .accessibility: revoked.accessibility = false
            }
            callbacks.removeAll()
            model.updateSnapshot(revoked)
            precondition(callbacks == ["revoked:\(permission.rawValue)", "changed"], "Stop services before grant-change callbacks")
            precondition(model.lastRevoked == permission && !model.snapshot.ready)
            model.updateSnapshot(revoked)
            precondition(callbacks.count == 2, "Unchanged status must not repeat revocation callbacks")
            model.updateSnapshot(allowed)
            precondition(model.lastRevoked == nil && model.snapshot.ready)
        }
        for (status, expected) in [(AVAuthorizationStatus.notDetermined, "not_determined"), (.denied, "denied"),
                                   (.restricted, "restricted"), (.authorized, "authorized")] {
            var snapshot = allowed
            snapshot.microphone = status
            precondition(snapshot.diagnosticFields["microphone"] == expected)
        }
        var denied = allowed
        denied.accessibility = false
        model.updateSnapshot(denied)
        model.reportTapFailure(.creationFailed)
        precondition(!model.snapshot.accessibility && model.tapFailure == .creationFailed)
        model.stop()
        print("Permission recovery probes passed (synthetic status only; no TCC, UI, or microphone access).")
        print("Permission checks passed: 16 readiness combinations, Accessibility warning recovery, microphone and Secure Input warnings, informational listen access.")
    }
}
