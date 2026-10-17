import AppKit
import Foundation
import GoblinCore
@testable import GoblinApp

@main
struct OriginalFieldCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        GoblinBrand.registerFonts()
        let foreground = NSWindow(contentRect: NSRect(x: 720, y: 300, width: 400, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        foreground.title = "Foreground app stays here"
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        editor.string = "Foreground draft must stay untouched."
        foreground.contentView = editor
        Task { @MainActor in
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            let suite = "app.goblin.original-field-check." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "goblin.trailingSpace")
            let service = TextInsertionService(defaults: defaults, registerShortcuts: false)
            let overlay = OverlayController()
            var report: [String: Any] = [:]
            defer {
                overlay.shutdown()
                service.shutdown()
                defaults.removePersistentDomain(forName: suite)
            }
            do {
                guard AXIsProcessTrusted() else { throw Failure("Signed probe has no Accessibility permission") }
                guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "app.goblin.original-field-target" }) else {
                    throw Failure("Isolated target is missing")
                }
                defer { target.terminate() }
                foreground.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try await wait("probe activation") { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
                target.activate(options: [.activateIgnoringOtherApps])
                try await wait("target activation") { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
                let started = ContinuousClock.now
                let session = DictationSession()
                report["captureMilliseconds"] = Double(started.duration(to: .now).components.attoseconds) / 1e15
                guard let original = session.originalText, original.value == "left 🧌 right", original.supportsDirectInsertion else {
                    throw Failure("Original native editor was not captured as writable: \(String(describing: session.originalText))")
                }
                let fields = descendants(AXUIElementCreateApplication(target.processIdentifier))
                guard let pasteOnly = fields["paste-only"], let unconfirmed = fields["unconfirmed"] else { throw Failure("Target fields missing") }
                var movedSelection = CFRange(location: 0, length: 4)
                try set(original.element, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &movedSelection)!)
                try set(pasteOnly, kAXFocusedAttribute, kCFBooleanTrue)
                foreground.makeKeyAndOrderFront(nil)
                foreground.makeFirstResponder(editor)
                app.activate(ignoringOtherApps: true)
                try await wait("background delivery foreground") { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
                let clipboardCount = NSPasteboard.general.changeCount
                await service.insert("replacement", into: original)
                try require(service.outcome == .success, "Background insertion failed: " + service.status)
                try require(FocusedText.read(pid: original.pid, element: original.element).value == "left replacement right", "Wrong original selection")
                try require(FocusedText.read(pid: original.pid, element: pasteOnly).value == "draft", "Other field changed")
                try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() && editor.string == "Foreground draft must stay untouched.", "Background insertion stole focus or typed into the foreground")
                try require(NSPasteboard.general.changeCount == clipboardCount, "Background insertion touched the clipboard")
                report["backgroundOriginalField"] = true

                var currentCaret = CFRange(location: "left replacement right".utf16.count, length: 0)
                try set(original.element, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &currentCaret)!)
                await service.insert(" end", into: original)
                let changedValue = FocusedText.read(pid: original.pid, element: original.element).value
                try require(service.outcome == .success && changedValue == "left replacement right end", "Changed field reused a stale selection")
                let cancelled = Task { @MainActor in await service.insert("cancelled", into: original) }
                cancelled.cancel()
                await cancelled.value
                try require(service.outcome != .success && FocusedText.read(pid: original.pid, element: original.element).value == changedValue,
                            "Cancelled insertion reused a previous success or changed text")
                report["selectionAndCancellation"] = true

                let model = AppModel(dataDirectory: root.appendingPathComponent(UUID().uuidString), defaults: defaults, servicesEnabled: false)
                await model.history.reload()
                session.overlayID = model.overlay.begin(onCancel: {})
                let audio = root.appendingPathComponent(UUID().uuidString + ".wav")
                try Data([0x52, 0x49, 0x46, 0x46]).write(to: audio)
                try await model.finishDictation(.init(rawText: " pipeline", finalText: " pipeline", tone: .formal, polished: false),
                    model: "fixture", audioURL: audio, duration: 1, timings: DictationTimings(), session: session)
                try require(model.insertion.outcome == .success && model.lastTranscript == " pipeline", "Recording completion did not use its original target")
                try require(model.history.entries.contains { $0.id == session.id && $0.targetApplicationName == target.localizedName && $0.processingWarning == nil },
                            "Completion lost the destination or saved a false warning")
                guard case .inserted(let delivery) = model.overlay.model.phase, delivery.application == target.localizedName else {
                    throw Failure("Verified completion did not name its destination")
                }
                try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "Completion activated the target app")
                await model.shutdown()
                report["appModelCompletionAndHistory"] = true
                foreground.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try await wait("foreground after model fixture shutdown") { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }

                let unsupported = FocusedText.read(pid: original.pid, element: pasteOnly)
                await service.insert("must stay ready", into: unsupported)
                try require(service.outcome == .readyToPaste && NSPasteboard.general.changeCount == clipboardCount, "Unsupported target did not preserve manual recovery")
                await service.insert("missing target", into: nil)
                try require(service.outcome == .readyToPaste, "Missing target recaptured another field")
                var changedDocument = original
                changedDocument.document = "file:///a-different-document"
                await service.insert("stale document", into: changedDocument)
                try require(service.outcome == .readyToPaste, "Changed document accepted insertion")
                var changedIdentity = original
                changedIdentity.identity[kAXDescriptionAttribute] = "A different destination"
                await service.insert("reused control", into: changedIdentity)
                try require(service.outcome == .readyToPaste, "Reused control identity accepted insertion")
                report["unsupportedAndMissingTargets"] = true

                let ambiguous = FocusedText.read(pid: original.pid, element: unconfirmed)
                await service.insert("unconfirmed", into: ambiguous)
                try require(service.outcome == .failure(.insertionNotAcknowledged), "Accepted no-op write claimed success")
                try require(NSPasteboard.general.changeCount == clipboardCount, "Ambiguous write attempted a duplicate paste")
                report["ambiguousWriteNotRetried"] = true

                let old = overlay.begin(onCancel: {})
                let current = overlay.begin(onCancel: {})
                overlay.update(.listening, committed: "New recording", session: current)
                overlay.showCompletion(.inserted(.init(application: "Original Field Target", words: 3, seconds: 0.2)), session: old)
                try require(overlay.model.phase == .listening, "Older result replaced a new recording")
                overlay.hide(session: current)
                try await wait("queued completion") { if case .inserted = overlay.model.phase { return true }; return false }
                try await Task.sleep(for: .milliseconds(700))
                try capture(overlay, to: root.appendingPathComponent("delivery-notice.png"))
                try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "Delivery notice stole focus")
                report["destinationNoticeQueuedWithoutFocusChange"] = true
                let readyNotice = overlay.begin(onCancel: {})
                overlay.showCompletion(.readyToPaste(application: "Original Field Target"), session: readyNotice)
                try await Task.sleep(for: .milliseconds(250))
                try capture(overlay, to: root.appendingPathComponent("ready-notice.png"))
                overlay.shutdown()

                target.activate(options: [.activateIgnoringOtherApps])
                try await wait("manual recovery target") { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
                try set(pasteOnly, kAXFocusedAttribute, kCFBooleanTrue)
                try await wait("manual recovery field") { FocusedText.capture().map { CFEqual($0.element, pasteOnly) } ?? false }
                await service.insert("manual")
                try require(service.outcome == .success, "Manual paste recovery failed: " + service.status)
                report["manualPasteRecovery"] = true

                guard let window = original.window, let close = attribute(window, kAXCloseButtonAttribute) else { throw Failure("Target close button missing") }
                try require(AXUIElementPerformAction(unsafeDowncast(close, to: AXUIElement.self), kAXPressAction as CFString) == .success, "Target did not close")
                app.activate(ignoringOtherApps: true)
                try await wait("closed target foreground") { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
                await service.insert("closed target", into: original)
                try require(service.outcome == .readyToPaste, "Closed target received text")
                report["closedWindowRejected"] = true
                if let slack = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.tinyspeck.slackmacgap" }) {
                    let axApp = AXUIElementCreateApplication(slack.processIdentifier)
                    AXUIElementSetMessagingTimeout(axApp, 0.05)
                    if let focused = attribute(axApp, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                        let field = unsafeDowncast(focused, to: AXUIElement.self)
                        AXUIElementSetMessagingTimeout(field, 0.05)
                        var settable = DarwinBoolean(false)
                        report["slackFocusedRole"] = attribute(field, kAXRoleAttribute) as? String
                        report["slackSelectedTextWritable"] = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
                    }
                }
                report["passed"] = true
            } catch {
                report["passed"] = false
                report["error"] = String(describing: error)
            }
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor private static func descendants(_ element: AXUIElement, depth: Int = 0) -> [String: AXUIElement] {
        guard depth < 12 else { return [:] }
        var result: [String: AXUIElement] = [:]
        if let id = attribute(element, kAXIdentifierAttribute) as? String { result[id] = element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            result.merge(descendants(child, depth: depth + 1), uniquingKeysWith: { first, _ in first })
        }
        return result
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        try require(AXUIElementSetAttributeValue(element, name as CFString, value) == .success, "Could not set " + name)
    }
    private static func require(_ condition: Bool, _ reason: String) throws { if !condition { throw Failure(reason) } }
    @MainActor private static func capture(_ overlay: OverlayController, to url: URL) throws {
        guard let view = NSApplication.shared.windows.first(where: { $0.title == "gob.lin Dictation" && $0.isVisible })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Notice window missing") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    @MainActor private static func wait(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try require(ContinuousClock.now < deadline, "Timed out: \(name); foreground=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
}
