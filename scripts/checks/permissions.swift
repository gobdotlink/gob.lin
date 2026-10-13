import AVFoundation

@main
struct PermissionRecoveryCheck {
    @MainActor static func main() {
        let allowed = PermissionModel.Snapshot(microphone: .authorized, accessibility: true, inputMonitoring: true)
        let model = PermissionModel(snapshot: allowed, monitorSystem: false)
        var retries = 0
        var callbacks: [String] = []
        model.onRetry = { retries += 1 }
        model.onRevocation = { callbacks.append("revoked:\($0.rawValue)") }
        model.onChange = { _, _ in callbacks.append("changed") }

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

        for permission in [PermissionModel.Permission.microphone, .accessibility, .inputMonitoring] {
            var revoked = allowed
            switch permission {
            case .microphone: revoked.microphone = .denied
            case .accessibility: revoked.accessibility = false
            case .inputMonitoring: revoked.inputMonitoring = false
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
    }
}
