import SwiftUI

struct InsertionSettingsView: View {
    @ObservedObject var service: TextInsertionService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Text insertion").font(.largeTitle.bold())
            Toggle("Add a trailing space", isOn: $service.trailingSpace)
            Text("Paste last transcript: ⌘⌥⇧V, or the menu bar item.").foregroundStyle(.secondary)
            Label(service.status, systemImage: service.busy ? "arrow.down.doc" : "text.cursor")
                .fixedSize(horizontal: false, vertical: true)
            if service.hasRecoveryClipboard {
                Button("Restore previous clipboard") { service.restorePreviousClipboard() }.disabled(service.busy)
                Text("For apps that cannot confirm a paste, gob.lin leaves the transcript on the clipboard. Restore the previous contents after checking that your text arrived.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Your clipboard is restored automatically only after the same focused app exposes the expected inserted text. Clipboard-manager reads alone cannot trigger restoration.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Terminals, Electron editors, browser address bars and remote desktop sessions use paste. Remote apps may need manual clipboard recovery.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(minWidth: 540, maxWidth: 800, minHeight: 360, maxHeight: 650, alignment: .topLeading)
    }
}
