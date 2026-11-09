import AppKit
import ApplicationServices
import Foundation
@testable import GoblinApp
import GoblinCore
import SwiftUI

/// Dictionary suggestions end to end in a signed app context: the real hotkey, microphone, project detection from
/// TextEdit's open file, the repository read, edit watching, accepting a term and using it in the next dictation.
/// Uses an isolated dictionary, history and preferences. Arguments: results folder, the fixture file open in TextEdit,
/// and two spoken recordings.
@main
struct DictionarySuggestionsCheck {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let checkShortcut = HotkeyShortcut(keyCode: 50,
        modifiers: CGEventFlags.maskControl.union(.maskAlternate).union(.maskShift).rawValue, keyLabel: "Grave")

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        let arguments = CommandLine.arguments
        let results = URL(fileURLWithPath: arguments[1]), notes = URL(fileURLWithPath: arguments[2])
        fixture = notes
        let speech = (URL(fileURLWithPath: arguments[3]), URL(fileURLWithPath: arguments[4]))
        Task { @MainActor in
            let suite = "app.goblin.suggestions-check." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set("parakeet-tdt-v3", forKey: "speechModelID")
            defaults.set(DictationTone.casual.rawValue, forKey: DictationTone.preferenceKey)
            let model = AppModel(dataDirectory: results.appendingPathComponent("data"), defaults: defaults)
            var report: [String: Any] = [:]
            do {
                try await run(model, defaults: defaults, notes: notes, speech: speech, results: results, report: &report)
                report["passed"] = true
            } catch {
                report["passed"] = false
                report["failure"] = String(describing: error)
            }
            await model.shutdown()
            if model.insertion.hasRecoveryClipboard { model.insertion.restorePreviousClipboard() }
            defaults.removePersistentDomain(forName: suite)
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: results.appendingPathComponent("suggestions-result.json"))
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func run(_ model: AppModel, defaults: UserDefaults, notes: URL, speech: (URL, URL), results: URL,
                               report: inout [String: Any]) async throws {
        guard model.permissions.snapshot.microphone == .authorized, model.permissions.snapshot.accessibility else {
            throw CheckFailure("Signed app context does not have microphone and Accessibility permission")
        }
        guard model.dictionary.suggestsTerms, model.dictionary.entries.isEmpty else { throw CheckFailure("Suggestions should start on with an empty dictionary") }
        model.refreshConfiguration()
        model.hotkeys.setShortcut(checkShortcut)
        try await Task.sleep(for: .seconds(1))
        guard model.hotkeys.lastFailure == nil else { throw CheckFailure("Hotkey failed: \(String(describing: model.hotkeys.lastFailure))") }
        try await wait("speech model", seconds: 90) { model.speechModels.state == .ready }
        guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
              let textEditURL = textEdit.bundleURL else { throw CheckFailure("Open the fixture in TextEdit first") }
        _ = try await NSWorkspace.shared.open([notes], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration())
        textEdit.activate()
        try await wait("TextEdit focus", seconds: 5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEdit.processIdentifier }
        try setText(textEdit, "")

        // 1. No term lists a project, so detection runs only because suggestions are on.
        report["focusedDocument"] = focusedDocument(textEdit) as Any
        let first = try await dictate(model, speech.0)
        report["first"] = ["raw": first.rawText, "final": first.finalText, "recordedProject": first.dictionaryProject as Any]
        try await wait("project detection", seconds: 3) { model.dictionary.lastContext?.project != nil }
        let project = model.dictionary.lastContext!.project!
        report["detectedProject"] = ["name": project.name, "source": project.source.rawValue, "root": project.root?.path as Any]
        guard project.name == "quixlo", project.root?.resolvingSymlinksInPath() == notes.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw CheckFailure("Detected \(project.name) at \(String(describing: project.root))")
        }
        try await wait("repository suggestions", seconds: 5) { model.dictionary.suggestions.contains { $0.reason == .folder } }
        let found = model.dictionary.suggestions
        report["repositorySuggestions"] = found.map { "\($0.spelling) · \($0.reason) · \($0.projects)" }
        let spellings = Set(found.map(\.spelling))
        guard ["quixlo", "QuixloKit", "Fluxomatic"].allSatisfy(spellings.contains), !spellings.contains("Sources"),
              !spellings.contains("node_modules"), found.allSatisfy({ $0.projects == ["quixlo"] && $0.apps.isEmpty }) else {
            throw CheckFailure("Unexpected repository suggestions: \(found.map(\.spelling))")
        }
        try render(popover(model), size: CGSize(width: 400, height: 640), to: results.appendingPathComponent("popover.png"))
        try render(page(model, defaults: defaults), size: CGSize(width: 650, height: 1300), to: results.appendingPathComponent("dictionary-page.png"))

