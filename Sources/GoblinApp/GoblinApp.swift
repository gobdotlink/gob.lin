import AppKit
import GoblinCore
import SwiftUI

@main
struct GoblinApp: App {
    @StateObject private var model = AppModel()
    @State private var popoverHeight: CGFloat = 0
    @NSApplicationDelegateAdaptor(GoblinApplicationDelegate.self) private var lifecycle

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        // The sidebar is a fixed 200 pt. AppKit restores a saved split width past SwiftUI's
        // maximum, so a width saved by an older build would stick.
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames settings, SidebarNavigationSplitView")
    }

    var body: some Scene {
        let _ = attachLifecycle()
        MenuBarExtra {
            MenuPopover(model: model)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { popoverHeight = $0 }
                .background(PopoverWindowFit(height: popoverHeight))
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("gob.lin", id: "settings") {
            SettingsView(model: model, speechModels: model.speechModels)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentSize)
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
