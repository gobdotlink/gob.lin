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
        .windowResizability(.contentSize)

    }

    private func attachLifecycle() { lifecycle.model = model }
}

private struct GoblinMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuStatus(hotkeys: model.hotkeys, state: model.mascotState)
        if let warning = model.diagnostics.warningMessage {
            Label(warning, systemImage: "exclamationmark.triangle")
        }
        Divider()
        Button("Paste last transcript", systemImage: "doc.on.clipboard") { model.pasteLastTranscript() }
            .disabled(!model.canPasteLastTranscript)
        ClipboardRecoveryMenu(service: model.insertion)
        Divider()
        Button("History", systemImage: "clock") { model.settingsSelection = .history; show("settings") }
        Button("Insights", systemImage: "chart.bar.xaxis") { model.settingsSelection = .insights; show("settings") }
        Button("Settings…", systemImage: "gearshape") { show("settings") }
            .keyboardShortcut(",")
        Divider()
        Button("Permissions & onboarding…", systemImage: "hand.raised") { model.permissions.showOnboarding() }
        Button("Diagnostics…", systemImage: "stethoscope") { model.settingsSelection = .diagnostics; show("settings") }
        Button("Copy diagnostics", systemImage: "doc.on.doc") { model.diagnostics.copyDiagnostics() }
        Divider()
        if let version = model.updates.availableVersion {
            Button("Install v\(version) & relaunch", systemImage: "arrow.down.circle") { model.updates.install() }
                .disabled(model.updates.isBusy || !model.canInstallUpdate)
        }
        Button(model.updates.isBusy ? model.updates.status : "Check for updates…", systemImage: "arrow.clockwise") {
            model.settingsSelection = .about
            show("settings")
            model.updates.check()
        }.disabled(model.updates.isBusy)
        Divider()
        Button("Quit gob.lin", systemImage: "power") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// First menu line: what gob.lin is doing right now.
private struct MenuStatus: View {
    @ObservedObject var hotkeys: HotkeyService
    let state: MascotState

    var body: some View {
        switch state {
        case .idle: Text("Ready · hold \(hotkeys.shortcut.label) to talk")
        case .recording: Text("Dictating…")
        case .transcribing: Text("Transcribing…")
        case .warning: Text("Needs attention")
        }
    }
}

private struct ClipboardRecoveryMenu: View {
    @ObservedObject var service: TextInsertionService
    var body: some View {
        if service.hasRecoveryClipboard {
            Button("Restore previous clipboard", systemImage: "arrow.uturn.backward") { service.restorePreviousClipboard() }.disabled(service.busy)
        }
    }
}
