import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    @State private var token = ""

    var body: some View {
        if needed {
            Section {
                // Amber only when there is something to do: an update to install.
                StatusRow(failed ? .problem : updates.availableVersion == nil ? .off : .waiting, Text(updates.status)) {
                    if updates.isBusy { ProgressView().controlSize(.small) }
                    else if let version = updates.availableVersion {
                        Button("Install v\(version) & Relaunch") { updates.install() }.prominent()
                    }
                }
                if !updates.ghAuthenticated {
                    LabeledContent {
                        HStack(spacing: 8) {
                            SecureField("GitHub token", text: $token).labelsHidden().frame(width: 190)
                            Button("Save") { updates.saveToken(token); token = "" }
                                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || updates.isBusy)
                            Button("Remove") { updates.saveToken("") }.disabled(updates.isBusy)
                        }
                    } label: {
                        Text("GitHub token")
                        Text("For private releases. Sign in with gh, or save a token with Contents read access to gobdotlink/gob.lin.")
                    }
                }
                LabeledContent("Release notes") {
                    Link("Open on GitHub", destination: URL(string: "https://github.com/gobdotlink/gob.lin/releases")!)
                        .foregroundStyle(GoblinBrand.mossText)
                }
            } header: { CapsHeader("Updates") }
        }
    }

    private var failed: Bool { if case .failed = updates.phase { true } else { false } }

    /// About's version line covers idle, checking and up to date.
    private var needed: Bool {
        switch updates.phase {
        case .idle, .checking, .upToDate: !updates.ghAuthenticated
        default: true
        }
    }
}
