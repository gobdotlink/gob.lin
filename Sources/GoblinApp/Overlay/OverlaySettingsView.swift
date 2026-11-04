import SwiftUI

struct OverlaySettingsView: View {
    let overlay: OverlayController
    @AppStorage("overlayPosition") private var position = OverlayPosition.bottom.rawValue
    @AppStorage("overlay.milestones") private var milestones = true
    @AppStorage("overlay.termSuggestions") private var termSuggestions = true

    var body: some View {
        Section {
            LabeledContent("Corner") {
                Picker("Corner", selection: $position) {
                    Text("Bottom right").tag(OverlayPosition.bottom.rawValue)
                    Text("Top right").tag(OverlayPosition.top.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(GoblinBrand.moss)
            }
            StatusRow(.ready, Text("Bottom right sits above the Dock; top right sits below the menu bar. If your cursor is in that corner, I use the left side instead.")) {
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
            Toggle(isOn: $termSuggestions) {
                Text("Offer words from your fixes")
                Text("When you fix a word I misheard, I ask right away whether to add it to the dictionary.")
            }
        } header: { Text("Moments") }
        .onChange(of: position) { _, value in overlay.position = OverlayPosition(rawValue: value) ?? .bottom }
    }
}
