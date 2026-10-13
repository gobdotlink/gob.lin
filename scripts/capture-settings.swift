import AppKit
import GoblinCore
import SwiftUI

/// Production Settings views with isolated synthetic data and no system services.
@main
struct SettingsCapture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        let suite = "app.goblin.settings-capture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DictionaryRepository(url: directory.appendingPathComponent("dictionary.json")).save([
            DictionaryEntry(spelling: "Dev review", aliases: ["day review"]),
            DictionaryEntry(spelling: "gob.lin", aliases: ["goblin"]),
            DictionaryEntry(spelling: "Postgres", aliases: ["post grass"]),
        ])
        defaults.set(try JSONEncoder().encode(HistoryRetention(maximumUnstarredCount: 500, maximumAgeDays: 30)), forKey: "history.retention")
        defaults.set(OverlayPosition.top.rawValue, forKey: "overlayPosition")
        try RewriteSettingsStore.save(RewriteSettings(enabled: false, baseURL: "https://provider.invalid/v1", model: "example-model", cleanup: .light), defaults: defaults)
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false,
            diagnosticEnvironment: DiagnosticEnvironment(microphonePermission: .notRequested,
                accessibilityPermission: .denied, inputMonitoringPermission: .denied,
                microphoneNames: ["Preview microphone"], defaultMicrophoneName: "Preview microphone"))
        precondition(model.overlay.position == .top, "Saved overlay position must apply before Settings or Preview opens")
        let lifecycle = GoblinApplicationDelegate()
        lifecycle.model = model
        app.delegate = lifecycle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 840),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "gob.lin — Settings capture"
        window.contentView = NSHostingView(rootView: SettingsView(model: model).allowsHitTesting(false))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        print("Preview PID \(getpid()), window \(window.windowNumber)")
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots", isDirectory: true)
        var captureFailed = false
        let capture = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
                precondition(model.dictionary.entries.count == 3 && model.dictionary.available)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let phases: [(OverlayPhase, String)] = [(.arming, "arming"), (.listening, "listening"),
                    (.transcribing, "transcribing"), (.polishing, "polishing"), (.error("polish failed — pasted raw"), "error")]
                if !CommandLine.arguments.contains("--transition-only") {
                    let pages: [(SettingsSection, String)] = [(.general, "general"), (.audio, "audio"), (.model, "model"),
                        (.dictionary, "dictionary"), (.rewrite, "rewrite"), (.tone, "tone"), (.history, "history"),
                        (.overlay, "overlay"), (.diagnostics, "diagnostics"), (.about, "about")]
                    precondition(Set(pages.map(\.0)) == Set(SettingsSection.allCases))
                    for (page, name) in pages {
                        model.settingsSelection = page
                        if page == .diagnostics {
                            model.diagnostics.report(.modelUnavailable)
                            model.diagnostics.recordTimings(DictationTimings(asrMilliseconds: 180, rewriteMilliseconds: 12))
                        }
                        try await Task.sleep(for: .milliseconds(700))
                        try snapshot(window, to: destination.appendingPathComponent("gob-22-settings-\(name).png"))
                        print("Captured \(page.rawValue)")
                    }
                    window.title = "gob.lin — Branding and menu capture"
                    window.setContentSize(NSSize(width: 660, height: 760))
                    window.contentView = NSHostingView(rootView: BrandCaptureView(model: model).allowsHitTesting(false))
                    window.center()
                    try await Task.sleep(for: .milliseconds(700))
                    try snapshot(window, to: destination.appendingPathComponent("gob-19-brand-menu-final.png"))
                    print("Captured production wordmark, four status images, and production menu view")
                    window.setContentSize(NSSize(width: 620, height: 370))
                    window.center()
                    for (phase, name) in phases {
                        window.title = "gob.lin — Overlay \(name) capture"
                        let overlay = OverlayModel()
                        overlay.phase = phase
                        overlay.audioLevel = phase == .listening ? 0.65 : 0
                        overlay.committedText = phase == .listening ? "Ship the small things. Keep your hands on the keyboard." : ""
                        overlay.tentativeText = phase == .listening ? "Let the goblin do the typing." : ""
                        window.contentView = NSHostingView(rootView: DictationOverlay(model: overlay)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(GoblinBrand.surface).allowsHitTesting(false))
                        try await Task.sleep(for: .milliseconds(700))
                        try snapshot(window, to: destination.appendingPathComponent("gob-12-overlay-\(name)-final.png"))
                        print("Captured production overlay \(name) view")
                    }
                }
                window.setContentSize(NSSize(width: 620, height: 370))
                window.center()
                let sharedOverlay = OverlayModel()
                let sharedHost = NSHostingView(rootView: DictationOverlay(model: sharedOverlay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(GoblinBrand.surface).allowsHitTesting(false))
                window.contentView = sharedHost
                for (phase, name) in phases {
                    window.title = "gob.lin — Overlay \(name) capture"
                    sharedOverlay.phase = phase
                    sharedOverlay.audioLevel = phase == .listening ? 0.65 : 0
                    sharedOverlay.committedText = phase == .listening ? "Ship the small things. Keep your hands on the keyboard." : ""
                    sharedOverlay.tentativeText = phase == .listening ? "Let the goblin do the typing." : ""
                    try await Task.sleep(for: .milliseconds(700))
                }
                try snapshot(window, to: destination.appendingPathComponent("gob-12-transition-before-redraw.png"), redraw: false)
                invalidateTree(sharedHost)
                sharedHost.layoutSubtreeIfNeeded()
                sharedHost.display()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = sharedHost.bitmapImageRepForCachingDisplay(in: sharedHost.bounds) else { throw CaptureError.screenshot }
                sharedHost.cacheDisplay(in: sharedHost.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.screenshot }
                try png.write(to: destination.appendingPathComponent("gob-12-transition-after-redraw-bitmap.png"))
                try snapshot(window, to: destination.appendingPathComponent("gob-12-transition-after-redraw-window.png"))
                print("Captured reused overlay host after polishing→error, before redraw and after full layout/display with fresh bitmap")
            } catch { captureFailed = true; print("Settings capture failed: \(error)") }
            await model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            _ = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { app.terminate(nil) }
            }
        }
        // Run-loop delivery lets the real delegate's MainActor shutdown finish during terminateLater.
        let timeout = Timer(timeInterval: 45, repeats: false) { _ in
            MainActor.assumeIsolated {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
                exit(1)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        withExtendedLifetime((lifecycle, model, window)) { app.run() }
        capture.cancel()
        timeout.invalidate()
        if captureFailed { exit(1) }
    }
    @MainActor private static func invalidateTree(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        for child in view.subviews { invalidateTree(child) }
    }

    @MainActor private static func snapshot(_ window: NSWindow, to file: URL, redraw: Bool = true) throws {
        if redraw, let view = window.contentView {
            invalidateTree(view)
            view.layoutSubtreeIfNeeded()
            view.display()
            window.displayIfNeeded()
        }
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-l", String(window.windowNumber), file.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        guard screenshot.terminationStatus == 0 else { throw CaptureError.screenshot }
    }

    enum CaptureError: Error { case screenshot }
}

/// Uses the production menu extracted into the build directory with only its visibility changed.
private struct BrandCaptureView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GoblinWordmark().fixedSize()
            HStack(spacing: 28) {
                ForEach(MascotState.allCases, id: \.self) { state in
                    VStack(spacing: 8) {
                        Image(nsImage: GoblinBrand.menuImage(state)).renderingMode(.original)
                        Text(state.rawValue.capitalized).font(.caption)
                    }
                }
            }
            Divider()
            Text("Menu").font(.headline)
            VStack(alignment: .leading, spacing: 14) { GoblinMenu(model: model) }
                .buttonStyle(.plain)
            Spacer(minLength: 0)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GoblinBrand.surface).preferredColorScheme(.dark)
    }
}
