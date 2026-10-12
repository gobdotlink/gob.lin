import AppKit
import GoblinCore
import SwiftUI

@main
struct GoblinApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            GoblinMenu(model: model)
        } label: {
            Image(nsImage: GoblinBrand.menuImage(model.mascotState)).renderingMode(.original)
                .accessibilityLabel("gob.lin " + model.mascotState.rawValue)
        }

        Window("gob.lin Settings", id: "settings") {
            SettingsShell()
        }
        .defaultSize(width: 640, height: 440)

        Window("gob.lin History", id: "history") {
            HistoryShell()
        }
        .defaultSize(width: 720, height: 480)
    }
}

private struct GoblinMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        Button("History") { show("history") }
        Button("Permissions & onboarding…") { model.permissions.showOnboarding() }
        Divider()
        Button("Paste last transcript") { model.pasteLastTranscript() }
            .disabled(!model.canPasteLastTranscript)
        Divider()
        Button("Quit gob.lin") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsShell: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GoblinWordmark()
            Text("Native dictation for your Mac.").foregroundStyle(.secondary)
            Divider()
            LabeledContent("Version", value: GoblinMetadata.version)
            LabeledContent("Speech engine", value: "Awaiting benchmark selection")
            Text("Dictation becomes available after microphone, accessibility, and engine setup.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .background(GoblinBrand.background)
        .tint(GoblinBrand.accent)
        .preferredColorScheme(.dark)
    }
}

private struct HistoryShell: View {
    var body: some View {
        ContentUnavailableView("No dictations yet", systemImage: "text.bubble", description: Text("Your completed dictations will appear here."))
            .padding(28)
    }
}
