import SwiftUI

struct OverlaySettingsView: View {
    let overlay: OverlayController
    @AppStorage("overlayPosition") private var position = OverlayPosition.bottom.rawValue
    @AppStorage("overlay.milestones") private var milestones = true

    var body: some View {
        Section {
            Picker("Corner", selection: $position) {
                Text("Bottom right, above the Dock").tag(OverlayPosition.bottom.rawValue)
                Text("Top right, below the menu bar").tag(OverlayPosition.top.rawValue)
            }
            .pickerStyle(.radioGroup)
            StatusRow(.ready, Text("If your cursor is in that corner, I use the left side instead.")) {
                Button("Preview") {
                    overlay.position = OverlayPosition(rawValue: position) ?? .bottom
                    let session = overlay.begin { overlay.hide() }
                    overlay.update(.listening, committed: "Your words show up here as you talk.", level: 0.45, session: session)
                    overlay.hide(after: 4, session: session)
                }
            }
        } header: { Text("Where it sits") }
        Section {
            Toggle(isOn: $milestones) {
                Text("Celebrate milestones")
                Text("A one-time note at 1,000, 10,000, 100,000 and a million words.")
            }
        } header: { Text("Moments") }
        .onChange(of: position) { _, value in overlay.position = OverlayPosition(rawValue: value) ?? .bottom }
    }
}
