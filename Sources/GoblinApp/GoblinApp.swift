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

        Window("gob.lin Dictionary", id: "dictionary") {
            DictionarySettingsView()
        }
        .defaultSize(width: 720, height: 460)

        Window("gob.lin Tone", id: "tone") {
            ToneSettingsView()
        }
        .defaultSize(width: 600, height: 480)

        Window("gob.lin AI Cleanup", id: "rewrite") {
            RewriteSettingsView()
        }
        .defaultSize(width: 640, height: 620)

        Window("gob.lin History", id: "history") {
            HistoryView(model: model.history)
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
        Button("Dictionary…") { show("dictionary") }
        Button("Tone…") { show("tone") }
        Button("AI cleanup…") { show("rewrite") }
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
