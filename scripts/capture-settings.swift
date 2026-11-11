import AppKit
import GoblinCore
import SwiftUI

/// Production views with isolated synthetic data and no system services: Settings, History, the
/// popover, first run and every overlay phase, in light and dark.
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
            DictionaryEntry(spelling: "Sol", aliases: ["soul", "sole"], context: ["GPT", "6.1"]),
        ])
        defaults.set(try JSONEncoder().encode(HistoryRetention(maximumUnstarredCount: 500, maximumAgeDays: 30)), forKey: "history.retention")
        defaults.set(OverlayPosition.top.rawValue, forKey: "overlayPosition")
        try RewriteSettingsStore.save(RewriteSettings(enabled: false, baseURL: "https://provider.invalid/v1", model: "example-model", cleanup: .light), defaults: defaults)
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false,
            diagnosticEnvironment: DiagnosticEnvironment(microphonePermission: .notRequested,
                accessibilityPermission: .denied, inputMonitoringPermission: .denied,
                microphoneNames: ["Preview microphone"], defaultMicrophoneName: "Preview microphone"))
        precondition(model.overlay.position == .top, "Saved overlay position must apply before Settings or Preview opens")
        let emptyDirectory = directory.appendingPathComponent("empty", isDirectory: true)
        let empty = AppModel(dataDirectory: emptyDirectory, defaults: defaults, servicesEnabled: false)
        let lifecycle = GoblinApplicationDelegate()
        lifecycle.model = model
        app.delegate = lifecycle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        if !CommandLine.arguments.contains("--offscreen") {
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate()
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots", isDirectory: true)
        let offscreen = CommandLine.arguments.contains("--offscreen")
        var captureFailed = false
        let capture = Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try await seedHistory(model.history)
                precondition(model.dictionary.entries.count == 4 && model.dictionary.available)
                // Two fixes of one word, so the Dictionary page offers it with the context they share.
                for (heard, after) in [("rock", "review"), ("rock", "agent")] {
                    model.dictionary.offerCorrection(dictated: "ask the Claude 5 \(heard) \(after) for this",
                                                     edited: "ask the Claude 5 Rook \(after) for this",
                                                     scope: DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin"))
                }
                var window = window
                @MainActor func shoot(_ name: String, _ view: some View, size: NSSize, dark: Bool = false) async throws {
                    // A fresh window per shot, so one view's toolbar never leaks into the next capture.
                    window.orderOut(nil)
                    window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.title = "gob.lin — \(name)"
                    window.setContentSize(size)
                    window.contentView = NSHostingView(rootView: view.allowsHitTesting(false))
                    if offscreen {
                        // Rendered off the visible desktop: nothing flashes on screen or takes focus.
                        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
                        window.orderBack(nil)
                    } else {
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    try await Task.sleep(for: .milliseconds(700))
                    try snapshot(window, to: destination.appendingPathComponent("design-\(name).png"), live: !offscreen)
                    print("Captured \(name)")
                }
                let only = CommandLine.arguments.dropFirst(2).first { !$0.hasPrefix("--") }
                func wanted(_ group: String) -> Bool { only == nil || only == group }

                if wanted("settings") {
                    for page in SettingsSection.allCases {
                        model.settingsSelection = page
                        if page == .diagnostics { model.diagnostics.report(.modelUnavailable) }
                        try await shoot("settings-\(page.rawValue.lowercased())", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1040, height: 1080))
                    }
                    for page in [SettingsSection.general, .dictionary, .cleanup, .about] {
                        model.settingsSelection = page
                        try await shoot("settings-\(page.rawValue.lowercased())-dark", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1040, height: 1080), dark: true)
                    }
                    empty.settingsSelection = .dictionary
                    try await shoot("settings-dictionary-empty-dark", SettingsView(model: empty, speechModels: empty.speechModels), size: NSSize(width: 1040, height: 1080), dark: true)
                    model.diagnostics.resolve(.model)
                    let provider = CleanupProviderSheet(settings: RewriteSettingsStore.load(defaults: defaults), defaults: defaults,
                                                        inspectCredentials: false, turnOn: false, onSave: { _ in }, onFailure: { _ in })
                    try await shoot("settings-cleanup-provider", provider, size: NSSize(width: 680, height: 520))
                    let sol = model.dictionary.entries.first { $0.spelling == "Sol" }!
                    for dark in [false, true] {
                        try await shoot("settings-dictionary-entry\(dark ? "-dark" : "")", DictionaryEntryEditor(entry: sol, model: model.dictionary).background(Color(nsColor: .windowBackgroundColor)),
                                        size: NSSize(width: 460, height: 740), dark: dark)
                    }
                }
                if wanted("history") {
                    model.settingsSelection = .history
                    try await shoot("history", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720))
                    try await shoot("history-dark", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720), dark: true)
                    model.settingsSelection = .insights
                    try await shoot("history-insights", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720))
                    model.settingsSelection = .history
                    empty.settingsSelection = .history
                    try await shoot("history-empty", SettingsView(model: empty), size: NSSize(width: 970, height: 620))
                    try await shoot("history-narrow", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 970, height: 620))
                }
                if wanted("popover") {
                    try await shoot("popover", popover(model), size: NSSize(width: 420, height: 720))
                    model.diagnostics.report(.requiredPermissionsMissing)
                    model.diagnostics.report(.rewriteConfiguration)
                    try await shoot("popover-attention-dark", popover(model), size: NSSize(width: 420, height: 720), dark: true)
                    model.diagnostics.resolve(.permissions)
                    model.diagnostics.resolve(.rewrite)
                }
                if wanted("onboarding") {
                    for step in OnboardingView.Step.allCases {
                        try await shoot("onboarding-\(step.rawValue + 1)", OnboardingView(model: model, startAt: step), size: NSSize(width: 660, height: 516))
                    }
                    try await shoot("onboarding-1-dark", OnboardingView(model: model, startAt: .permissions), size: NSSize(width: 660, height: 516), dark: true)
                }
                if wanted("overlay") {
                    for (name, overlay) in overlayPhases() {
                        try await shoot("overlay-\(name)", ZStack { Wallpaper(); DictationOverlay(model: overlay) },
                                        size: DictationOverlay.panelSize, dark: name.hasSuffix("dark"))
                    }
                }
            } catch { captureFailed = true; print("Capture failed: \(error)") }
            await model.shutdown()
            await empty.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            _ = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { app.terminate(nil) }
            }
        }
        // Run-loop delivery lets the real delegate's MainActor shutdown finish during terminateLater.
        let timeout = Timer(timeInterval: 180, repeats: false) { _ in
            MainActor.assumeIsolated {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
                exit(1)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        withExtendedLifetime((lifecycle, model, empty, window)) { app.run() }
        capture.cancel()
        timeout.invalidate()
        if captureFailed { exit(1) }
    }

    @MainActor private static func seedHistory(_ history: HistoryModel) async throws {
        let now = Date()
        let entries: [(String, String, String, String, Double, Double, Bool, String?)] = [
            ("Mail", "com.apple.mail", "um so can we push the design review to thursday like i want the overlay sorted before anyone sees it and uh and the menu still needs a pass on the copy",
             "Can we push the design review to Thursday? I want the overlay sorted before anyone sees it, and the menu still needs a pass on the copy.", 9, 60, true, nil),
            ("Slack", "com.tinyspeck.slackmacgap", "looks good to me ship it once notarisation passes", "Looks good to me. Ship it once notarisation passes.", 5, 600, false, nil),
            ("Xcode", "com.apple.dt.Xcode", "mirror the overlay when the caret sits in the bottom right corner", "Mirror the overlay when the caret sits in the bottom-right corner.", 6, 1500, false, nil),
            ("Messages", "com.apple.MobileSMS", "on my way grab me a flat white", "On my way. Grab me a flat white?", 3, 3600, true, nil),
            ("Terminal", "com.apple.Terminal", "fix the clipboard restore race when secure input is on", "fix the clipboard restore race when secure input is on", 4, 90_000, false,
             DiagnosticFailure.insertionTargetChanged.message),
            ("Safari", "com.apple.Safari", "best low profile mechanical keyboard", "best low profile mechanical keyboard", 2, 100_000, false, nil),
        ]
        for (name, bundle, raw, final, duration, age, starred, warning) in entries.reversed() {
            let entry = HistoryEntry(rawText: raw, finalText: final, tone: "formal", polished: raw != final,
                                     targetBundleIdentifier: bundle, targetApplicationName: name,
                                     createdAt: now.addingTimeInterval(-age), audioDuration: duration, model: "parakeet-tdt-v3",
                                     latencies: DictationTimings(captureMilliseconds: duration * 1000, asrMilliseconds: 142, rewriteMilliseconds: raw != final ? 386 : 0, insertionMilliseconds: 9),
                                     starred: starred, processingWarning: warning)
            guard await history.record(entry) else { throw CaptureError.seed }
        }
    }

    @MainActor private static func popover(_ model: AppModel) -> some View {
        ZStack(alignment: .top) {
            Wallpaper()
            MenuPopover(model: model)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .padding(.top, 24)
        }
    }

    @MainActor private static func overlayPhases() -> [(String, OverlayModel)] {
        func make(_ phase: OverlayPhase, committed: String = "", tentative: String = "", level: Double = 0.6,
                  configure: (OverlayModel) -> Void = { _ in }) -> OverlayModel {
            let model = OverlayModel()
            model.presented = true
            model.phase = .arming
            if phase != .arming { model.phase = .listening }
            model.committedText = committed
            model.tentativeText = tentative
            for value in [0.2, 0.5, 0.8, 0.45, level] { model.audioLevel = value }
            model.phase = phase
            model.audioSeconds = 7
            configure(model)
            return model
        }
        let words = "Cut the export redesign instead. Keep the onboarding, it's what people"
        let long = "so the build goes out tonight. Keep the onboarding, it's what people see first, and we'll move export to next week, because the copy pass on the menu still needs a day"
        return [
            ("arming", make(.arming)),
            ("listening", make(.listening, committed: words, tentative: " see first")),
            ("listening-long", make(.listening, committed: long, tentative: " or two")),
            ("listening-dark", make(.listening, committed: words, tentative: " see first")),
            ("handsfree", make(.listening, committed: "Second point: the overlay copy needs one more pass", tentative: " before anyone sees it") { $0.handsFree = true }),
            ("handsfree-keyed", make(.listening, committed: "Second point: the overlay copy needs one more pass") { $0.handsFree = true; $0.talkKey = .optionSpace }),
            ("transcribing", make(.transcribing, committed: words + " see first.")),
            ("polishing", make(.polishing, committed: "so um cut the export redesign instead keep the onboarding it's what people see first") { $0.cleanupLabel = "Light · Cerebras" }),
            ("inserted", make(.inserted(OverlayResult(application: "Team chat", words: 23, seconds: 0.59)))),
            ("milestone", make(.milestone(words: 10_000))),
            ("term-suggestion", make(.termSuggestion(TermSuggestion(spelling: "panacea", aliases: ["anasia"], projects: ["gob.lin"],
                                                                     reason: .correction(heard: "anasia"))))),
            ("term-suggestion-repeated", make(.termSuggestion(TermSuggestion(spelling: "Sol", aliases: ["soul", "sole"],
                                                                     reason: .correction(heard: "soul"), context: ["GPT", "6.1"], timesFixed: 5)))),
            ("term-added", make(.termAdded(TermSuggestion(spelling: "panacea", projects: ["gob.lin"], reason: .correction(heard: "anasia"))))),
            ("error-cleanup", make(.error(OverlayNotice(.rewriteTimeout)))),
            ("error-microphone", make(.error(OverlayNotice(.microphoneUnavailable)))),
            ("listening-new-microphone", make(.listening, committed: words, tentative: " see first") { $0.microphoneLine = "Using Lav Receiver" }),
            ("new-microphone", make(.newMicrophone(name: "Lav Receiver", uid: "preview-lav"))),
            ("error-secure", make(.error(OverlayNotice(.secureInputEnabled)))),
            ("mirrored", make(.listening, committed: "Sounds good, send it", tentative: " over") { $0.mirrored = true }),
            ("top", make(.listening, committed: "Top-right, under the menu bar") { $0.edge = .top }),
        ]
    }

    @MainActor private static func invalidateTree(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        for child in view.subviews { invalidateTree(child) }
    }

    @MainActor private static func snapshot(_ window: NSWindow, to file: URL, live: Bool = true) throws {
        if let view = window.contentView {
            invalidateTree(view)
            view.layoutSubtreeIfNeeded()
            view.display()
            window.displayIfNeeded()
        }
        if live {
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        guard screenshot.terminationStatus != 0 else { return }
        }
        // A locked or sleeping display can't be captured; render the view offscreen instead.
        // Window materials and chrome are missing from these, so prefer a live capture when possible.
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.screenshot }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.screenshot }
        try png.write(to: file)
    }

    enum CaptureError: Error { case screenshot, seed }
}

/// A desktop-ish backdrop so translucent surfaces have something to sit on.
private struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.5, green: 0.6, blue: 0.56), Color(red: 0.3, green: 0.42, blue: 0.38)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(RadialGradient(colors: [Color(red: 0.78, green: 0.7, blue: 0.56).opacity(0.7), .clear],
                                    center: .topTrailing, startRadius: 0, endRadius: 420))
    }
}
