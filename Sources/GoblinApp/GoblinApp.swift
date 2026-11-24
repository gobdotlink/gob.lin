import AppKit
import GoblinCore
import SwiftUI

@main
enum GoblinEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst() == ["--mute-output-while-dictating"] {
            runOutputMuteHelper()
        } else {
            GoblinApp.main()
        }
    }
}

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
        .commands {
            // AppKit's own Quit does nothing while a sheet is up; this one closes the sheet first.
            CommandGroup(replacing: .appTermination) {
                Button("Quit gob.lin") { UpdateChecker.requestTermination() }.keyboardShortcut("q")
            }
        }
    }

    private func attachLifecycle() { lifecycle.model = model }
}

/// The goblin with its state dot, and the headset while a meeting records, optionally with the elapsed time.
/// It also hands the scene's window opener to the model, because the label exists from launch while the popover
/// may never have been opened.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var meetings: MeetingsController
    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()
    /// Drawn once per state: building it reads the artwork from disk.
    @MainActor private static var images: [String: NSImage] = [:]

    init(model: AppModel) {
        self.model = model
        _meetings = ObservedObject(wrappedValue: model.meetings)
    }

    var body: some View {
        let recording = meetings.recording
        HStack(spacing: 4) {
            Image(nsImage: image(headset: recording != nil)).renderingMode(.original)
            if let recording, meetings.showsMenuBarTime {
                Text(MeetingsController.elapsed(now.timeIntervalSince(recording.startedAt))).monospacedDigit()
            }
        }
        // The menu bar redraws the label on a state change, not from a TimelineView. The clock ticks only while it's
        // shown: a recording with the time in the menu bar.
        .task(id: recording != nil && meetings.showsMenuBarTime) {
            guard recording != nil, meetings.showsMenuBarTime else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("gob.lin " + model.mascotState.rawValue + (recording != nil ? ", recording a meeting" : ""))
            .onAppear {
                model.openWindow = { id in
                    openWindow(id: id)
                    NSApp.activate(ignoringOtherApps: true)
                }
                // The last run quit partway through Meetings setup; General opens the setup sheet again.
                if SystemAudioAccess.shared.resumeSetup != nil {
                    model.settingsSelection = .general
                    model.openWindow?("settings")
                }
            }
    }

    private func image(headset: Bool) -> NSImage {
        let key = model.mascotState.rawValue + (headset ? "+headset" : "")
        if let image = Self.images[key] { return image }
        let image = GoblinBrand.menuImage(model.mascotState, headset: headset)
        Self.images[key] = image
        return image
    }
}
