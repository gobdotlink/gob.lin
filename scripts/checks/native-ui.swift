import AppKit
import ApplicationServices
import Combine
import GoblinCore
import GoblinEngines
import ServiceManagement
import SwiftUI
@testable import GoblinApp

// Native UI probe: the production popover, Settings and History scenes with isolated preferences and
// data, driven through the Accessibility API, clicks and keystrokes like a person would. Signed as
// gob.lin, so it inherits the Accessibility and microphone grants. Build with
// scripts/build-native-ui-check.sh; it writes results/ui-result.json beside the bundle and quits.

@MainActor enum Probe {
    nonisolated static let results = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
    static let shortcut = HotkeyShortcut(keyCode: 50, modifiers: CGEventFlags.maskControl.union(.maskAlternate).union(.maskShift).rawValue,
                                         keyLabel: "Grave")
    static var model: AppModel!
    static var suite = ""
}

@main
struct UIProbeApp: App {
    @StateObject private var model: AppModel
    @State private var popoverHeight: CGFloat = 0
    @NSApplicationDelegateAdaptor(Driver.self) private var driver

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        try? FileManager.default.createDirectory(at: Probe.results, withIntermediateDirectories: true)
        let suite = "app.goblin.ui-probe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try! JSONEncoder().encode(Probe.shortcut), forKey: "goblin.dictationShortcut")
        // A local endpoint needs no key, so the popover's cleanup switch can turn on.
        try! RewriteSettingsStore.save(RewriteSettings(enabled: false, baseURL: "http://localhost:11434/v1", model: "probe-model", cleanup: .light), defaults: defaults)
        let model = AppModel(dataDirectory: Probe.results.appendingPathComponent(UUID().uuidString, isDirectory: true), defaults: defaults)
        Probe.model = model
        Probe.suite = suite
        _model = StateObject(wrappedValue: model)
    }

    // Mirrors GoblinApp's scenes. The popover gets the isolated preferences so it never writes the real ones.
    var body: some Scene {
        let _ = attach()
        MenuBarExtra {
            MenuPopover(model: model).defaultAppStorage(model.defaults)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { popoverHeight = $0 }
                .background(PopoverWindowFit(height: popoverHeight))
        } label: {
            ProbeMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        Window("gob.lin", id: "settings") {
            SettingsView(model: model, speechModels: model.speechModels)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentSize)
    }

    private func attach() { driver.lifecycle.model = model }
}

/// Copied from GoblinApp.swift, which this probe excludes because it declares @main. Keep the two in step.
private struct ProbeMenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
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

// MARK: Accessibility. Calls into our own process run in-process on the calling thread, so only from the main actor.

