import AppKit
import AVFoundation
import Combine
import Foundation
@testable import GoblinApp
import GoblinCore
import GoblinEngines

@main
struct NativeDictationCheck {
    @MainActor private static var targetFocusLost = false
    private static let checkShortcut = HotkeyShortcut(keyCode: 50,
        modifiers: CGEventFlags.maskControl.union(.maskAlternate).union(.maskShift).rawValue,
        modifier: nil, keyLabel: "Grave")
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
            var focusSubscription: AnyCancellable?
            var ownedClipboardCount: Int?
            let clipboardSubscription = model.insertion.$hasRecoveryClipboard.sink { ownsClipboard in
                ownedClipboardCount = ownsClipboard ? NSPasteboard.general.changeCount : nil
            }
            do {
                guard model.permissions.snapshot.microphone == .authorized, model.permissions.snapshot.accessibility else {
                    throw CheckFailure("Signed app context does not have microphone and Accessibility permission")
                }
                defaults.set(DictationTone.casual.rawValue, forKey: DictationTone.preferenceKey)
                guard model.dictionary.put(DictionaryEntry(spelling: "gob.lin", aliases: ["goblin"])) else {
                    throw CheckFailure("Isolated dictionary could not be saved")
                }
                model.refreshConfiguration()
                let beforeTap = (try? model.diagnostics.developmentLog.recentText()) ?? ""
                model.hotkeys.setShortcut(checkShortcut)
                try await wait("confirmed hotkey event tap", seconds: 5) {
                    guard model.hotkeys.lastFailure == nil,
                          let log = try? model.diagnostics.developmentLog.recentText(), log.hasPrefix(beforeTap) else { return false }
                    return log.dropFirst(beforeTap.count).split(separator: "\n").contains { line in
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let details = event["details"] as? [String: Any] else { return false }
                        return event["event"] as? String == "hotkeyReady" && details["succeeded"] as? Bool == true
                    }
                }
                report["nativeShortcut"] = checkShortcut.label
                try await wait("actual model preparation", seconds: 90) { model.speechModels.state == .ready }
                let target = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "app.goblin.native-dictation-target" }
                guard let target else { throw CheckFailure("Isolated target app is missing") }
                target.activate()
                try await wait("target focus", seconds: 5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
                focusSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
                    .receive(on: DispatchQueue.main).sink { notification in
                        guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                              activated.processIdentifier != target.processIdentifier,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier else { return }
                        report["focusLossPhase"] = String(describing: model.overlay.model.phase)
                        report["focusLossAppWasProbe"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
                        report["focusLossApplication"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        targetFocusLost = true
                        model.hotkeys.cancelRecording()
                        model.overlay.model.cancel()
                    }
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
                if let input = await AudioCaptureService.shared.inputResolution {
                    report["inputDevice"] = input.device.name
                    report["inputUsedFallback"] = input.usedFallback
                    report["inputFollowsSystemDefault"] = input.requestedUID.isEmpty
                }
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

                var count = model.history.entries.count
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

                // A valid capture can join a Settings cancellation while the real load drains.
                model.speechModels.unloadIfIdle(now: .now.advanced(by: .seconds(3_601)))
                try await wait("model unload before preparation cancellation", seconds: 10) { model.speechModels.state == .unloaded }
                model.speechModels.preload()
                try await wait("real runtime preparation", seconds: 5) {
                    if case .preparing(let progress) = model.speechModels.state { return progress.phase == .compiling || progress.phase == .loading }
                    return model.speechModels.state == .ready
                }
                let cancellationIssued = model.speechModels.isPreparing
                model.speechModels.cancelPreparation()
                var joinedCancellation = false
                let cancellationSubscription = model.speechModels.$activeSessionCount.sink { leases in
                    if leases > 0 && model.speechModels.state == .cancelling { joinedCancellation = true }
                }
                await tap()
                try await wait("valid capture after Settings cancel", seconds: 5) { model.overlay.model.phase == .listening }
                try await play(source)
                await tap()
                try await wait("valid output after Settings cancel", seconds: 15) { model.history.entries.count == count + 1 && model.speechModels.activeSessionCount == 0 }
                cancellationSubscription.cancel()
                guard case .success = model.insertion.outcome else { throw CheckFailure("Settings cancellation disrupted the new dictation") }
                report["settingsPreparationCancellationIssued"] = cancellationIssued
                report["validLeaseJoinedCancellation"] = joinedCancellation
                report["dictationSurvivedSettingsCancellation"] = true
                count = model.history.entries.count

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
                let previousText = model.overlay.model.committedText + model.overlay.model.tentativeText
                post(down: false)
                try await wait("visible finalization", seconds: 2) { model.overlay.model.phase == .transcribing || model.overlay.model.phase == .polishing }
                // The panel is a fixed size, so only the words need checking here.
                guard !(model.overlay.model.committedText + model.overlay.model.tentativeText).isEmpty,
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
                try await wait("both overlapping captures saved", seconds: 15) { model.history.entries.count == count + 2 && model.speechModels.activeSessionCount == 0 }
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
                // The preview opens on the capture thread.
                do { try await wait("Settings preview joining active capture", seconds: 2) { model.audioPreview.running } }
                catch { throw CheckFailure("Settings preview could not join active capture: \(model.audioPreview.error ?? "no error")") }
                model.audioPreview.stop()
                // Closing it is asynchronous too; give it time to land before checking the capture survived.
                try await Task.sleep(for: .milliseconds(300))
                guard model.hotkeys.recording != nil, model.overlay.model.phase == .listening,
                      await AudioCaptureService.shared.activeSessionID != nil else { throw CheckFailure("Closing preview stopped dictation") }
                report["sharedPreviewPreservedCapture"] = true
                try await play(source)
                post(down: false)
                try await wait("cancelable finalization", seconds: 2) { model.overlay.model.phase == .transcribing }
                model.overlay.model.cancel()
                try await wait("finalization cancel drain", seconds: 5) { model.speechModels.activeSessionCount == 0 && model.overlay.model.phase == .hidden }
                guard model.history.entries.count == beforeFinalCancel else { throw CheckFailure("Cancel before final recognition produced output") }
                report["finalizationCancelSuppressedOutput"] = true

                report["automaticSuspension"] = try await checkSuspension(model, source: source, targetTextURL: targetTextURL)
                report["stopFailureRecovery"] = try await checkStopFailure(model, source: source)
                report["pendingSourceOwnership"] = try await checkHistoryOwnership(model.history, original: audio)

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
            focusSubscription?.cancel()
            report["isolatedTargetFocusLost"] = targetFocusLost
            await model.shutdown()
            clipboardSubscription.cancel()
            if model.insertion.hasRecoveryClipboard, ownedClipboardCount == NSPasteboard.general.changeCount {
                model.insertion.restorePreviousClipboard()
            }
            defaults.removePersistentDomain(forName: suite)
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("native-result.json"))
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func checkSuspension(_ model: AppModel, source: URL, targetTextURL: URL) async throws -> [String: Any] {
        try await wait("idle before automatic suspension", seconds: 5) { model.overlay.model.phase == .hidden }
        let count = model.history.entries.count
        let targetBefore = try String(contentsOf: targetTextURL, encoding: .utf8)
        let clipboardCount = NSPasteboard.general.changeCount
        post(down: true)
        try await wait("automatic suspension capture", seconds: 5) { model.overlay.model.phase == .listening }
        try await play(source)
        model.hotkeys.stop()
        post(down: false)
        try await wait("automatic suspension History", seconds: 15) {
            model.history.entries.count == count + 1 && model.speechModels.activeSessionCount == 0
        }
        guard let saved = model.history.entries.first, !saved.rawText.isEmpty, !saved.finalText.isEmpty,
              saved.latencies.insertionMilliseconds == 0,
              let audio = try await model.history.store?.audioFileURL(for: saved.id),
              try AVAudioFile(forReading: audio).length > 0,
              try String(contentsOf: targetTextURL, encoding: .utf8) == targetBefore,
              NSPasteboard.general.changeCount == clipboardCount else {
            throw CheckFailure("Automatic monitoring suspension lost audio/text or pasted into the target")
        }
        let beforeTap = (try? model.diagnostics.developmentLog.recentText()) ?? ""
        model.hotkeys.start()
        try await wait("monitoring restored after suspension", seconds: 5) {
            guard let log = try? model.diagnostics.developmentLog.recentText(), log.hasPrefix(beforeTap) else { return false }
            return log.dropFirst(beforeTap.count).split(separator: "\n").contains { line in
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let details = event["details"] as? [String: Any] else { return false }
                return event["event"] as? String == "hotkeyReady" && details["succeeded"] as? Bool == true
            }
        }
        return ["historyOnly": true, "originalAudioReadable": true, "finalTextRetained": true,
                "targetAndClipboardUnchanged": true, "monitoringRestored": true]
    }

    @MainActor static func checkStopFailure(_ model: AppModel, source: URL) async throws -> [String: Any] {
        try await wait("idle before stop failure", seconds: 5) { model.overlay.model.phase == .hidden }
        guard let store = model.history.store else { throw CheckFailure("Missing isolated History store") }
        let captures = store.directory.appendingPathComponent("Captures", isDirectory: true)
        let permissions = try FileManager.default.attributesOfItem(atPath: captures.path)[.posixPermissions]!
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: captures.path) }
        let count = model.history.entries.count
        let previousTranscript = model.lastTranscript
        post(down: true)
        try await wait("stop failure capture", seconds: 5) { model.overlay.model.phase == .listening }
        try await play(source)
        // Existing file writes remain valid; only the private test directory's final rename is denied.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: captures.path)
        post(down: false)
        try await wait("failed stop recovery History", seconds: 10) {
            model.history.entries.count == count + 1 && model.speechModels.activeSessionCount == 0
        }
        guard let failed = model.history.entries.first, failed.rawText.isEmpty, failed.finalText.isEmpty,
              failed.processingWarning != nil, failed.audioDuration > 0,
              let audio = try await store.audioFileURL(for: failed.id), try AVAudioFile(forReading: audio).length > 0,
              model.lastTranscript == previousTranscript, model.canPasteLastTranscript,
              model.diagnostics.latestTimings == failed.latencies else {
            throw CheckFailure("Stop failure lost readable recovery or erased the last successful transcript/timings")
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: captures.path)
        for url in try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasSuffix(".partial.wav") {
            try FileManager.default.removeItem(at: url)
        }
        return ["failedEntryAndAudioRetained": true, "lastTranscriptPreserved": true, "failureTimingsRecorded": true]
    }

