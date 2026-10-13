import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Let’s get gob.lin ready").font(.largeTitle.bold())
                Text("Two permissions put your voice where your cursor is. Each request starts only when you choose Allow.")
                    .foregroundStyle(.secondary)
                permissionRow(.microphone, title: "Microphone", detail: "Capture your voice during dictation.",
                              granted: permissions.snapshot.microphone == .authorized, icon: "mic")
                permissionRow(.accessibility, title: "Accessibility", detail: "Insert text and handle your dictation shortcut.",
                              granted: permissions.snapshot.accessibility, icon: "hand.raised")
                if let failure = permissions.tapFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Shortcut unavailable", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        if failure == .runLoopSourceFailed {
                            Text("The shortcut tap was created, but its run-loop source could not be prepared. Quit and reopen gob.lin. If it persists, collect development diagnostics.")
                        } else if !permissions.snapshot.accessibility {
                            Text("macOS currently reports Accessibility as not allowed. Allow the running app in System Settings, return here, and choose Check again.")
                        } else {
                            Text("macOS reports Accessibility allowed, but the shortcut tap could not be created. Choose Check again to retry. If it still fails, quit and reopen the same signed app and collect development diagnostics. This failure alone does not establish a stale grant.")
                        }
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
                Text("If a System Settings toggle is on but its row is not Allowed, quit and reopen the same signed app. Check that the entry belongs to this app rather than an older build. Some permission changes require a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Running app") {
                    Text(PermissionModel.launchIdentity["bundle_path"] ?? "Unknown bundle")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("Check again") { permissions.checkAgain() }
            }
            .padding(28)
        }
    }

    private func statusLabel(_ permission: PermissionModel.Permission) -> String {
        if permissions.snapshot.isGranted(permission) { return "Allowed" }
        guard permission == .microphone else { return "Not allowed" }
        switch permissions.snapshot.microphone {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .authorized: return "Allowed"
        @unknown default: return "Unknown"
        }
    }

    private func permissionRow(_ permission: PermissionModel.Permission, title: String, detail: String,
                               granted: Bool, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Label(statusLabel(permission), systemImage: granted ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(granted ? .green : .secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            let opensSettings = granted || (permission == .microphone && permissions.snapshot.microphone != .notDetermined)
            Button(opensSettings ? "Settings" : "Allow") {
                if opensSettings { permissions.openSettings(permission) } else { permissions.request(permission) }
            }
            .accessibilityLabel("\(opensSettings ? "Open settings for" : "Allow") \(title)")
        }
        .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
