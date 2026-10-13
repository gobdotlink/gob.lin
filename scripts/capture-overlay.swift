import AppKit
import Foundation

/// A native fixture using the production view, without microphone capture or UI automation.
@main
struct OverlayCapture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        let overlay = OverlayController()
        let session = overlay.begin { overlay.hide() }
        overlay.update(.listening, committed: "Ship the small things. Keep your hands on the keyboard.",
            tentative: "Let the goblin do the typing.", level: 0.65, session: session)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(800))
                guard app.windows.allSatisfy({ !$0.canBecomeKey }) else {
                    throw CaptureError.focusChanged
                }
                guard let view = app.windows.first(where: { $0.title == "gob.lin Dictation" })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.windowMissing }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.captureFailed }
                let output = CommandLine.arguments.dropFirst().first ?? "docs/screenshots/gob-12-overlay.png"
                try png.write(to: URL(fileURLWithPath: output))
                let next = overlay.begin { overlay.hide() }
                overlay.hide(session: session)
                precondition(overlay.model.phase == .arming, "A stale hide closed a newer session")
                overlay.update(.listening, level: .nan, session: next)
                precondition(overlay.model.audioLevel == 0)
                overlay.hide(session: next)
                overlay.update(.listening, session: next)
                precondition(overlay.model.phase == .hidden, "A canceled session reopened")
                overlay.shutdown()
                print("Native overlay captured; non-key panel, stale hide and non-finite input checks passed.")
            } catch {
                fputs("Overlay capture failed: \(error)\n", stderr)
                exit(1)
            }
            app.terminate(nil)
        }
        app.run()
    }

    enum CaptureError: Error { case focusChanged, windowMissing, captureFailed }
}
