import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: GoblinBrand.sprite("goblin-shut")).resizable().interpolation(.none)
                        .frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Let’s get gob.lin ready").font(.title2.weight(.semibold))
                        Text("Two permissions put your voice where your cursor is. Each request starts only when you choose Allow.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                permissionRow(.microphone, title: "Microphone", detail: "Capture your voice during dictation.",
                              granted: permissions.snapshot.microphone == .authorized, icon: "mic")
                permissionRow(.accessibility, title: "Accessibility", detail: "Insert text and handle your dictation shortcut.",
                              granted: permissions.snapshot.accessibility, icon: "accessibility")
            } header: { Text("Permissions") } footer: {
                Text("This window checks grants live; no recording starts here.")
            }
            if let failure = permissions.tapFailure {
                Section {
                    Label {
                        Text("Shortcut unavailable")
                        if failure == .runLoopSourceFailed {
                            Text("The shortcut tap was created, but its run-loop source could not be prepared. Quit and reopen gob.lin. If it persists, collect development diagnostics.")
                        } else if !permissions.snapshot.accessibility {
                            Text("macOS currently reports Accessibility as not allowed. Allow the running app in System Settings, return here, and choose Check again.")
                        } else {
                            Text("macOS reports Accessibility allowed, but the shortcut tap could not be created. Choose Check again to retry. If it still fails, quit and reopen the same signed app and collect development diagnostics. This failure alone does not establish a stale grant.")
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            if permissions.lastRevoked != nil {
                Section {
                    Label("A permission was revoked. Shortcuts and recording have stopped safely.", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    Label(permissions.snapshot.ready ? "Permissions ready" : "Waiting for permissions",
                          systemImage: permissions.snapshot.ready ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(permissions.snapshot.ready ? GoblinBrand.accent : .secondary)
                    Spacer()
                    Button("Check again") { permissions.checkAgain() }
                }
                DisclosureGroup("Running app") {
                    Text(PermissionModel.launchIdentity["bundle_path"] ?? "Unknown bundle")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } footer: {
                Text("If a System Settings toggle is on but its row is not Allowed, quit and reopen the same signed app. Check that the entry belongs to this app rather than an older build. Some permission changes require a relaunch.")
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .background(GoblinBrand.background)
        .preferredColorScheme(.dark)
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
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Label(statusLabel(permission), systemImage: granted ? "checkmark.circle.fill" : "circle")
                .font(.callout).foregroundStyle(granted ? GoblinBrand.accent : .secondary)
            if granted || (permission == .microphone && permissions.snapshot.microphone != .notDetermined) {
                Button("Settings") { permissions.openSettings(permission) }
                    .accessibilityLabel("Open settings for \(title)")
            } else {
                Button("Allow") { permissions.request(permission) }
                    .buttonStyle(.borderedProminent).tint(GoblinBrand.tint)
                    .accessibilityLabel("Allow \(title)")
            }
        }
        .padding(.vertical, 2)
    }
}
