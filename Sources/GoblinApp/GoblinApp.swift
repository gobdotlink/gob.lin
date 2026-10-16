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
        // Both sidebars are a fixed 200 pt. AppKit restores a saved split width past SwiftUI's
        // maximum, so a width saved by an older build would stick.
        for window in ["history", "settings"] {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(window), SidebarNavigationSplitView")
        }
    }

    var body: some Scene {
        let _ = attachLifecycle()
        MenuBarExtra {
            MenuPopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("gob.lin Settings", id: "settings") {
            SettingsView(model: model, speechModels: model.speechModels)
        }
        .defaultSize(width: 940, height: 720)
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryWindow(model: model)
        }
        .defaultSize(width: 1100, height: 720)
    }

    private func attachLifecycle() { lifecycle.model = model }
}

/// Today's icon, unchanged. It also hands the scene's window opener to the model, because the
/// label exists from launch while the popover may never have been opened.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Drawn once per state: building it reads the artwork from disk.
    @MainActor private static var images: [MascotState: NSImage] = [:]

    var body: some View {
        Image(nsImage: image).renderingMode(.original)
            .accessibilityLabel("gob.lin " + model.mascotState.rawValue)
            .onAppear {
                model.openWindow = { id in
                    openWindow(id: id)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    private var image: NSImage {
        if let image = Self.images[model.mascotState] { return image }
        let image = GoblinBrand.menuImage(model.mascotState)
        Self.images[model.mascotState] = image
        return image
    }
}
