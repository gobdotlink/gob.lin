import SwiftUI

struct OverlaySettingsView: View {
    let overlay: OverlayController
    @AppStorage("overlayPosition") private var position = OverlayPosition.bottom.rawValue

    var body: some View {
        Section {
            Picker("Position", selection: $position) {
                Text("Bottom, above the Dock").tag(OverlayPosition.bottom.rawValue)
                Text("Top, below the menu bar").tag(OverlayPosition.top.rawValue)
            }
            .pickerStyle(.radioGroup).tint(GoblinBrand.tint)
            LabeledContent("Try it") {
                Button("Preview overlay") {
                    overlay.position = OverlayPosition(rawValue: position) ?? .bottom
                    let session = overlay.begin { overlay.hide() }
                    overlay.update(.listening, committed: "Your words appear here as you speak.", level: 0.45, session: session)
                }
            }
        } header: { Text("Dictation overlay") } footer: {
            Text("The overlay follows the screen with your pointer and stays visible across Spaces and full-screen apps.")
        }
        .onChange(of: position) { _, value in overlay.position = OverlayPosition(rawValue: value) ?? .bottom }
    }
}
