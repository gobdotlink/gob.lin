import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    @State private var token = ""

    var body: some View {
        Section("Updates") {
            Text(updates.status).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Check for updates") { updates.check() }.disabled(updates.isBusy)
                if let version = updates.availableVersion {
                    Button("Install v\(version) & relaunch") { updates.install() }.disabled(updates.isBusy)
                }
                if updates.isBusy { ProgressView().controlSize(.small) }
            }
            if updates.ghAuthenticated {
                Label("Using GitHub CLI authentication", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("For private releases, sign in with gh or save a GitHub token with Contents read access to akalikin/gob.lin.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    SecureField("GitHub token", text: $token)
                    Button("Save token") { updates.saveToken(token); token = "" }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || updates.isBusy)
                    Button("Remove saved token") { updates.saveToken("") }.disabled(updates.isBusy)
                }
            }
            Link("Release notes", destination: URL(string: "https://github.com/akalikin/gob.lin/releases")!)
        }
    }
}
