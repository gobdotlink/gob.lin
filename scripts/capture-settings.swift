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
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false,
            diagnosticEnvironment: DiagnosticEnvironment(microphonePermission: .notRequested,
                accessibilityPermission: .denied, inputMonitoringPermission: .denied,
                microphoneNames: ["Preview microphone"], defaultMicrophoneName: "Preview microphone"))
        let lifecycle = GoblinApplicationDelegate()
        lifecycle.model = model
        app.delegate = lifecycle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 840),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "gob.lin — Settings capture"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        print("Preview PID \(getpid()), window \(window.windowNumber)")
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots", isDirectory: true)
        var captureFailed = false
        let capture = Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let pages: [(SettingsSection, String)] = [(.general, "general"), (.audio, "audio"), (.dictionary, "dictionary"),
                    (.tone, "tone"), (.rewrite, "rewrite"), (.overlay, "overlay"), (.diagnostics, "diagnostics")]
                for (page, name) in pages {
                    model.settingsSelection = page
                    if page == .diagnostics {
                        model.diagnostics.report(.modelUnavailable)
                        model.diagnostics.recordTimings(DictationTimings(asrMilliseconds: 180, rewriteMilliseconds: 12))
                    }
                    try await Task.sleep(for: .milliseconds(700))
                    let screenshot = Process()
                    screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    screenshot.arguments = ["-x", "-l", String(window.windowNumber),
                        destination.appendingPathComponent("gob-22-settings-\(name).png").path]
                    try screenshot.run()
                    screenshot.waitUntilExit()
                    guard screenshot.terminationStatus == 0 else { throw CaptureError.screenshot }
                    print("Captured \(page.rawValue)")
                }
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
    enum CaptureError: Error { case screenshot }
}