struct Element: @unchecked Sendable {
    let ref: AXUIElement
    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success ? value : nil
    }
    var role: String { attribute(kAXRoleAttribute) as? String ?? "" }
    var label: String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
            .compactMap { attribute($0) as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
    }
    var children: [Element] { (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(Element.init) }
    var frame: CGRect? {
        guard let p = attribute(kAXPositionAttribute), let s = attribute(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
    @discardableResult func press() -> Bool { AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success }
    func find(depth: Int = 0, _ match: (Element) -> Bool) -> Element? {
        if match(self) { return self }
        guard depth < 40 else { return nil }
        for child in children { if let found = child.find(depth: depth + 1, match) { return found } }
        return nil
    }
    func all(depth: Int = 0, into result: inout [Element]) {
        result.append(self)
        guard depth < 40 else { return }
        for child in children { child.all(depth: depth + 1, into: &result) }
    }
    var texts: [String] { var all: [Element] = []; self.all(into: &all); return all.map(\.label).filter { !$0.isEmpty } }
}

enum AX { static let app = Element(ref: AXUIElementCreateApplication(getpid())) }

func windows() -> [Element] { (AX.app.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(Element.init) }

func click(_ frame: CGRect) async {
    let point = CGPoint(x: frame.midX, y: frame.midY)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    try? await Task.sleep(for: .milliseconds(30))
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func mouseDown(_ frame: CGRect) {
    let point = CGPoint(x: frame.midX, y: frame.midY)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func mouseUp(_ frame: CGRect) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: frame.midX, y: frame.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
}

func type(_ text: String) {
    for character in text.utf16 {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            var unit = character
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            event?.post(tap: .cghidEventTap)
        }
    }
}

func key(_ code: CGKeyCode) {
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

// MARK: Driver

@MainActor
final class Driver: NSObject, NSApplicationDelegate {
    let lifecycle = GoblinApplicationDelegate()
    nonisolated(unsafe) static var report: [String: Any] = [:]
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var log: [String] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { lifecycle.applicationShouldTerminate(sender) }

    nonisolated(unsafe) static var menusOpened = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in Driver.menusOpened += 1 }
        lifecycle.applicationDidFinishLaunching(notification)
        Task { @MainActor in await Driver.run() }
    }

    nonisolated static func note(_ text: String) {
        log.append(text); print(text); fflush(stdout)
        let url = Probe.results.appendingPathComponent("progress.log")
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close() }
        else { try? (text + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }
    nonisolated static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        report[name] = ok
        if !ok { failures.append(name + (detail().isEmpty ? "" : ": " + detail())) }
        note((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " — " + detail()))
    }
    nonisolated static func record(_ name: String, _ value: Any) { report[name] = value; note("  \(name) = \(value)") }

    /// Polls on the main actor; returns elapsed milliseconds, or nil on timeout.
    nonisolated static func until(_ seconds: Double = 3, _ condition: @MainActor () -> Bool) async -> Double? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(seconds) {
            if await MainActor.run(body: condition) {
                let c = start.duration(to: .now).components
                return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    static func untilAX(_ seconds: Double = 3, _ condition: () -> Bool) async -> Double? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(seconds) {
            if condition() { let c = start.duration(to: .now).components; return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15 }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @MainActor static func window(_ match: String) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && (($0.identifier?.rawValue ?? "").contains(match) || $0.className.contains(match)) }
    }

    @MainActor static func snapshot(_ window: NSWindow?, _ name: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Probe.results.appendingPathComponent(name + ".png"))
    }

    static func popover() -> Element? { windows().first { $0.find { $0.label.contains("Paste Last Dictation") } != nil } }

    static func statusItem() -> Element? {
        guard let bar = AX.app.attribute("AXExtrasMenuBar") else { return nil }
        return Element(ref: bar as! AXUIElement).children.first
    }

    /// Opens the popover from the status item and returns how long until it is on screen with content.
    static func openPopover() async -> Double? {
        if popover() != nil { return 0 }
        let start = ContinuousClock.now
        await MainActor.run { statusButton()?.performClick(nil) }
        guard await until(3, { window("MenuBarExtra") != nil }) != nil,
              await untilAX(3, { popover() != nil }) != nil else { return nil }
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    static func closePopover() async {
        guard popover() != nil else { return }
        key(53) // Escape
        if await until(1, { window("MenuBarExtra") == nil }) == nil {
            await MainActor.run { statusButton()?.performClick(nil) }
            _ = await until(1, { window("MenuBarExtra") == nil })
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func button(_ root: Element?, _ text: String) -> Element? {
        root?.find { ($0.role == kAXButtonRole || $0.role == kAXCheckBoxRole || $0.role == "AXSwitch" || $0.role == kAXMenuButtonRole || $0.role == kAXPopUpButtonRole) && $0.label.contains(text) }
    }

    static func run() async {
        note("UI probe starting, pid \(getpid())")
        let model = await MainActor.run { Probe.model! }
        // Seed History: the newest entry becomes the last transcript.
        await MainActor.run {
            check("accessibility trusted", AXIsProcessTrusted())
        }
        for (index, app) in [("Safari", "com.apple.Safari"), ("Mail", "com.apple.mail"), ("Terminal", "com.apple.Terminal"),
                             ("Slack", "com.tinyspeck.slackmacgap"), ("Notes", "com.apple.Notes")].enumerated() {
            let text = index == 4 ? "Probe paste text alpha bravo." : "Seeded dictation \(index) from \(app.0)."
            _ = await model.history.record(HistoryEntry(rawText: text, finalText: text, targetBundleIdentifier: app.1, targetApplicationName: app.0,
                createdAt: Date().addingTimeInterval(Double(index - 5) * 600), audioDuration: 2, model: "parakeet-tdt-v3"))
        }
        await MainActor.run { record("lastTranscript", model.lastTranscript ?? "nil") }
        let modelReady = await until(60) { model.speechModels.state == .ready }
        record("modelReadyMs", modelReady ?? -1)

        // 1. Popover opens from the status item, repeatedly.
        check("status item exposed", statusItem() != nil)
        var opens: [Double] = []
        for _ in 0..<6 {
            if let t = await openPopover() { opens.append(t) }
            try? await Task.sleep(for: .milliseconds(300))
            await closePopover()
        }
        check("popover opens every time", opens.count == 6, "\(opens.count)/6")
        record("popoverOpenMs", opens.map { (($0 * 10).rounded()) / 10 })
        _ = await openPopover()
        try? await Task.sleep(for: .milliseconds(500))
        await MainActor.run { snapshot(window("MenuBarExtra"), "01-popover") }
        let texts = popover()?.texts ?? []
        for expected in ["Microphone", "Cleanup", "Tone", "Search", "All History", "Insights", "Paste Last Dictation", "Settings…", "Probe paste text alpha bravo."] {
            check("popover shows \(expected)", texts.contains { $0.contains(expected) }, texts.joined(separator: " ¦ ").prefix(400).description)
        }

        // 2. Live updates while open: a problem appears and clears, and the menu-bar icon follows.
        let idleImage = await MainActor.run { statusButtonImage() }
        await MainActor.run { model.diagnostics.report(.modelUnavailable) }
        let title = DiagnosticFailure.modelUnavailable.plainWords.title
        let shown = await untilAX(2) { popover()?.texts.contains { $0.contains(title) } == true }
        check("problem module appears live in open popover", shown != nil)
        let warned = await until(2) { model.mascotState == .warning }
        check("mascot switches to warning", warned != nil)
        try? await Task.sleep(for: .milliseconds(300))
        let warningImage = await MainActor.run { statusButtonImage() }
        check("menu-bar icon changes for warning", idleImage != nil && warningImage != nil && idleImage != warningImage)
        await MainActor.run { model.diagnostics.resolve(.model) }
        let cleared = await untilAX(2) { popover()?.texts.contains { $0.contains(title) } == false }
        check("problem module clears live", cleared != nil)
        _ = await until(2) { model.mascotState == .idle }
        try? await Task.sleep(for: .milliseconds(300))
        let restored = await MainActor.run { statusButtonImage() }
        check("menu-bar icon returns to idle", restored == idleImage)

        // 3. Idle churn with the popover open: nothing should publish.
        let counts = await MainActor.run { ChangeCounter(model) }
        try? await Task.sleep(for: .seconds(3))
        let churn = await MainActor.run { counts.snapshot() }
        record("changesIn3sIdleWithPopoverOpen", churn)
        check("no model churn while idle", churn.values.allSatisfy { $0 == 0 }, "\(churn)")

        // 4. Hold to Test: the meter runs only while held.
        if let hold = button(popover(), "Hold to test")?.frame ?? popover()?.find({ $0.label.contains("Hold to test") })?.frame {
            mouseDown(hold)
            let running = await until(3) { model.audioPreview.running }
            check("hold to test opens the microphone", running != nil)
            record("holdToTestStartMs", running ?? -1)
            let level = await until(3) { model.audioPreview.ready }
            check("mic test receives audio", level != nil)
            let label = await untilAX(1) { popover()?.texts.contains { $0.contains("Level only") } == true }
            check("popover shows testing state", label != nil)
            try? await Task.sleep(for: .milliseconds(600))
            mouseUp(hold)
            let stopped = await until(2) { !model.audioPreview.running }
            check("releasing stops the mic test", stopped != nil)
            try? await Task.sleep(for: .milliseconds(400))
            let session = await AudioCaptureService.shared.activeSessionID
            check("no capture left behind", session == nil)
        } else { check("hold to test found", false) }

        // 5. Search filters recents.
        if let field = popover()?.find({ $0.role == kAXTextFieldRole }) {
            // Real keystrokes: setting the AX value does not reach SwiftUI's binding.
            if let frame = field.frame { await click(frame) }
            try? await Task.sleep(for: .milliseconds(200))
            type("Safari")
            try? await Task.sleep(for: .milliseconds(200))
            record("searchFieldValue", (field.attribute(kAXValueAttribute) as? String) ?? "nil")
            let filtered = await untilAX(2) {
                let t = popover()?.texts ?? []
                return t.contains { $0.contains("Seeded dictation 0 from Safari") } && !t.contains { $0.contains("Probe paste text") }
            }
            check("search filters recents", filtered != nil, (popover()?.texts ?? []).filter { $0.contains("dictation") || $0.contains("Probe") || $0.contains("Nothing") }.joined(separator: " ¦ "))
            for _ in 0..<6 { key(51) }  // Delete
            let reset = await untilAX(2) { popover()?.texts.contains { $0.contains("Probe paste text") } == true }
            check("clearing search restores recents", reset != nil)
        } else { check("search field found", false) }

        // 6. Cleanup switch: saves, reapplies configuration and redraws.
        if let on = button(popover(), "Turn cleanup on") {
            on.press()
            let enabled = await until(2) { RewriteSettingsStore.load(defaults: model.defaults).enabled && model.history.rewriteAction != nil }
            check("cleanup switch turns cleanup on and reapplies configuration", enabled != nil)
            let flipped = await untilAX(2) { button(popover(), "Turn cleanup off") != nil }
            check("cleanup tile redraws as on", flipped != nil)
            button(popover(), "Turn cleanup off")?.press()
            let disabled = await until(2) { !RewriteSettingsStore.load(defaults: model.defaults).enabled && model.history.rewriteAction == nil }
            check("cleanup switch turns cleanup off", disabled != nil)
        } else { check("cleanup switch found", false) }

        // 7. Settings… opens Settings straight away and closes the popover.
        var settingsOpens: [Double] = []
        for attempt in 0..<3 {
            _ = await openPopover()
            guard let settings = button(popover(), "Settings…") else { check("settings button found", false); break }
            settings.press()
            let shown = await until(3) { window("settings")?.isKeyWindow == true && window("MenuBarExtra") == nil }
            if let shown { settingsOpens.append(shown) }
            if attempt < 2 {
                await MainActor.run { window("settings")?.performClose(nil) }
                _ = await until(2) { window("settings") == nil }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        check("Settings… opens Settings and closes popover", settingsOpens.count == 3, "\(settingsOpens.count)/3")
        record("settingsOpenFromPopoverMs", settingsOpens.map { ($0 * 10).rounded() / 10 })
        await MainActor.run { check("Settings is frontmost and active", NSApp.isActive && window("settings")?.isKeyWindow == true) }

        // 8. Every Settings page.
        let settingsWindow = windows().first { $0.label.contains("gob.lin Settings") || $0.find { $0.label == "General" } != nil && $0.find { $0.label == "Diagnostics" } != nil }
        var switches: [String: Double] = [:]
        for section in SettingsSection.allCases {
            guard let row = settingsWindow?.find({ $0.role == kAXButtonRole && $0.label.hasPrefix(section.rawValue) }) else { check("sidebar row \(section.rawValue)", false); continue }
            row.press()
            if let t = await until(2, { model.settingsSelection == section }) { switches[section.rawValue] = (t * 10).rounded() / 10 }
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run { snapshot(window("settings"), "settings-\(section.rawValue.lowercased())") }
        }
        check("every sidebar row switches page", switches.count == SettingsSection.allCases.count, "\(switches)")
        record("settingsPageSwitchMs", switches)

        // 9. General: trailing space switch and the login item status (now read off the main thread).
        settingsWindow?.find { $0.role == kAXButtonRole && $0.label.hasPrefix("General") }?.press()
        _ = await until(2) { model.settingsSelection == .general }
        try? await Task.sleep(for: .milliseconds(500))
        let trailing = await MainActor.run { model.insertion.trailingSpace }
        if let toggle = settingsWindow?.find({ $0.label.contains("Add a space after each take") && $0.role != kAXStaticTextRole }) ?? settingsWindow?.find({ $0.label.contains("Add a space after each take") }) {
            if !toggle.press(), let frame = toggle.frame { await click(frame) }
            let flipped = await until(2) { model.insertion.trailingSpace != trailing }
            check("trailing space switch works", flipped != nil)
            if !toggle.press(), let frame = toggle.frame { await click(frame) }
            _ = await until(2) { model.insertion.trailingSpace == trailing }
        } else { check("trailing space switch found", false) }
        let loginEnabled = SMAppService.mainApp.status == .enabled
        let loginShown = settingsWindow?.find { $0.label.contains("Open at login") }
        record("openAtLoginElement", loginShown.map { "\($0.role) \($0.label) value=\(String(describing: $0.attribute(kAXValueAttribute)))" } ?? "missing")
        record("openAtLoginSystemStatusEnabled", loginEnabled)

        // 10. Audio: warm microphone reaches the capture thread; the Settings level preview runs.
        settingsWindow?.find { $0.role == kAXButtonRole && $0.label.hasPrefix("Audio") }?.press()
        _ = await until(2) { model.settingsSelection == .audio }
        try? await Task.sleep(for: .milliseconds(500))
        if let warm = settingsWindow?.find({ $0.label.contains("Keep microphone warm") && $0.role != kAXStaticTextRole }) ?? settingsWindow?.find({ $0.label.contains("Keep microphone warm") }) {
            if !warm.press(), let frame = warm.frame { await click(frame) }
            let on = await until(2) { model.defaults.bool(forKey: "audio.keepMicrophoneWarm") }
            var warmApplied = false
            for _ in 0..<40 where on != nil { if await AudioCaptureService.shared.warmMicrophoneEnabled { warmApplied = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
            check("warm microphone switch reaches the capture service", on != nil && warmApplied)
            if !warm.press(), let frame = warm.frame { await click(frame) }
            var warmOff = false
            for _ in 0..<40 { if !(await AudioCaptureService.shared.warmMicrophoneEnabled) { warmOff = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
            check("warm microphone switches back off", warmOff)
        } else { check("warm microphone switch found", false) }
        if let preview = button(settingsWindow, "Preview microphone level") {
            preview.press()
            let running = await until(3) { model.audioPreview.running && model.audioPreview.ready }
            check("Settings level preview runs", running != nil)
            record("settingsPreviewStartMs", running ?? -1)
            let flipped = await untilAX(2) { button(settingsWindow, "Stop level preview") != nil }
            check("Settings preview button shows Stop", flipped != nil)
            button(settingsWindow, "Stop level preview")?.press()
            let stopped = await until(2) { !model.audioPreview.running }
            check("Settings preview stops", stopped != nil)
        } else { check("Settings preview button found", false) }

        // 11. Overlay corner applies immediately.
        settingsWindow?.find { $0.role == kAXButtonRole && $0.label.hasPrefix("Overlay") }?.press()
        _ = await until(2) { model.settingsSelection == .overlay }
        await MainActor.run { model.defaults.set(OverlayPosition.top.rawValue, forKey: "overlayPosition") }
        let moved = await until(2) { model.overlay.position == .top }
        check("overlay position preference applies", moved != nil)
        await MainActor.run { model.defaults.set(OverlayPosition.bottom.rawValue, forKey: "overlayPosition") }
        _ = await until(2) { model.overlay.position == .bottom }

        // 12. History from the popover: All History, a recent row focusing its entry, Insights.
        await MainActor.run { window("settings")?.performClose(nil) }
        _ = await until(2) { window("settings") == nil }
        var historyOpens: [Double] = []
        _ = await openPopover()
        if let all = button(popover(), "All History") {
            all.press()
            if let t = await until(3, { window("settings")?.isKeyWindow == true && window("MenuBarExtra") == nil }) { historyOpens.append(t) }
            check("All History opens the shared window", historyOpens.count == 1)
            await MainActor.run { check("History shows all dictations", model.settingsSelection == .history && model.history.filter == .all) }
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { snapshot(window("settings"), "history-all") }
        }
        _ = await openPopover()
        let rowTarget = await MainActor.run { model.history.entries.first { $0.targetApplicationName == "Mail" }?.id }
        if let row = popover()?.find({ $0.label.contains("Seeded dictation 1 from Mail") && $0.role != kAXStaticTextRole }) ?? popover()?.find({ $0.label.contains("Seeded dictation 1 from Mail") }) {
            if !row.press(), let frame = row.frame { await click(frame) }
            let focused = await until(3) { window("settings")?.isKeyWindow == true && model.historyFocus == nil && window("MenuBarExtra") == nil }
            check("recent row opens History on that entry", focused != nil && rowTarget != nil)
            let selected = await untilAX(2) { windows().contains { $0.find { $0.label.contains("Seeded dictation 1 from Mail") && ($0.attribute(kAXSelectedAttribute) as? Bool == true || $0.label.contains("Selected")) } != nil } }
            record("historyRowSelectedViaAX", selected != nil)
        } else { check("recent row found", false, (popover()?.texts ?? []).joined(separator: " ¦ ").prefix(300).description) }
        _ = await openPopover()
        if let insights = button(popover(), "Insights") {
            insights.press()
            let shown = await until(3) { model.settingsSelection == .insights && window("settings")?.isKeyWindow == true }
            check("Insights opens the shared window on Insights", shown != nil)
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { snapshot(window("settings"), "history-insights") }
        }
        record("historyOpenFromPopoverMs", historyOpens)
        await MainActor.run { window("settings")?.performClose(nil) }

        // 13. More menu. Its popup is not in the AX tree, so click it open and pick items by typing their
        // names: arrow counts break while Check for Updates… is disabled.
        func openMore() async -> Bool {
            _ = await openPopover()
            guard let frame = popover()?.find({ $0.role == kAXMenuButtonRole && $0.label.contains("More") })?.frame else { return false }
            let before = menusOpened
            await click(frame)
            let opened = await untilAX(2) { menusOpened > before } != nil
            try? await Task.sleep(for: .milliseconds(300))
            return opened
        }
        func choose(_ item: String) async {
            type(item)
            try? await Task.sleep(for: .milliseconds(200))
            key(36)
        }
        check("More menu opens", await openMore())
        record("activeWhenChoosingAbout", "gob.lin active \(NSApp.isActive), frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        await choose("About")
        let about = await until(3) { model.settingsSelection == .about && window("settings")?.isKeyWindow == true && window("MenuBarExtra") == nil }
        check("More ▸ About opens Settings on About", about != nil,
              "selection \(String(describing: model.settingsSelection)), settings key \(window("settings")?.isKeyWindow == true), popover \(window("MenuBarExtra") != nil)")
        await MainActor.run { window("settings")?.performClose(nil) }
        _ = await until(2) { window("settings") == nil }
        try? await Task.sleep(for: .milliseconds(300))
        check("More menu opens again", await openMore())
        await choose("Permissions")
        let setup = await until(3) { window("MenuBarExtra") == nil && NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to gob.lin" } }
        check("More ▸ Permissions… opens setup", setup != nil)
        NSApp.windows.first { $0.title == "Welcome to gob.lin" }?.performClose(nil)
        try? await Task.sleep(for: .milliseconds(300))

        // Right-click on the menu-bar icon: closes the popover and opens the shared status menu.
        _ = await openPopover()
        if let frame = statusItem()?.frame {
            let before = menusOpened
            let point = CGPoint(x: frame.midX, y: frame.midY)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
            let opened = await untilAX(2) { menusOpened > before }
            check("right-click opens the status menu", opened != nil)
            check("right-click closes the popover", await until(2) { window("MenuBarExtra") == nil } != nil)
            try? await Task.sleep(for: .milliseconds(300))
            await choose("Settings")
            let settings = await until(3) { window("settings")?.isKeyWindow == true && model.settingsSelection == .general }
            check("status menu ▸ Settings… opens Settings", settings != nil)
            window("settings")?.performClose(nil)
            _ = await until(2) { window("settings") == nil }
        } else { check("status item frame", false) }

        // 14. Paste Last Dictation into another app: focus returns there first.
        let targetURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Native Target.app")
        let targetText = targetURL.deletingLastPathComponent().appendingPathComponent("target-text.txt")
        try? FileManager.default.removeItem(at: targetText)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            _ = try? await NSWorkspace.shared.openApplication(at: targetURL, configuration: configuration)
            let front = await until(5) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "app.goblin.native-dictation-target" }
            check("target app frontmost", front != nil)
            try? await Task.sleep(for: .milliseconds(500))
            _ = await openPopover()
            button(popover(), "Paste Last Dictation")?.press()
            let pasted = await untilAX(5) { ((try? String(contentsOf: targetText, encoding: .utf8)) ?? "").contains("Probe paste text alpha bravo.") }
            check("Paste Last Dictation lands in the previous app", pasted != nil, "target: \((try? String(contentsOf: targetText, encoding: .utf8)) ?? "none")")
            record("pasteMs", pasted ?? -1)
            let verified = await until(3) {
                guard case .success = model.insertion.outcome else { return false }
                return !model.insertion.hasRecoveryClipboard && !model.insertion.busy
            }
            // A focus change during the paste (for example someone using the desktop) leaves it unverified.
            check("pasted text verified and clipboard restored", verified != nil, model.insertion.status)
            NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.goblin.native-dictation-target" }.forEach { $0.terminate() }
        } else { record("pasteTest", "skipped: target app missing") }

        // Done: write results, then quit through the real termination path. Pending saves or a held
        // clipboard copy make Quit ask first, so record them.
        if model.insertion.hasRecoveryClipboard {
            // Otherwise Quit stops to ask about the recovery copy; give the person their clipboard back.
            model.insertion.restorePreviousClipboard()
            _ = await until(2) { !model.insertion.hasRecoveryClipboard }
            record("restoredPreviousClipboardBeforeQuit", true)
        }
        let summary: [String: Any] = ["failures": failures, "report": report, "log": log]
        try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: Probe.results.appendingPathComponent("ui-result.json"))
        note("UI probe finished with \(failures.count) failure(s); quitting")
        await MainActor.run {
            UserDefaults(suiteName: Probe.suite)?.removePersistentDomain(forName: Probe.suite)
            // From a run-loop timer, like a real Quit, not from inside a main-queue job.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    @MainActor static func statusButton() -> NSStatusBarButton? {
        NSApp.windows.lazy.compactMap { $0.contentView?.firstSubview(of: NSStatusBarButton.self) }.first
    }

    @MainActor static func statusButtonImage() -> Data? {
        for window in NSApp.windows {
            if let button = window.contentView?.firstSubview(of: NSStatusBarButton.self) { return button.image?.tiffRepresentation }
        }
        return nil
    }
}

@MainActor final class ChangeCounter {
    private var counts: [String: Int] = [:]
    private var subscriptions: [AnyCancellable] = []
    init(_ model: AppModel) {
        let publishers: [(String, ObservableObjectPublisher)] = [("app", model.objectWillChange), ("permissions", model.permissions.objectWillChange),
            ("diagnostics", model.diagnostics.objectWillChange), ("audioPreview", model.audioPreview.objectWillChange),
            ("history", model.history.objectWillChange), ("hotkeys", model.hotkeys.objectWillChange), ("insertion", model.insertion.objectWillChange)]
        for (name, publisher) in publishers {
            counts[name] = 0
            subscriptions.append(publisher.sink { [weak self] _ in self?.counts[name, default: 0] += 1 })
        }
    }
    func snapshot() -> [String: Int] { counts }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews { if let match = subview.firstSubview(of: type) { return match } }
        return nil
    }
}
