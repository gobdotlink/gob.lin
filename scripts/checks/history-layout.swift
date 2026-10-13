import AppKit
import GoblinCore
import SwiftUI

/// File-only fixtures and offscreen views; no microphone, clipboard or desktop interaction.
@main
struct HistoryLayoutChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        GoblinBrand.registerFonts()
        let suite = "app.goblin.history-layout.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false)
        model.settingsSelection = .history
        let first = HistoryEntry(rawText: "Plan the next release and review the checklist.",
                                 finalText: "Plan the next release and review the checklist.",
                                 targetApplicationName: "Synthetic editor", audioDuration: 3.4, model: "Fixture", starred: true)
        let second = HistoryEntry(rawText: "Send the updated schedule tomorrow.", finalText: "Send the updated schedule tomorrow.",
                                  targetApplicationName: "Synthetic notes", createdAt: Date(timeIntervalSinceNow: -60))
        let firstSaved = await model.history.record(first)
        let secondSaved = await model.history.record(second)
        precondition(firstSaved && secondSaved)
        let host = NSHostingView(rootView: SettingsView(model: model).frame(width: 940, height: 720))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 940, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots/history")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await capture(host, to: output.appendingPathComponent("settings-history.png"))
        model.history.searchText = "schedule"
        await model.history.reload()
        precondition(model.history.entries.map(\.id) == [second.id])
        try await capture(host, to: output.appendingPathComponent("settings-history-search.png"))
        model.history.searchText = "no matching fixture"
        await model.history.reload()
        precondition(model.history.entries.isEmpty)
        try await capture(host, to: output.appendingPathComponent("settings-history-no-matches.png"))
        model.history.searchText = ""
        await model.history.reload()
        await model.history.delete(second)
        precondition(model.history.entries.map(\.id) == [first.id])
        try await capture(host, to: output.appendingPathComponent("settings-history-after-delete.png"))
        let reopened = HistoryModel(directory: directory, defaults: defaults)
        await reopened.reload()
        precondition(reopened.entries == model.history.entries, "Navigation must use the existing persistent store")
        let retentionHost = NSHostingView(rootView: HistoryRetentionView(model: model.history).preferredColorScheme(.dark))
        retentionHost.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let retentionWindow = NSWindow(contentRect: retentionHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        retentionWindow.contentView = retentionHost
        defer { retentionWindow.close() }
        try await capture(retentionHost, to: output.appendingPathComponent("history-retention.png"))
        await model.history.delete(first)
        try await capture(host, to: output.appendingPathComponent("settings-history-empty.png"))
        await model.shutdown()
        print("History layout checks passed: isolated persistence/search/delete; offscreen populated, search, no-match, deletion, empty and retention captures. Hidden rendering omits sidebar material; live entry points, resizing and action clicks remain unverified.")
    }

    @MainActor private static func capture(_ view: NSView, to url: URL) async throws {
        try await Task.sleep(for: .milliseconds(350))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureFailure.noBitmap }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureFailure.noBitmap }
        try png.write(to: url)
    }

    enum CaptureFailure: Error { case noBitmap }
}
