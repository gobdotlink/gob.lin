import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Let’s get gob.lin ready").font(.largeTitle.bold())
                Text("Three permissions put your voice where your cursor is. Each request starts only when you choose Allow.")
                    .foregroundStyle(.secondary)
                permissionRow(.microphone, title: "Microphone", detail: "Capture your voice during dictation.",
                              granted: permissions.snapshot.microphone == .authorized, icon: "mic")
                permissionRow(.accessibility, title: "Accessibility", detail: "Insert text and handle your dictation shortcut.",
                              granted: permissions.snapshot.accessibility, icon: "hand.raised")
                permissionRow(.inputMonitoring, title: "Input Monitoring", detail: "Recognize Fn and modifier-only shortcuts.",
                              granted: permissions.snapshot.inputMonitoring, icon: "keyboard")
                if permissions.staleAccessibility {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility needs a refresh", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text("The shortcut tap could not start even though access appears enabled. Toggle gob.lin off and on in System Settings, then relaunch. If that fails, reset its grant in Terminal:")
                        Text("tccutil reset Accessibility app.goblin.dictation")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Reopen gob.lin and grant Accessibility again. A reset removes only gob.lin’s grant.")
                    }
                    .padding(14).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                if permissions.lastRevoked != nil {
                    Label("A permission was revoked. Shortcuts and recording have stopped safely.", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
                Divider()
                Label(permissions.snapshot.ready ? "Permissions ready" : "Waiting for permissions",
                      systemImage: permissions.snapshot.ready ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(permissions.snapshot.ready ? .green : .secondary)
                Text("Speech engine setup follows the benchmark. This window checks grants live; no recording starts here.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check again") { permissions.refresh() }
            }
            .padding(28)
        }
    }

    private func permissionRow(_ permission: PermissionModel.Permission, title: String, detail: String,
                               granted: Bool, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Label(granted ? "Allowed" : "Required", systemImage: granted ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(granted ? .green : .secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Settings" : "Allow") {
                if granted { permissions.openSettings(permission) } else { permissions.request(permission) }
            }
            .accessibilityLabel("\(granted ? "Open settings for" : "Allow") \(title)")
        }
        .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
