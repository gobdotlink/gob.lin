import AppKit
import AVFoundation
import Combine
import Foundation
@testable import GoblinApp
import GoblinCore
import GoblinEngines

@main
struct NativeDictationCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        Task { @MainActor in
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suite = "app.goblin.native-check." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "audio.keepMicrophoneWarm")
            let model = AppModel(dataDirectory: directory.appendingPathComponent(UUID().uuidString), defaults: defaults)
            var report: [String: Any] = ["pid": getpid(), "executable": Bundle.main.executableURL!.path,
                "microphone": model.permissions.snapshot.microphone.rawValue,
                "accessibility": model.permissions.snapshot.accessibility]
            do {
                guard model.permissions.snapshot.microphone == .authorized, model.permissions.snapshot.accessibility else {
                    throw CheckFailure("Signed app context does not have microphone and Accessibility permission")
                }
                defaults.set(DictationTone.casual.rawValue, forKey: DictationTone.preferenceKey)
                guard model.dictionary.put(DictionaryEntry(spelling: "gob.lin", aliases: ["goblin"])) else {
                    throw CheckFailure("Isolated dictionary could not be saved")
                }
                model.refreshConfiguration()
                model.hotkeys.setShortcut(.optionSpace)
                try await wait("hotkey event tap", seconds: 5) { model.permissions.tapFailure == nil && model.hotkeys.lastFailure == nil }
                try await wait("actual model preparation", seconds: 90) { model.speechModels.state == .ready }
                let target = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "app.goblin.native-dictation-target" }
                guard let target else { throw CheckFailure("Isolated target app is missing") }
                target.activate()
                try await wait("target focus", seconds: 5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
                let source = Bundle.main.resourceURL!.appendingPathComponent("speech.aiff")
                let audioDuration = try AVAudioFile(forReading: source).length
                report["sourceFrames"] = audioDuration
                var firstText: Double?
                var releasedAt: ContinuousClock.Instant?
                var finalTextMilliseconds: Double?
                let started = ContinuousClock.now
                let subscription = model.overlay.model.$committedText.combineLatest(model.overlay.model.$tentativeText).sink { committed, tentative in
                    if firstText == nil, !(committed + tentative).isEmpty { firstText = milliseconds(since: started) }

                }
                let clipboardBefore = NSPasteboard.general.string(forType: .string)
                let finalSubscription = model.$lastTranscript.dropFirst().sink { _ in
                    if let releasedAt, finalTextMilliseconds == nil { finalTextMilliseconds = milliseconds(since: releasedAt) }
                }
                post(down: true)
                try await wait("native hotkey capture readiness", seconds: 5) { model.overlay.model.phase == .listening }
                try await play(source)
                let hadLiveText = !model.overlay.model.committedText.isEmpty || !model.overlay.model.tentativeText.isEmpty
                if let view = app.windows.first(where: { $0.title == "gob.lin Dictation" })?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("overlay-live.png"))
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      app.windows.allSatisfy({ !$0.canBecomeKey }) else { throw CheckFailure("Overlay stole target focus") }
                releasedAt = .now
                post(down: false)
                try await wait("dictation history and insertion", seconds: 15) { !model.history.entries.isEmpty && model.speechModels.activeSessionCount == 0 }
                subscription.cancel()
                finalSubscription.cancel()
                guard let entry = model.history.entries.first, !entry.rawText.isEmpty else { throw CheckFailure("Native microphone produced no recognized text") }
                guard case .success = model.insertion.outcome else { throw CheckFailure("Native target insertion was not acknowledged: \(model.insertion.status)") }
                let targetTextURL = target.bundleURL!.deletingLastPathComponent().appendingPathComponent("target-text.txt")
                try await wait("target text observation", seconds: 3) {
                    (try? String(contentsOf: targetTextURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == entry.finalText
                }
                guard let audio = try await model.history.store?.audioFileURL(for: entry.id), FileManager.default.isReadableFile(atPath: audio.path) else {
                    throw CheckFailure("History did not retain original capture audio")
                }
                guard NSPasteboard.general.string(forType: .string) == clipboardBefore else {
                    throw CheckFailure("Acknowledged paste did not restore the original clipboard")
                }
                report["clipboardRestored"] = true
                report["recognizedWords"] = entry.wordCount
                report["hadLiveText"] = hadLiveText
                report["firstTextMilliseconds"] = firstText
                report["releaseToFinalTextMilliseconds"] = finalTextMilliseconds
                report["timings"] = DiagnosticsReport.timingLines(entry.latencies)
                report["capturedDuration"] = entry.audioDuration
                report["insertionAcknowledged"] = true
                report["insertionStatus"] = model.insertion.status
                report["rawText"] = entry.rawText
                report["finalText"] = entry.finalText

                let count = model.history.entries.count
                post(down: true)
                try await wait("cancel capture readiness", seconds: 5) { model.overlay.model.phase == .listening }
                try await Task.sleep(for: .milliseconds(450))
                let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
                escape.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
                post(down: false)
                try await wait("cancel drain", seconds: 5) { model.speechModels.activeSessionCount == 0 && model.overlay.model.phase == .hidden }
                guard model.history.entries.count == count else { throw CheckFailure("Cancelled capture wrote a transcript") }
                report["cancelSuppressedOutput"] = true

                // Real unload/reload, with capture opening before recognition becomes ready.
                model.speechModels.unloadIfIdle(now: .now.advanced(by: .seconds(3_601)))
                try await wait("idle model unload", seconds: 10) { model.speechModels.state == .unloaded }
                var capturedBeforeReady = false
                let loadingSubscription = model.overlay.model.$phase.sink { phase in
                    if phase == .listening && model.speechModels.state != .ready { capturedBeforeReady = true }
                }
                post(down: true)
                try await wait("capture during model reload", seconds: 5) { model.overlay.model.phase == .listening }
                try await play(source)
                let height = model.overlay.model.textHeight
                let previousText = model.overlay.model.committedText + model.overlay.model.tentativeText
                post(down: false)
                try await wait("visible finalization", seconds: 2) { model.overlay.model.phase == .transcribing || model.overlay.model.phase == .polishing }
                guard model.overlay.model.textHeight == height,
                      !(model.overlay.model.committedText + model.overlay.model.tentativeText).isEmpty,
                      !previousText.isEmpty else { throw CheckFailure("Finalization discarded the visible live text") }
                try await Task.sleep(for: .milliseconds(90))
                await tap()
                try await wait("new capture while prior output drains", seconds: 5) { model.overlay.model.phase == .listening && model.hotkeys.recording != nil }
                let overlappingLeases = model.speechModels.activeSessionCount
                try await wait("prior output history", seconds: 10) { model.history.entries.count == count + 1 }
                guard model.overlay.model.phase == .listening, model.hotkeys.recording != nil else {
                    throw CheckFailure("Prior completion replaced or hid a newer capture")
                }
                try await play(source)
                await tap()
                try await wait("ordered overlapping history", seconds: 15) { model.history.entries.count == count + 2 && model.speechModels.activeSessionCount == 0 }
                loadingSubscription.cancel()
                report["captureBeforeModelReady"] = capturedBeforeReady
                report["maximumOverlappingLeases"] = overlappingLeases
                report["newCaptureSurvivedPriorCompletion"] = true
                report["finalizationPreservedTextArea"] = true
                guard case .success = model.insertion.outcome else { throw CheckFailure("Overlapping capture final insertion was not acknowledged") }

                // Compare the production live result with an independent decode of its saved original audio.
                let lease = try model.speechModels.beginSession()
                let runtime = try await model.speechModels.readyEngine(for: lease)
                var comparisons: [[String: Any]] = []
                for recorded in model.history.entries {
                    guard let audio = try await model.history.store?.audioFileURL(for: recorded.id) else { throw CheckFailure("An overlapping dictation lost original audio") }
                    let batch = try await RecordedAudioPipeline(engine: runtime).transcribe(audio)
                    let processed = await model.processTranscript(recorded.rawText)
                    guard processed.finalText == recorded.finalText else { throw CheckFailure("History bypassed shared final postprocessing") }
                    comparisons.append(["audioSeconds": recorded.audioDuration, "liveEqualsBatch": recorded.rawText == batch.rawText,
                        "endingPreserved": recorded.rawText.lowercased().contains("purple violet"), "wordCount": recorded.wordCount])
                }
                model.speechModels.endSession(lease)
                report["batchComparisons"] = comparisons
                guard entry.finalText.contains("gob.lin"), entry.tone == DictationTone.casual.rawValue,
                      !entry.finalText.hasSuffix(".") else { throw CheckFailure("Final output bypassed dictionary or tone preferences") }
                report["dictionaryAndToneApplied"] = true

                let beforeFinalCancel = model.history.entries.count
                post(down: true)
                try await wait("final cancel capture readiness", seconds: 5) { model.overlay.model.phase == .listening }
                model.audioPreview.start(uid: defaults.string(forKey: "audio.inputDeviceUID") ?? "")
                guard model.audioPreview.running else { throw CheckFailure("Settings preview could not join active capture") }
                model.audioPreview.stop()
                guard model.hotkeys.recording != nil else { throw CheckFailure("Closing preview stopped dictation") }
                report["sharedPreviewPreservedCapture"] = true
                try await play(source)
                post(down: false)
                try await wait("cancelable finalization", seconds: 2) { model.overlay.model.phase == .transcribing }
                model.overlay.model.cancel()
                try await wait("finalization cancel drain", seconds: 5) { model.speechModels.activeSessionCount == 0 && model.overlay.model.phase == .hidden }
                guard model.history.entries.count == beforeFinalCancel else { throw CheckFailure("Cancel before final recognition produced output") }
                report["finalizationCancelSuppressedOutput"] = true

                let configuration = directory.deletingLastPathComponent().appendingPathComponent("durations.json")
                let durations = (try? JSONDecoder().decode([Double].self, from: Data(contentsOf: configuration))) ?? []
                var longRuns: [[String: Any]] = []
                for duration in durations {
                    guard duration.isFinite, duration > 0, duration <= 300 else { throw CheckFailure("Invalid native capture duration") }
                    try await wait("idle overlay", seconds: 5) { model.overlay.model.phase == .hidden }
                    let count = model.history.entries.count
                    var released: ContinuousClock.Instant?
                    var finalized: Double?
                    var firstText: Double?
                    var readyAt: ContinuousClock.Instant?
                    let textSubscription = model.overlay.model.$committedText.combineLatest(model.overlay.model.$tentativeText).sink { committed, tentative in
                        if let readyAt, firstText == nil, !(committed + tentative).isEmpty { firstText = milliseconds(since: readyAt) }

                    }
                    let finalSubscription = model.$lastTranscript.dropFirst().sink { _ in
                        if let released, finalized == nil { finalized = milliseconds(since: released) }
                    }
                    post(down: true)
                    try await wait("timed capture readiness", seconds: 5) { model.overlay.model.phase == .listening }
                    readyAt = .now
                    let playback = Task { @MainActor in
                        while !Task.isCancelled { try await play(source) }
                    }
                    try await Task.sleep(for: .seconds(duration))
                    playback.cancel()
                    _ = try? await playback.value
                    released = .now
                    post(down: false)
                    try await wait("timed final output", seconds: 20) { model.history.entries.count == count + 1 && model.speechModels.activeSessionCount == 0 }
                    let historyMilliseconds = milliseconds(since: released!)
                    textSubscription.cancel()
                    finalSubscription.cancel()
                    guard let recorded = model.history.entries.first,
                          let audio = try await model.history.store?.audioFileURL(for: recorded.id),
                          case .success = model.insertion.outcome else { throw CheckFailure("Timed dictation did not retain or acknowledge output") }
                    let lease = try model.speechModels.beginSession()
                    let runtime = try await model.speechModels.readyEngine(for: lease)
                    let batch = try await RecordedAudioPipeline(engine: runtime).transcribe(audio)
                    model.speechModels.endSession(lease)
                    var metrics: [String: Any] = ["requestedCaptureSeconds": duration, "savedAudioSeconds": recorded.audioDuration,
                        "releaseToHistoryMilliseconds": historyMilliseconds, "liveEqualsBatch": recorded.rawText == batch.rawText,
                        "wordCount": recorded.wordCount, "insertionAcknowledged": true, "timings": DiagnosticsReport.timingLines(recorded.latencies)]
                    metrics["releaseToFinalTextMilliseconds"] = finalized
                    metrics["firstTextMillisecondsFromReady"] = firstText
                    longRuns.append(metrics)
                    try JSONSerialization.data(withJSONObject: longRuns, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("timed-progress.json"))
                }
                report["timedCaptures"] = longRuns
                report["success"] = true
            } catch {
                report["success"] = false
                report["failure"] = String(describing: error)
                report["diagnostics"] = DiagnosticsReport.render(environment: model.diagnostics.environment, activeFailures: model.diagnostics.warnings, events: model.diagnostics.events, timings: model.diagnostics.latestTimings)
            }
            await model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("native-result.json"))
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func post(down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down)!
        event.flags = down ? .maskAlternate : []
        event.post(tap: .cghidEventTap)
    }

    @MainActor static func tap() async {
        post(down: true)
        try? await Task.sleep(for: .milliseconds(20))
        post(down: false)
    }

    @MainActor static func play(_ url: URL) async throws {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        try await wait("speech playback", seconds: 15) { !player.isRunning }
        guard player.terminationStatus == 0 else { throw CheckFailure("Speech playback failed") }
    }

    @MainActor static func wait(_ name: String, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CheckFailure("Timed out waiting for " + name) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let time = start.duration(to: .now).components
        return Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15
    }
    struct CheckFailure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
}