    @MainActor static func checkHistoryOwnership(_ history: HistoryModel, original: URL) async throws -> [String: Any] {
        guard let store = history.store, history.pending.isEmpty else { throw CheckFailure("Missing clean isolated History store") }
        let owned = store.directory.appendingPathComponent(UUID().uuidString + ".wav")
        try FileManager.default.copyItem(at: original, to: owned)
        let audioDirectory = store.directory.appendingPathComponent("audio", isDirectory: true)
        let heldDirectory = store.directory.appendingPathComponent("audio-held", isDirectory: true)
        try FileManager.default.moveItem(at: audioDirectory, to: heldDirectory)
        defer {
            if FileManager.default.fileExists(atPath: heldDirectory.path) {
                try? FileManager.default.moveItem(at: heldDirectory, to: audioDirectory)
            }
        }
        let finalText = history.entries.first(where: { !$0.finalText.isEmpty })?.finalText ?? ""
        let ownedEntry = HistoryEntry(rawText: finalText, finalText: finalText)
        let borrowedEntry = HistoryEntry(rawText: finalText, finalText: finalText)
        let ownedSaved = await history.record(ownedEntry, untrimmedAudioURL: owned, ownsAudioSource: true)
        let borrowedSaved = await history.record(borrowedEntry, untrimmedAudioURL: original)
        guard !ownedSaved, !borrowedSaved, history.pending.count == 2,
              history.pending.first(where: { $0.id == ownedEntry.id })?.ownsAudioSource == true,
              history.pending.first(where: { $0.id == borrowedEntry.id })?.ownsAudioSource == false else {
            throw CheckFailure("Failed saves did not retain capture source ownership")
        }
        await history.retryPending()
        guard history.pending.count == 2, FileManager.default.isReadableFile(atPath: owned.path) else {
            throw CheckFailure("Failed retry deleted its owned audio source")
        }
        try FileManager.default.moveItem(at: heldDirectory, to: audioDirectory)
        await history.retryPending()
        guard history.pending.isEmpty, !FileManager.default.fileExists(atPath: owned.path),
              FileManager.default.isReadableFile(atPath: original.path),
              let ownedCopy = try await store.audioFileURL(for: ownedEntry.id),
              let borrowedCopy = try await store.audioFileURL(for: borrowedEntry.id),
              try AVAudioFile(forReading: ownedCopy).length > 0, try AVAudioFile(forReading: borrowedCopy).length > 0 else {
            throw CheckFailure("Successful retry leaked capture audio or deleted a borrowed History source")
        }
        return ["retryFailureKeptOwnedSource": true, "retrySuccessRemovedOwnedSource": true,
                "borrowedHistorySourcePreserved": true, "savedCopiesReadable": true]
    }

    @MainActor static func post(down: Bool) {
        guard !down || !targetFocusLost else { return }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: checkShortcut.keyCode!, keyDown: down)!
        event.flags = down ? CGEventFlags(rawValue: checkShortcut.modifiers) : []
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
            guard !targetFocusLost else { throw CheckFailure("Reserved native target lost focus; check canceled") }
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
