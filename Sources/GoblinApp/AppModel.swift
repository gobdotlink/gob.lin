import AppKit
import AVFoundation
import Combine
import GoblinCore
import GoblinEngines
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let defaults: UserDefaults
    let servicesEnabled: Bool
    let overlay = OverlayController()
    let processor = TranscriptPostprocessor()
    private let rewriteCredentials = RewriteCredentials()
    let diagnostics: DiagnosticsModel
    let dictionary: DictionaryModel
    let history: HistoryModel
    let permissions: PermissionModel
    let hotkeys: HotkeyService
    let insertion: TextInsertionService
    private let editWatcher = PostPasteWatcher()
    private var pendingEditObservationID: UUID?
    let audioPreview: AudioPreviewModel
    let speechModels: SpeechModelService
    let updates = UpdateChecker()
    @Published var mascotState: MascotState = .idle
    @Published var settingsSelection: SettingsSection? = .general
    @Published var lastTranscript: String?
    /// A dictation History should select when it opens, e.g. from a popover row.
    @Published var historyFocus: UUID?
    /// Set by the app scene: opens a window by id and brings gob.lin forward.
    var openWindow: ((String) -> Void)?
    /// Set by the popover while it's open, so the right-click menu can close it first.
    var closePopover: (() -> Void)?
    /// While first run is testing the talk key, dictations made with gob.lin in front go here instead of
    /// being refused as a focus change: gob.lin never types into its own windows.
    var onboardingTake: ((OverlayResult, String) -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var insertionTask: Task<Void, Never>?
    private let processingQueue = DictationProcessingQueue()
    private var dictationSessions: [UUID: DictationSession] = [:]
    private let capture = AudioCaptureService.shared
    private let captureDirectory: URL?
    private let feedback: FeedbackSounds?
    private var activeCapture: ActiveDictation?
    private var liveSessions: [UUID: ActiveDictation] = [:]
    private var captureDrainTask: Task<Void, Never>?
    private var shuttingDown = false
    private var appliedConfiguration: Configuration?
    private var warmTask: Task<Void, Never>?

    init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard, servicesEnabled: Bool = true,
         diagnosticEnvironment: DiagnosticEnvironment? = nil) {
        self.defaults = defaults
        self.servicesEnabled = servicesEnabled
        captureDirectory = dataDirectory?.appendingPathComponent("Captures", isDirectory: true)
        feedback = servicesEnabled ? GoblinBrand.assetDirectory.map { FeedbackSounds(directory: $0) } : nil
        speechModels = SpeechModelService(defaults: defaults)
        diagnostics = DiagnosticsModel(environment: diagnosticEnvironment, logDirectory: dataDirectory?.appendingPathComponent("logs", isDirectory: true))
        history = HistoryModel(directory: dataDirectory, defaults: defaults)
        dictionary = DictionaryModel(repository: dataDirectory.map { DictionaryRepository(url: $0.appendingPathComponent("dictionary.json")) } ?? .applicationDefault)
        permissions = PermissionModel(snapshot: servicesEnabled ? nil : .init(microphone: .notDetermined, accessibility: false, inputMonitoring: false), monitorSystem: servicesEnabled, diagnostics: diagnostics)
        hotkeys = HotkeyService(permissions: permissions, defaults: defaults, monitorSystem: servicesEnabled, diagnostics: diagnostics)
        insertion = TextInsertionService(pasteboard: servicesEnabled ? .general : .withUniqueName(), defaults: defaults, registerShortcuts: servicesEnabled)
        audioPreview = AudioPreviewModel(devices: servicesEnabled ? nil : [InputDevice(id: 0, uid: "preview-input", name: "Preview microphone")], diagnostics: diagnostics)
        // Views observe the child models they show. Forwarding every child change here re-rendered
        // each open window whole, many times a second.
        diagnostics.$activeFailures.sink { [weak self] _ in
            Task { @MainActor in self?.synchronizeMascot() }
        }.store(in: &subscriptions)
        overlay.model.$phase.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.synchronizeMascot() }
        }.store(in: &subscriptions)
        // The poll publishes only changes, but it is also how a microphone coming or going shows in
        // diagnostics and how the warm microphone follows a new default device.
        permissions.onRefresh = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.refreshDiagnostics()
            self.applyWarmMicrophone()
        }
        permissions.$snapshot.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDiagnostics()
                self.applyWarmMicrophone()
            }
        }.store(in: &subscriptions)
        speechModels.$state.sink { [weak self] state in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.refreshDiagnostics()
                self.hotkeys.engineConnected = state == .ready
                if case .failed = state { self.showFailure(.modelLoadFailed) }
                else if state == .ready { self.diagnostics.resolve(.model) }
            }
        }.store(in: &subscriptions)
        hotkeys.$secureInput.sink { [weak self] secure in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.refreshDiagnostics()
                if secure { self.showFailure(.secureInputEnabled) }
            }
        }.store(in: &subscriptions)
        hotkeys.$lastFailure.combineLatest(insertion.$shortcutFailure).sink { [weak self] hotkeyFailure, pasteFailure in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                if let failure = hotkeyFailure ?? pasteFailure { self.showFailure(failure) }
                else { self.diagnostics.resolve(.hotkeys) }
            }
        }.store(in: &subscriptions)
        insertion.$watchEdits.sink { [weak self] watchEdits in
            Task { @MainActor in
                if !watchEdits {
                    self?.pendingEditObservationID = nil
                    self?.editWatcher.cancel()
                }
            }
        }.store(in: &subscriptions)
        insertion.$outcome.sink { [weak self] outcome in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                switch outcome {
                case .failure(let failure): self.showFailure(failure)
                case .success, .unverified, .readyToPaste: self.diagnostics.resolve(.insertion)
                case .idle, .pending: break
                }
            }
        }.store(in: &subscriptions)
        history.$lastFailure.sink { [weak self] failure in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                if let failure { self.showFailure(failure) }
                else if self.history.pending.isEmpty { self.diagnostics.resolve(.history) }
            }
        }.store(in: &subscriptions)
        dictionary.$lastFailure.sink { [weak self] failure in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                if let failure { self.showFailure(failure) }
                else if self.dictionary.available { self.diagnostics.resolve(.dictionary) }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.refreshConfiguration() }
        }.store(in: &subscriptions)
        hotkeys.$recording.sink { [weak self] recording in
            Task { @MainActor in self?.overlay.model.handsFree = recording == .handsFree }
        }.store(in: &subscriptions)
        speechModels.$selectedModel.sink { [weak self] model in
            self?.overlay.model.modelName = model.name
        }.store(in: &subscriptions)
        overlay.model.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .setup: self.permissions.showOnboarding()
            case .audioSettings: self.openSettings(.audio)
            case .cleanupSettings: self.openSettings(.cleanup)
            }
        }
        permissions.onboardingContent = { [weak self] in self.map { AnyView(OnboardingView(model: $0)) } ?? AnyView(EmptyView()) }
        hotkeys.onAction = { [weak self] action in self?.handleHotkey(action) }
        insertion.lastTranscript = { [weak self] in self?.lastTranscript }
        insertion.onPasteRequested = { [weak self] in self?.pasteLastTranscript() }
        history.onRecorded = { [weak self] entry in
            if !entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.lastTranscript = entry.finalText }
            self?.diagnostics.recordTimings(entry.latencies)
        }
        refreshConfiguration()
        refreshDiagnostics()
        updates.canInstall = { [weak self] in self?.canInstallUpdate == true }
        if servicesEnabled { speechModels.preload(); updates.start() }
        Task { [weak self] in
            guard let self else { return }
            await self.history.reload()
            if self.lastTranscript == nil { self.lastTranscript = self.history.entries.first?.finalText }
        }
    }

    var canPasteLastTranscript: Bool { lastTranscript.map { !$0.isEmpty } ?? false }

    func pasteLastTranscript() {
        guard !shuttingDown else { return }
        guard let text = lastTranscript, !text.isEmpty else { showFailure(.noTranscriptAvailable); return }
        guard insertionTask == nil else { showFailure(.insertionNotAcknowledged); return }
        finishEditObservation()
        insertionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let operation = UUID()
            self.diagnostics.developmentLog.record(.insertionStarted, area: .insertion, operation: operation)
            self.finishEditObservation()
            await self.insertion.insert(text)
            var details = DevelopmentDetails()
            if case .failure(let failure) = self.insertion.outcome { details.failure = failure; details.succeeded = false }
            else if case .success = self.insertion.outcome { details.succeeded = true }
            self.diagnostics.developmentLog.record(.insertionFinished, area: .insertion, operation: operation, details: details)
            self.insertionTask = nil
        }
    }

    private func finishEditObservation() {
        // A new action also supersedes an observation still awaiting its History save.
        pendingEditObservationID = nil
        editWatcher.finish()
    }

    /// Every preferences write lands here, window frames included, so it returns early unless a
    /// preference it reads has changed.
    func refreshConfiguration() {
        guard !shuttingDown else { return }
        let configuration = Configuration(defaults)
        guard configuration != appliedConfiguration else { return }
        appliedConfiguration = configuration
        overlay.position = OverlayPosition(rawValue: defaults.string(forKey: "overlayPosition") ?? "") ?? .bottom
        let settings = RewriteSettingsStore.load(defaults: defaults)
        if servicesEnabled {
            do { try rewriteCredentials.prepare(for: settings) }
            catch { showFailure(.rewriteConfiguration) }
        }
        if settings.provider.runsOnDevice, settings.enabled, settings.cleanup != .none { OnDeviceCleanup.prewarm() }
        if settings.enabled && settings.cleanup != .none {
            history.rewriteAction = { [weak self] entry, _ in
                guard let self, !self.shuttingDown else { throw CancellationError() }
                let result = await self.processTranscript(entry.rawText)
                return HistoryReprocessResult(rawText: result.rawText, finalText: result.finalText,
                    tone: result.tone.rawValue, polished: result.polished, model: entry.model,
                    latencies: result.timings, warning: result.warning?.message)
            }
        } else { history.rewriteAction = nil }
        history.retranscribeAction = servicesEnabled ? { [weak self] entry, audioURL in
            guard let self, !self.shuttingDown, let audioURL else { throw RecordedAudioError.invalidFile }
            let lease = try self.speechModels.beginSession()
            defer { self.speechModels.endSession(lease) }
            let engine = try await self.speechModels.readyEngine(for: lease)
            let run = try await RecordedAudioPipeline(engine: engine, options: lease.options).transcribe(audioURL)
            try Task.checkCancellation()
            let result = await self.processTranscript(run.rawText)
            try Task.checkCancellation()
            var timings = run.timings
            timings.rewriteMilliseconds = result.timings.rewriteMilliseconds
            return HistoryReprocessResult(rawText: run.rawText, finalText: result.finalText,
                tone: result.tone.rawValue, polished: result.polished, model: engine.identifier,
                latencies: timings, warning: result.warning?.message)
        } : nil
        applyWarmMicrophone()
        objectWillChange.send()
    }

    func reloadRewriteCredentials() {
        rewriteCredentials.reset()
        appliedConfiguration = nil
        refreshConfiguration()
    }

    /// The preferences refreshConfiguration reads.
    private struct Configuration: Equatable {
        var overlayPosition: String?
        var rewriteSettings: Data?
        var rewriteKeys: [String: String]?
        var keepMicrophoneWarm: Bool
        var inputDeviceUID: String?

        init(_ defaults: UserDefaults) {
            overlayPosition = defaults.string(forKey: "overlayPosition")
            rewriteSettings = defaults.data(forKey: RewriteSettingsStore.preferenceKey)
            rewriteKeys = defaults.dictionary(forKey: RewriteKeyStore.preferenceKey) as? [String: String]
            keepMicrophoneWarm = defaults.bool(forKey: "audio.keepMicrophoneWarm")
            inputDeviceUID = defaults.string(forKey: "audio.inputDeviceUID")
        }
    }

    func processTranscript(_ raw: String) async -> TranscriptProcessingResult {
        let operation = UUID()
        diagnostics.developmentLog.record(.processingStarted, area: .application, operation: operation)
        var completed = DevelopmentDetails()
        defer { diagnostics.developmentLog.record(.processingFinished, area: .application, severity: completed.failure == nil ? .info : .warning, operation: operation, details: completed) }
        let settings = RewriteSettingsStore.load(defaults: defaults)
        let tone = DictationTone(rawValue: defaults.string(forKey: DictationTone.preferenceKey) ?? "") ?? .formal
        guard dictionary.available else {
            completed.failure = .dictionaryUnavailable
            showFailure(.dictionaryUnavailable)
            return TranscriptProcessingResult(rawText: raw, finalText: raw, tone: tone, polished: false, warning: .dictionaryUnavailable)
        }
        var key = ""
        if settings.enabled, settings.cleanup != .none, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard servicesEnabled else {
                completed.failure = .rewriteConfiguration
                showFailure(.rewriteConfiguration)
                return TranscriptProcessingResult(rawText: raw, finalText: raw, tone: tone, polished: false, warning: .rewriteConfiguration)
            }
            do { key = try rewriteCredentials.key(for: settings) }
            catch {
                let failure = DiagnosticFailure.rewriteConfiguration
                completed.failure = failure
                showFailure(failure)
                return TranscriptProcessingResult(rawText: raw, finalText: raw, tone: tone, polished: false, warning: failure)
            }
        }
        let rewriting = settings.enabled && settings.cleanup != .none && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if rewriting { diagnostics.developmentLog.record(.rewriteStarted, area: .rewrite, operation: operation) }
        let result = await processor.process(raw, dictionaryEntries: dictionary.entries, tone: tone, rewriteSettings: settings, apiKey: key)
        completed.failure = result.warning
        completed.timings = result.timings
        completed.succeeded = result.warning == nil
        if rewriting { diagnostics.developmentLog.record(.rewriteFinished, area: .rewrite, severity: result.warning == nil ? .info : .warning, operation: operation, details: completed) }
        if let warning = result.warning { showFailure(warning) }
        else { diagnostics.resolve(.rewrite) }
        return result
    }

    func handleHotkey(_ action: HotkeyStateMachine.Action) {
        guard !shuttingDown else { return }
        switch action {
        case .beginRecording:
            diagnostics.developmentLog.record(.hotkeyBegin, area: .hotkeys, operation: UUID())
            let failure: DiagnosticFailure?
            if permissions.snapshot.microphone != .authorized { failure = .microphonePermissionMissing }
            else if !permissions.snapshot.accessibility { failure = .requiredPermissionsMissing }
            else if permissions.tapFailure != nil { failure = .hotkeyUnavailable }
            else if hotkeys.secureInput { failure = .secureInputEnabled }
            else if !servicesEnabled { failure = .modelUnavailable }
            else { failure = nil }
            if let failure { hotkeys.cancelRecording(); showFailure(failure) }
            else { beginDictation() }
        case .finishRecording:
            diagnostics.developmentLog.record(.hotkeyFinish, area: .hotkeys)
            if let active = activeCapture { finishDictation(active, counted: true) }
            else { hotkeys.processingCompleted() }
        case .cancelRecording:
            diagnostics.developmentLog.record(.hotkeyCancel, area: .hotkeys)
            if let active = activeCapture {
                if hotkeys.isSuspending { suspendDictation(active) }
                else { cancelDictation(active) }
            }
        }
    }

    /// Recording right now: the menu-bar icon's right-click menu offers to cancel.
    var isRecording: Bool { activeCapture != nil }

    /// The same as the overlay's close button.
    func cancelRecording() { if let activeCapture { cancelDictation(activeCapture) } }

    private func beginDictation() {
        guard activeCapture == nil else { return }
        finishEditObservation()
        let session = DictationSession(destination: insertion.destination)
        let lease: SpeechModelLease
        do { lease = try speechModels.beginSession() }
        catch { hotkeys.cancelRecording(); showFailure(.modelUnavailable); return }
        let readiness = Task<any PCMSpeechEngine, Error> { [speechModels] in
            try await speechModels.readyEngine(for: lease)
        }
        let active = ActiveDictation(session: session, lease: lease, readiness: readiness)
        dictationSessions[session.id] = session
        liveSessions[session.id] = active
        activeCapture = active
        session.overlayID = overlay.begin { [weak self, weak active] in
            guard let active else { return }
            self?.cancelDictation(active)
        }
        active.textTask = Task { @MainActor [weak self] in
            var previousRecovery: LiveRecoveryReason?
            for await text in active.live.updates {
                guard let self, !session.cancelled, !active.stopping, let overlayID = session.overlayID else { continue }
                if text.recoveryReason != previousRecovery {
                    var details = DevelopmentDetails()
                    switch text.recoveryReason {
                    case .windowLimit: details.reason = .liveWindowLimit
                    case .decodeFailed: details.reason = .liveDecodeFailed
                    case .decodeUnavailable, .modelPreviewUnavailable: details.reason = .liveDecodeUnavailable
                    case .overlapMismatch: details.reason = .liveOverlapMismatch
                    case .timingUnavailable: details.reason = .liveTimingUnavailable
                    case .inputDiscontinuity: details.reason = .liveInputDiscontinuity
                    case .invalidSamples: details.reason = .liveInvalidSamples
                    case nil: break
                    }
                    self.diagnostics.developmentLog.record(text.recoveryReason == nil ? .livePreviewRecovered : .livePreviewDegraded,
                        area: .application, severity: text.recoveryReason == nil || text.recoveryReason == .modelPreviewUnavailable ? .info : .warning,
                        operation: session.id, details: details)
                    previousRecovery = text.recoveryReason
                }
                self.overlay.update(.listening,
                    committed: text.committedText, tentative: text.tentativeText,
                    previewUnavailable: text.recoveryReason == .decodeUnavailable || text.recoveryReason == .modelPreviewUnavailable, session: overlayID)
            }
        }
        let previousDrain = captureDrainTask
        active.startTask = Task { @MainActor [weak self] in
            await previousDrain?.value
            guard let self, !session.cancelled, !Task.isCancelled else { active.finishEvents(); return }
            do {
                if self.defaults.object(forKey: "feedbackSoundsEnabled") as? Bool ?? true {
                    active.sounds = self.feedback
                    active.sounds?.begin(sessionID: session.id)
                    if active.stopping { active.sounds?.cancelStart(sessionID: session.id) }
                }
                let frames = active.frames, live = active.live
                active.frameTask = Task.detached {
                    for await frame in frames { await live.append(frame.samples, at: frame.samplePosition) }
                }
                active.levelTask = Task { @MainActor [weak self] in
                    for await rms in active.levels {
                        guard !session.cancelled, !active.stopping, let overlayID = session.overlayID else { continue }
                        self?.overlay.update(.listening, level: AudioInputDevices.displayLevel(rms: rms), session: overlayID)
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                    }
                }
                active.captureID = try await self.capture.start(uid: self.defaults.string(forKey: "audio.inputDeviceUID") ?? "",
                    directory: self.captureDirectory, feedback: self.feedback, feedbackSessionID: session.id, onEvent: active.onEvent)
                active.eventTask = Task { @MainActor [weak self] in
                    for await event in active.events { await self?.consume(event, for: active) }
                }
            } catch {
                active.sounds?.end(sessionID: session.id, playStop: false)
                await active.audioReduction?.finish()
                active.failure = error as? AudioCaptureFailure ?? AudioCaptureFailure(.startFailed)
                active.finishEvents()
                if !active.stopping && !session.cancelled { self.suspendDictation(active) }
            }
        }
    }

    private func consume(_ event: AudioCaptureEvent, for active: ActiveDictation) async {
        let session = active.session
        guard !session.cancelled else { return }
        switch event {
        case .ready(let id, _):
            guard id == active.captureID, !active.stopping, let overlayID = session.overlayID else { return }
            if active.audioReduction == nil {
                active.audioReduction = AudioReductionSession(
                    pauseMedia: defaults.bool(forKey: "audio.pauseMediaWhileDictating"),
                    muteAudio: defaults.bool(forKey: "audio.muteWhileDictating"))
            }
            diagnostics.resolve(.microphone)
            diagnostics.developmentLog.record(.firstBuffer, area: .microphone, operation: session.id)
            overlay.update(.listening, session: overlayID)
        case .silence(let id, let cause):
            guard id == active.captureID, !active.stopping, let overlayID = session.overlayID else { return }
            overlay.setMicrophoneNotice(cause?.message, session: overlayID)
        case .frame, .level: break
        case .failed(let id, let failure):
            guard id == active.captureID else { return }
            active.failure = failure
            if !active.stopping { suspendDictation(active) }
        case .finished(let audio):
            if audio.sessionID == active.captureID { active.audio = audio }
        case .cancelled: break
        }
    }

    private func suspendDictation(_ active: ActiveDictation) {
        guard !shuttingDown else { return }
        active.session.historyOnly = true
        finishDictation(active, counted: false)
    }

    private func finishDictation(_ active: ActiveDictation, counted: Bool) {
        guard !active.stopping else { return }
        active.stopping = true
        active.sounds?.cancelStart(sessionID: active.session.id)
        active.countedForProcessing = counted
        if activeCapture === active {
            activeCapture = nil
            if !counted { hotkeys.cancelRecording() }
        }
        if let overlayID = active.session.overlayID { overlay.update(.transcribing, session: overlayID) }
        active.stopTask = Task { @MainActor [weak self] in
            await active.live.stopPreview()
            await active.startTask?.value
            guard let self else { throw CancellationError() }
            defer {
                active.captureMilliseconds = Self.milliseconds(since: active.session.captureStarted)
                active.finishEvents()
            }
            try active.session.checkCancellation()
            guard let captureID = active.captureID else { throw active.failure ?? AudioCaptureFailure(.startFailed) }
            let audio: CapturedAudio
            do { audio = try await self.capture.stop(sessionID: captureID) }
            catch {
                active.sounds?.end(sessionID: active.session.id, playStop: false)
                await active.audioReduction?.finish()
                throw error
            }
            await active.audioReduction?.finish()
            active.sounds?.end(sessionID: active.session.id, playStop: !active.session.cancelled)
            active.audio = audio
            await active.frameTask?.value
            await active.eventTask?.value
            self.applyWarmMicrophone()
            return audio
        }
        let stop = active.stopTask
        captureDrainTask = Task { _ = try? await stop?.value }
        enqueueDictation(active)
    }

    private func enqueueDictation(_ active: ActiveDictation) {
        guard !active.enqueued else { return }
        active.enqueued = true
        processingQueue.enqueue(active.session, operation: { [weak self] in
            guard let self else { return }
            do {
                guard let stop = active.stopTask else { throw CancellationError() }
                let audio = try await stop.value
                await active.frameTask?.value
                try active.session.checkCancellation()
                let result = try await active.live.finish()
                await active.textTask?.value
                try active.session.checkCancellation()
                var timings = DictationTimings(captureMilliseconds: active.captureMilliseconds,
                                               asrMilliseconds: await active.live.computeMilliseconds)
                let raw: String
                if let result {
                    raw = result.text
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.speechPresence == .notDetected {
                        self.diagnostics.developmentLog.record(.speechNotDetected, area: .application, operation: active.session.id)
                    }
                }
                else {
                    self.diagnostics.developmentLog.record(.liveFinalRecovery, area: .application, operation: active.session.id)
                    let engine = try await active.readiness.value
                    try active.session.checkCancellation()
                    let run = try await RecordedAudioPipeline(engine: engine, options: active.lease.options).transcribe(audio.fileURL)
                    raw = run.rawText
                    timings.asrMilliseconds += run.timings.asrMilliseconds
                }
                try await self.completeDictation(raw, model: active.lease.modelID, audioURL: audio.fileURL,
                    duration: audio.duration, timings: timings, session: active.session)
            } catch is CancellationError {
            } catch {
                await active.frameTask?.value
                guard !active.session.cancelled else { return }
                await self.recordFailedDictation(active, failure: active.failure == nil ? .transcriptionFailed : Self.diagnostic(active.failure!))
            }
        }, completed: { [weak self] in
            guard let self else { return }
            await active.cancelTask?.value
            await active.startTask?.value
            _ = try? await active.stopTask?.value
            active.finishEvents()
            await active.frameTask?.value
            await active.eventTask?.value
            await active.levelTask?.value
            await active.live.cancel()
            await active.textTask?.value
            _ = try? await active.readiness.value
            if active.session.cancelled, !active.session.audioOwnedByHistory, let audio = active.audio {
                try? FileManager.default.removeItem(at: audio.fileURL)
            }
            self.speechModels.endSession(active.lease)
            self.liveSessions[active.session.id] = nil
            self.dictationSessions[active.session.id] = nil
            if active.countedForProcessing { self.hotkeys.processingCompleted() }
            self.applyWarmMicrophone()
        })
    }

    private func cancelDictation(_ active: ActiveDictation) {
        guard !active.session.cancelled else { return }
        processingQueue.cancel(active.session)
        active.startTask?.cancel()
        active.sounds?.end(sessionID: active.session.id, playStop: false)
        active.readiness.cancel()
        if let overlayID = active.session.overlayID { overlay.hide(session: overlayID) }
        if activeCapture === active { activeCapture = nil; hotkeys.cancelRecording() }
        active.cancelTask = Task { @MainActor [weak self] in
            await active.startTask?.value
            if let self, let captureID = active.captureID, await self.capture.activeSessionID == captureID {
                do { try await self.capture.cancel(sessionID: captureID) }
                catch { self.diagnostics.report(.microphoneCaptureFailed, operation: active.session.id) }
            }
            await active.audioReduction?.finish()
            active.finishEvents()
            await active.frameTask?.value
            await active.eventTask?.value
        }
        let cancellation = active.cancelTask
        captureDrainTask = Task { await cancellation?.value }
        enqueueDictation(active)
    }

    private func recordFailedDictation(_ active: ActiveDictation, failure: DiagnosticFailure) async {
        diagnostics.report(failure, operation: active.session.id)
        if let overlayID = active.session.overlayID {
            overlay.update(.error(OverlayNotice(failure)), session: overlayID)
            overlay.hide(after: 4, session: overlayID)
        }
        guard let url = active.audio?.fileURL ?? active.failure?.recoveryURL,
              FileManager.default.isReadableFile(atPath: url.path) else { return }
        let session = active.session
        let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let entry = HistoryEntry(id: session.id, rawText: "", finalText: "", targetBundleIdentifier: session.target?.bundleIdentifier,
            targetApplicationName: session.target?.localizedName, createdAt: session.createdAt,
            audioDuration: active.audio?.duration ?? duration, model: active.lease.modelID,
            latencies: DictationTimings(captureMilliseconds: active.captureMilliseconds,
                                       asrMilliseconds: await active.live.computeMilliseconds),
            processingWarning: failure.message)
        let saved = await history.record(entry, untrimmedAudioURL: url, ownsAudioSource: true)
        session.audioOwnedByHistory = true
        if saved { try? FileManager.default.removeItem(at: url) }
    }

    /// Applied in order on the capture thread: opening a device can block.
    private func applyWarmMicrophone() {
        guard servicesEnabled, !shuttingDown, activeCapture == nil else { return }
        let enabled = permissions.snapshot.microphone == .authorized && defaults.bool(forKey: "audio.keepMicrophoneWarm")
        let uid = defaults.string(forKey: "audio.inputDeviceUID") ?? ""
        warmTask = Task { [previous = warmTask, capture, weak self] in
            await previous?.value
            do { try await capture.setWarmMicrophone(enabled: enabled, uid: uid) }
            // A dictation took the microphone first; it reapplies this when it finishes.
            catch let failure as AudioCaptureFailure where failure.kind == .alreadyRecording {}
            catch { self?.diagnostics.report(Self.diagnostic(error as? AudioCaptureFailure ?? AudioCaptureFailure(.startFailed))) }
        }
    }

    private static func diagnostic(_ failure: AudioCaptureFailure) -> DiagnosticFailure {
        switch failure.kind {
        case .permissionMissing: .microphonePermissionMissing
        case .deviceUnavailable: .microphoneUnavailable
        case .allZeroStream: .microphoneMuted
        default: .microphoneCaptureFailed
        }
    }

    func showFailure(_ failure: DiagnosticFailure) {
        guard !shuttingDown else { return }
        diagnostics.report(failure)
        mascotState = .warning
        // A background operation must not replace the current dictation's text.
        guard dictationSessions.isEmpty else { return }
        let session = overlay.begin { [weak self] in self?.overlay.hide() }
        overlay.update(.error(OverlayNotice(failure)), session: session)
        overlay.hide(after: 4, session: session)
    }

    var canInstallUpdate: Bool {
        !shuttingDown && dictationSessions.isEmpty && activeCapture == nil &&
        insertionTask == nil && !insertion.busy && history.pending.isEmpty && !insertion.hasRecoveryClipboard
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        updates.stop()
        diagnostics.developmentLog.record(.shutdownRequested, area: .application)
        hotkeys.shutdown()
        permissions.stop()
        insertionTask?.cancel()
        await insertionTask?.value
        insertionTask = nil
        for active in Array(liveSessions.values) { cancelDictation(active) }
        let modelShutdown = Task { [speechModels] in await speechModels.shutdown() }
        await processingQueue.shutdown()
        await captureDrainTask?.value
        if servicesEnabled { await capture.shutdown() }
        dictationSessions.removeAll()
        await modelShutdown.value
        editWatcher.cancel()
        insertion.shutdown()
        history.stopAudio()
        audioPreview.stop(reason: .shutdown)
        overlay.shutdown()
        subscriptions.removeAll()
        rewriteCredentials.reset()
        diagnostics.developmentLog.record(.appStopped, area: .application)
    }

    private func completeDictation(_ raw: String, model: String, audioURL: URL,
                                  duration: Double, timings: DictationTimings,
                                  session: DictationSession) async throws {
        try session.checkCancellation()
        let cleanup = RewriteSettingsStore.load(defaults: defaults)
        if let overlayID = session.overlayID, cleanup.enabled, cleanup.cleanup != .none,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlay.model.cleanupLabel = "\(cleanup.cleanup.title) · \(cleanup.provider.title)"
            overlay.update(.polishing, committed: raw, tentative: "", session: overlayID)
        }
        let result = await processTranscript(raw)
        try await finishDictation(result, model: model, audioURL: audioURL, duration: duration, timings: timings, session: session)
    }

    /// Shared completion path, including successful cleanup that leaves nothing to insert.
    func finishDictation(_ result: TranscriptProcessingResult, model: String, audioURL: URL,
                         duration: Double, timings: DictationTimings, session: DictationSession) async throws {
        try session.checkCancellation()
        var timings = timings
        timings.rewriteMilliseconds = result.timings.rewriteMilliseconds
        var warning = result.warning?.message
        var warningFailure = result.warning
        let text = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        var insertionAttempted = false
        var insertionAnchor: InsertionAnchor?
        var chipShown = false
        var delivered = false
        var deliverySeconds = 0.0
        var readyToPaste = false
        var deliveryApplication = session.destination == .originalField ? session.target : nil
        if !text.isEmpty {
            lastTranscript = result.finalText
            if let overlayID = session.overlayID {
                overlay.update(.transcribing, committed: result.finalText, tentative: "", session: overlayID)
            }
            if !session.historyOnly, session.target == nil, let deliver = onboardingTake {
                let seconds = (Self.milliseconds(since: session.captureStarted) - timings.captureMilliseconds) / 1000
                let take = OverlayResult(application: "gob.lin", words: result.finalText.split(whereSeparator: \.isWhitespace).count,
                                         seconds: seconds.isFinite ? max(0, seconds) : 0)
                deliver(take, result.finalText)
                if let overlayID = session.overlayID { overlay.update(.inserted(take), session: overlayID) }
            } else if !session.historyOnly {
                let insertionStart = ContinuousClock.now
                if !insertion.busy && insertionTask == nil {
                    insertionAttempted = true
                    diagnostics.developmentLog.record(.insertionStarted, area: .insertion, operation: session.id)
                    let insertionTarget: FocusedText?
                    if session.destination == .currentField {
                        let focused = FocusedText.capture(timeout: 0.05)
                        deliveryApplication = focused.flatMap { $0.pid == getpid() ? nil : NSRunningApplication(processIdentifier: $0.pid) }
                        insertionTarget = deliveryApplication == nil ? nil : focused
                    } else {
                        insertionTarget = session.target?.isTerminated == false ? session.originalText : nil
                    }
                    let showChip = { [weak self] in
                        guard !chipShown, result.warning == nil, let self, let overlayID = session.overlayID else { return }
                        chipShown = true
                        // Key-up is when capture ended; the chip reports key-up to text.
                        let seconds = (Self.milliseconds(since: session.captureStarted) - timings.captureMilliseconds) / 1000
                        self.overlay.update(.inserted(OverlayResult(application: deliveryApplication?.localizedName,
                            words: result.finalText.split(whereSeparator: \.isWhitespace).count,
                            seconds: seconds.isFinite ? max(0, seconds) : 0)), session: overlayID)
                        self.overlay.hide(after: 0.6, session: overlayID)
                    }
                    // Pastes report as soon as they're sent; direct Accessibility writes once verified.
                    finishEditObservation()
                    pendingEditObservationID = session.id
                    await insertion.insert(result.finalText, into: insertionTarget, onPasteSent: showChip)
                    insertionAnchor = insertion.takeLastAnchor()
                    var details = DevelopmentDetails()
                    if case .failure(let failure) = insertion.outcome {
                        details.failure = failure
                        details.succeeded = false
                        if warning == nil { warning = failure.message; warningFailure = failure }
                    } else if case .success = insertion.outcome {
                        delivered = true
                        details.succeeded = true
                        deliverySeconds = (Self.milliseconds(since: session.captureStarted) - timings.captureMilliseconds) / 1000
                    }
                    else if case .readyToPaste = insertion.outcome {
                        readyToPaste = true
                        details.succeeded = false
                        warning = insertion.status
                        warningFailure = nil
                    }
                    else if case .unverified = insertion.outcome { warning = warning ?? insertion.status }
                    diagnostics.developmentLog.record(.insertionFinished, area: .insertion, operation: session.id, details: details)
                } else {
                    let failure: DiagnosticFailure = .insertionNotAcknowledged
                    diagnostics.report(failure, operation: session.id)
                    if warning == nil { warning = failure.message; warningFailure = failure }
                }
                timings.insertionMilliseconds = Self.milliseconds(since: insertionStart)
            }
        } else if !result.intentionallyEmpty, warning == nil {
            warning = DiagnosticFailure.noTranscriptAvailable.message
            warningFailure = .noTranscriptAvailable
        }
        // Once insertion starts, retain its text/audio even if cancellation interrupts acknowledgement.
        if !insertionAttempted { try session.checkCancellation() }
        let entry = HistoryEntry(id: session.id, rawText: result.rawText, finalText: result.finalText,
            tone: result.tone.rawValue, polished: result.polished,
            targetBundleIdentifier: deliveryApplication?.bundleIdentifier,
            targetApplicationName: deliveryApplication?.localizedName, createdAt: session.createdAt,
            completedAt: Date(), audioDuration: duration, model: model, latencies: timings,
            processingWarning: warning)
        let saved = await history.record(entry, untrimmedAudioURL: audioURL, ownsAudioSource: true)
        if saved, pendingEditObservationID == session.id, insertion.watchEdits, !shuttingDown,
           let anchor = insertionAnchor {
            editWatcher.start(entryID: entry.id, anchor: anchor) { [weak self] result in
                Task { @MainActor in await self?.history.applyEditObservation(result) }
            }
        }
        if pendingEditObservationID == session.id { pendingEditObservationID = nil }
        session.audioOwnedByHistory = true
        if saved { try? FileManager.default.removeItem(at: audioURL) }
        if let overlayID = session.overlayID, !session.cancelled, !Task.isCancelled {
            if readyToPaste {
                overlay.showCompletion(.readyToPaste(application: deliveryApplication?.localizedName), session: overlayID)
            } else if delivered {
                let notice = warning.map { OverlayNotice(message: $0, failure: warningFailure) }
                if !chipShown || warning != nil {
                    overlay.showCompletion(.inserted(OverlayResult(application: deliveryApplication?.localizedName,
                        words: entry.wordCount, seconds: deliverySeconds.isFinite ? max(0, deliverySeconds) : 0, notice: notice)), session: overlayID)
                }
                if saved, warning == nil { await celebrateMilestone(adding: entry.wordCount, overlay: overlayID) }
            } else if let warning {
                overlay.update(.error(OverlayNotice(message: warning, failure: warningFailure)), session: overlayID)
                overlay.hide(after: 4, session: overlayID)
            } else {
                overlay.hide(after: 0.8, session: overlayID)
                if saved, insertionAttempted { await celebrateMilestone(adding: entry.wordCount, overlay: overlayID) }
            }
        }
    }

    /// One celebration per threshold, replacing the inserted chip. Thresholds passed before this
    /// feature existed are recorded quietly instead of celebrated late.
    private func celebrateMilestone(adding words: Int, overlay overlayID: UUID) async {
        guard defaults.object(forKey: "overlay.milestones") as? Bool ?? true else { return }
        let thresholds = [1_000, 10_000, 100_000, 1_000_000]
        let total: Int
        if defaults.object(forKey: "milestones.words") == nil {
            total = (try? await history.store?.insights().totalWords) ?? words
            defaults.set(thresholds.last { $0 <= total } ?? 0, forKey: "milestones.celebrated")
            defaults.set(total, forKey: "milestones.words")
            return
        }
        total = defaults.integer(forKey: "milestones.words") + words
        defaults.set(total, forKey: "milestones.words")
        guard let threshold = thresholds.last(where: { $0 <= total }), threshold > defaults.integer(forKey: "milestones.celebrated") else { return }
        defaults.set(threshold, forKey: "milestones.celebrated")
        overlay.update(.milestone(words: threshold), session: overlayID)
        overlay.hide(after: 2.5, session: overlayID)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    /// Microphones are listed off the main thread, then everything else is read fresh on return.
    private func refreshDiagnostics() {
        guard !shuttingDown, servicesEnabled else { return applyDiagnostics(microphones: nil) }
        Task { [weak self] in
            let microphones = await Task.detached(priority: .utility) { DiagnosticsModel.discoverMicrophones() }.value
            self?.applyDiagnostics(microphones: microphones)
        }
    }

    private func applyDiagnostics(microphones: DiagnosticsModel.Microphones?) {
        guard !shuttingDown else { return }
        let engineStatus: DiagnosticEngineStatus
        switch speechModels.state {
        case .ready: engineStatus = .ready
        case .preparing, .unloading, .cancelling: engineStatus = .loading
        default: engineStatus = .unavailable
        }
        diagnostics.refresh(permissions: permissions.snapshot, secureInput: hotkeys.secureInput, engineStatus: engineStatus, microphones: microphones)
    }

    private func synchronizeMascot() {
        let state: MascotState
        if diagnostics.hasWarning { state = .warning }
        else {
            switch overlay.model.phase {
            case .arming, .listening: state = .recording
            case .transcribing, .polishing: state = .transcribing
            case .error, .readyToPaste: state = .warning
            case .hidden, .inserted, .milestone: state = .idle
            }
        }
        if mascotState != state { mascotState = state }
    }
}
