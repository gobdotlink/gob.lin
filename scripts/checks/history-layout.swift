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
        var openedWindows: [String] = []
        model.openWindow = { openedWindows.append($0) }
        model.openSettings(.insights)
        precondition(model.settingsSelection == .insights)
        model.openHistory(.withWarnings)
        precondition(model.settingsSelection == .history && model.history.filter == .withWarnings)
        model.history.searchText = "stale search"
        let focus = UUID()
        model.openHistory(focus: focus)
        precondition(model.historyFocus == focus && model.history.searchText.isEmpty && model.history.filter == .all)
        model.historyFocus = nil
        model.openSettings(.general)
        model.openHistory()
        precondition(openedWindows == Array(repeating: "settings", count: 5), "Every entry point must use the same window")
        let first = HistoryEntry(rawText: "Plan the next release and review the checklist.",
                                 finalText: "Plan the next release and review the checklist.",
                                 targetApplicationName: "Synthetic editor", audioDuration: 3.4, model: "Fixture", starred: true)
        let second = HistoryEntry(rawText: "Send the updated schedule tomorrow.", finalText: "Send the updated schedule tomorrow.",
                                  targetApplicationName: "Synthetic notes", createdAt: Date(timeIntervalSinceNow: -60), processingWarning: "Synthetic warning")
        let firstSaved = await model.history.record(first)
        let secondSaved = await model.history.record(second)
        precondition(firstSaved && secondSaved)
        let host = NSHostingView(rootView: SettingsView(model: model, speechModels: model.speechModels).frame(width: 1100, height: 720))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots/history")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await capture(host, to: output.appendingPathComponent("history.png"))
        model.history.filter = .starred
        await model.history.reload()
        await expectEntries(model.history, [first.id])
        try await capture(host, to: output.appendingPathComponent("history-starred.png"))
        await model.history.setStarred(false, entry: first)
        await expectEntries(model.history, [])
        await model.history.setStarred(true, entry: first)
        await expectEntries(model.history, [first.id])
        model.history.filter = .withWarnings
        await model.history.reload()
        await expectEntries(model.history, [second.id])
        model.history.filter = .application("Synthetic editor")
        await model.history.reload()
        await expectEntries(model.history, [first.id])
        model.history.filter = .all
        model.history.searchText = "schedule"
        await model.history.reload()
        await expectEntries(model.history, [second.id])
        try await capture(host, to: output.appendingPathComponent("history-search.png"))
        let store = model.history.store!
        var filler: [UUID] = []
        for _ in 0..<205 {
            let entry = HistoryEntry(rawText: "Paging fixture", finalText: "Paging fixture", createdAt: Date(timeIntervalSinceNow: -1), starred: true)
            _ = try await store.insert(entry)
            filler.append(entry.id)
        }
        model.history.filter = .starred
        model.history.searchText = ""
        await model.history.reload()
        let starredIDs = try await store.entries(filter: .starred, limit: 2000).map(\.id)
        await expectEntries(model.history, Array(starredIDs.prefix(200)))
        await model.history.loadMore()
        await expectEntries(model.history, starredIDs)
        let olderID = starredIDs.last!, unstarredEntry = model.history.entries[200]
        await model.history.setStarred(false, entry: unstarredEntry)
        await expectEntries(model.history, starredIDs.filter { $0 != unstarredEntry.id })
        precondition(model.history.entries.contains { $0.id == olderID }, "Unstarring another row must preserve older loaded pages")
        model.history.filter = .all
        model.history.searchText = ""
        await model.history.reload()
        precondition(!model.history.entries.contains { $0.id == second.id })
        model.openHistory(focus: second.id)
        try await capture(host, to: output.appendingPathComponent("history-focused-older.png"))
        precondition(model.historyFocus == nil && model.history.entries.contains { $0.id == second.id }, "Recent-search navigation must reveal entries beyond the first page")
        model.history.searchText = "schedule"
        await model.history.reload()
        await expectEntries(model.history, [second.id])
        model.openHistory(focus: second.id)
        try await capture(host, to: output.appendingPathComponent("history-focused-from-search.png"))
        precondition(model.historyFocus == nil && model.history.entries.contains { $0.id == second.id }, "Clearing an old search must keep its requested entry focused")
        for id in filler { try await store.delete(id: id) }
        model.history.searchText = "no matching fixture"
        await model.history.reload()
        await expectEntries(model.history, [])
        try await capture(host, to: output.appendingPathComponent("history-no-matches.png"))
        model.history.searchText = ""
        await model.history.reload()
        model.openSettings(.insights)
        try await capture(host, to: output.appendingPathComponent("history-insights.png"))
        let totals = try await model.history.store!.insights()
        precondition(totals.totalWords == first.wordCount + second.wordCount)
        model.openSettings(.general)
        try await capture(host, to: output.appendingPathComponent("settings-general.png"))
        model.openHistory()
        await model.history.delete(second)
        await expectEntries(model.history, [first.id])
        try await capture(host, to: output.appendingPathComponent("history-after-delete.png"))
        let reopened = HistoryModel(directory: directory, defaults: defaults)
        await reopened.reload()
        precondition(reopened.entries == model.history.entries, "Navigation must use the existing persistent store")
        let retentionHost = NSHostingView(rootView: HistoryRetentionView(model: model.history).preferredColorScheme(.dark))
        retentionHost.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let retentionWindow = NSWindow(contentRect: retentionHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        retentionWindow.contentView = retentionHost
        defer { retentionWindow.close() }
        try await capture(retentionHost, to: output.appendingPathComponent("history-retention.png"))
        await model.history.saveRetention(HistoryRetention(maximumUnstarredCount: 0))
        precondition(model.history.entries.map(\.id) == [first.id], "Retention must preserve starred dictations")
        await model.history.delete(first)
        try await capture(host, to: output.appendingPathComponent("history-empty.png"))
        let popoverHost = NSHostingView(rootView: MenuPopover(model: model).defaultAppStorage(defaults))
        let popoverWindow = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 360, height: 720),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        popoverWindow.contentView = popoverHost
        defer { popoverWindow.close() }
        try await capture(popoverHost, to: output.appendingPathComponent("popover-empty.png"))
        await model.shutdown()
        print("History checks passed: shared-window routing, focus/search reset, filters, persistence, search, deletion, retained totals and starred retention; populated, Insights, General, empty and retention captures. Live menu clicks remain unverified.")
    }

    @MainActor private static func expectEntries(_ history: HistoryModel, _ ids: [UUID]) async {
        for _ in 0..<200 {
            if !history.isLoading, history.entries.map(\.id) == ids { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("History did not settle on the expected entries")
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