        // 2. Respell whatever was heard between "the" and "build"; the watcher reports the edit 30 s after insertion.
        let inserted = try text(textEdit)
        var words = inserted.split(separator: " ").map(String.init)
        guard let build = words.firstIndex(where: { $0.lowercased().hasPrefix("build") }),
              let the = words[..<build].lastIndex(where: { $0.lowercased() == "the" }), build - the - 1 >= 1, build - the - 1 <= 3 else {
            throw CheckFailure("Can't find the name to fix in “\(inserted)”")
        }
        let heard = words[(the + 1)..<build].joined(separator: " ")
        words.replaceSubrange((the + 1)..<build, with: ["Qorblaxx"])
        try setText(textEdit, words.joined(separator: " "))
        report["edit"] = ["inserted": inserted, "edited": words.joined(separator: " "), "heard": heard]
        try await wait("correction suggestion", seconds: 45) { model.dictionary.suggestions.contains { $0.spelling == "Qorblaxx" } }
        let fix = model.dictionary.suggestions.first { $0.spelling == "Qorblaxx" }!
        report["correction"] = ["aliases": fix.aliases, "projects": fix.projects, "apps": fix.apps, "reason": "\(fix.reason)",
                                "rank": model.dictionary.suggestions.firstIndex(of: fix)!]
        guard fix.projects == ["quixlo"], fix.apps.isEmpty, fix.aliases == [heard], model.dictionary.suggestions.first == fix else {
            throw CheckFailure("Correction suggestion has the wrong place or rank: \(fix)")
        }
        try render(page(model, defaults: defaults), size: CGSize(width: 650, height: 1300), to: results.appendingPathComponent("dictionary-page-correction.png"))

        // 3. Accept the fix, dismiss a folder, and check the project is listed.
        model.dictionary.accept(fix)
        guard let term = model.dictionary.entries.first(where: { $0.spelling == "Qorblaxx" }), term.projects == ["quixlo"], term.apps.isEmpty else {
            throw CheckFailure("Accepting didn't add a project term: \(model.dictionary.entries)")
        }
        guard model.dictionary.places.apps.contains(where: { $0.projects.contains { $0.name == "quixlo" } }) else {
            throw CheckFailure("The project isn't listed under its app")
        }
        if let folder = model.dictionary.suggestions.first(where: { $0.spelling == "Fluxomatic" }) {
            model.dictionary.dismiss(folder)
            guard !model.dictionary.suggestions.contains(folder),
                  defaults.stringArray(forKey: DictionaryModel.dismissedSuggestionsKey)?.contains(folder.id) == true else {
                throw CheckFailure("Dismissal didn't stick")
            }
        }
        report["remainingSuggestions"] = model.dictionary.suggestions.map(\.spelling)

        // 4. With a project term, the next dictation waits for the project and uses the term.
        textEdit.activate()
        try await wait("TextEdit focus", seconds: 5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEdit.processIdentifier }
        try? setText(textEdit, "")
        let second = try await dictate(model, speech.1)
        report["second"] = ["raw": second.rawText, "final": second.finalText, "recordedProject": second.dictionaryProject as Any,
                            "aliasApplied": second.finalText.contains("Qorblaxx")]
        guard second.dictionaryProject == "quixlo" else { throw CheckFailure("The second dictation didn't record the project") }
        try? setText(textEdit, "")
    }

    @MainActor static func dictate(_ model: AppModel, _ speech: URL) async throws -> HistoryEntry {
        let before = model.history.entries.first?.id
        post(down: true)
        try await wait("listening", seconds: 5) { model.overlay.model.phase == .listening }
        try await play(speech)
        post(down: false)
        try await wait("history entry", seconds: 20) {
            model.history.entries.first.map { $0.id != before } == true && model.speechModels.activeSessionCount == 0
        }
        return model.history.entries.first!
    }

    @MainActor static func popover(_ model: AppModel) -> some View {
        MenuPopover(model: model)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(20).frame(maxHeight: .infinity, alignment: .top).caseBackground()
    }

    @MainActor static func page(_ model: AppModel, defaults: UserDefaults) -> some View {
        Form { DictionarySettingsView(model: model.dictionary, service: model.speechModels, defaults: defaults) }
            .formStyle(PlateFormStyle()).defaultScrollAnchor(.top).caseBackground()
    }

    @MainActor static func render(_ view: some View, size: CGSize, to file: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure("Could not render \(file.lastPathComponent)") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }

    /// The text view of the TextEdit window showing the fixture, raised to the front.
    @MainActor static var fixture: URL!

    @MainActor static func textArea(_ app: NSRunningApplication) throws -> AXUIElement {
        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? String
        }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if string(element, kAXRoleAttribute) == kAXTextAreaRole { return element }
            guard depth < 6 else { return nil }
            return children(element, kAXChildrenAttribute).lazy.compactMap { find($0, depth: depth + 1) }.first
        }
        let windows = children(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
        guard let window = windows.first(where: { string($0, kAXDocumentAttribute).flatMap(URL.init(string:))?.resolvingSymlinksInPath().path
                                                   == fixture.resolvingSymlinksInPath().path }),
              let area = find(window, depth: 0) else { throw CheckFailure("TextEdit has no window for the fixture") }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return area
    }

    @MainActor static func focusedDocument(_ app: NSRunningApplication) -> String? {
        var window: CFTypeRef?, document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document)
        return document as? String
    }

    @MainActor static func text(_ app: NSRunningApplication) throws -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(try textArea(app), kAXValueAttribute as CFString, &value)
        return ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static func setText(_ app: NSRunningApplication, _ text: String) throws {
        guard AXUIElementSetAttributeValue(try textArea(app), kAXValueAttribute as CFString, text as CFString) == .success else {
            throw CheckFailure("Could not edit TextEdit's text")
        }
    }

    @MainActor static func post(down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: checkShortcut.keyCode!, keyDown: down)!
        event.flags = down ? CGEventFlags(rawValue: checkShortcut.modifiers) : []
        event.post(tap: .cghidEventTap)
    }

    @MainActor static func play(_ url: URL) async throws {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        try player.run()
        try await wait("speech playback", seconds: 15) { !player.isRunning }
        try await Task.sleep(for: .milliseconds(400))
    }

    @MainActor static func wait(_ name: String, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure("Timed out waiting for " + name) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
