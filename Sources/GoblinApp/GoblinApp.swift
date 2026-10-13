import AppKit
import GoblinCore
import SwiftUI

@main
struct GoblinApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(GoblinApplicationDelegate.self) private var lifecycle

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
    }

    var body: some Scene {
        let _ = attachLifecycle()
        MenuBarExtra {
            GoblinMenu(model: model)
        } label: {
            Image(nsImage: GoblinBrand.menuImage(model.mascotState)).renderingMode(.original)
                .accessibilityLabel("gob.lin " + model.mascotState.rawValue)
        }

        Window("gob.lin Settings", id: "settings") {
            SettingsView(model: model, speechModels: model.speechModels)
        }
        .defaultSize(width: 940, height: 720)

        Window("gob.lin History", id: "history") {
            HistoryView(model: model.history)
        }
        .defaultSize(width: 820, height: 620)

    }

    private func attachLifecycle() { lifecycle.model = model }
}

private struct GoblinMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        Button("History") { show("history") }
        Button("Permissions & onboarding…") { model.permissions.showOnboarding() }
        if let warning = model.diagnostics.warningMessage {
            Text(warning)
        }
        Button("Diagnostics…") { model.settingsSelection = .diagnostics; show("settings") }
        Button("Copy diagnostics") { model.diagnostics.copyDiagnostics() }
        Divider()
        Button("Paste last transcript") { model.pasteLastTranscript() }
            .disabled(!model.canPasteLastTranscript)
        ClipboardRecoveryMenu(service: model.insertion)
        Divider()
        Button("Quit gob.lin") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ClipboardRecoveryMenu: View {
    @ObservedObject var service: TextInsertionService
    var body: some View {
        if service.hasRecoveryClipboard {
            Button("Restore previous clipboard") { service.restorePreviousClipboard() }.disabled(service.busy)
        }
    }
}
