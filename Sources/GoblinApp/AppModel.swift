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
    private let projectDetector = ProjectDetector()
    let diagnostics: DiagnosticsModel
    let dictionary: DictionaryModel
    let history: HistoryModel
    let permissions: PermissionModel
    let hotkeys: HotkeyService
    let insertion: TextInsertionService
    private let editWatcher = PostPasteWatcher()
    private var pendingEditObservationID: UUID?
    let audioPreview: AudioPreviewModel
    let microphones: MicrophonesModel
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
    /// Counts insertions, so a take can tell whether an earlier one pasted after it read its field.
    private var insertions = 0
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
    /// The microphone the last take opened, kept across launches so the next take can say when it changes.
    private var lastMicrophoneUID: String? {
        get { defaults.string(forKey: "audio.lastMicrophoneUID") }
        set { defaults.set(newValue, forKey: "audio.lastMicrophoneUID") }
    }

    init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard, servicesEnabled: Bool = true,
         diagnosticEnvironment: DiagnosticEnvironment? = nil) {
        self.defaults = defaults
        self.servicesEnabled = servicesEnabled
        captureDirectory = dataDirectory?.appendingPathComponent("Captures", isDirectory: true)
        feedback = servicesEnabled ? GoblinBrand.assetDirectory.map { FeedbackSounds(directory: $0) } : nil
        speechModels = SpeechModelService(defaults: defaults)
        diagnostics = DiagnosticsModel(environment: diagnosticEnvironment, logDirectory: dataDirectory?.appendingPathComponent("logs", isDirectory: true))
        history = HistoryModel(directory: dataDirectory, defaults: defaults)
        dictionary = DictionaryModel(repository: dataDirectory.map { DictionaryRepository(url: $0.appendingPathComponent("dictionary.json")) } ?? .applicationDefault,
                                     defaults: defaults)
        permissions = PermissionModel(snapshot: servicesEnabled ? nil : .init(microphone: .notDetermined, accessibility: false, inputMonitoring: false), monitorSystem: servicesEnabled, diagnostics: diagnostics)
        hotkeys = HotkeyService(permissions: permissions, defaults: defaults, monitorSystem: servicesEnabled, diagnostics: diagnostics)
        insertion = TextInsertionService(pasteboard: servicesEnabled ? .general : .withUniqueName(), defaults: defaults, registerShortcuts: servicesEnabled)
        audioPreview = AudioPreviewModel(monitorSystem: servicesEnabled, diagnostics: diagnostics)
        microphones = servicesEnabled ? MicrophonesModel(defaults: defaults, diagnostics: diagnostics)
            : MicrophonesModel(devices: [InputDevice(id: 0, uid: "preview-input", name: "MacBook Pro Microphone", kind: .builtIn),
                                         InputDevice(id: 1, uid: "preview-webcam", name: "Desk Webcam", kind: .usb)],
                               defaultUID: "preview-webcam", defaults: defaults)
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
            self.microphones.checkLid()
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
                // A keyed talk key still works while another app has Secure Input on; only refused takes say so.
                if secure, !self.hotkeys.shortcut.worksUnderSecureInput { self.showFailure(.secureInputEnabled) }
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
        hotkeys.$shortcut.sink { [weak self] shortcut in
            self?.overlay.model.talkKey = shortcut
        }.store(in: &subscriptions)
        speechModels.$selectedModel.sink { [weak self] model in
            self?.overlay.model.modelName = model.name
        }.store(in: &subscriptions)
        if servicesEnabled {
            microphones.onNewMicrophone = { [weak self] device in
                self?.overlay.showCompletion(.newMicrophone(name: device.name, uid: device.uid), session: UUID())
            }
            // A microphone arriving, leaving or becoming the default moves the warm one at once, not at the next poll.
            microphones.$devices.combineLatest(microphones.$defaultUID).dropFirst().sink { [weak self] _ in
                Task { @MainActor in self?.applyWarmMicrophone() }
            }.store(in: &subscriptions)
        }
        overlay.model.applicationName = { DictionaryApps.name($0) }
        dictionary.loadProjectUses = { [history] in (try? await history.store?.dictionaryProjectUses()) ?? [] }
        overlay.model.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .setup: self.permissions.showOnboarding()
            case .audioSettings: self.openSettings(.audio)
            case .cleanupSettings: self.openSettings(.cleanup)
            case .useMicrophone(let uid):
                self.microphones.pick(uid)
                self.overlay.hide()
            case .dismiss: self.overlay.hide()
            case .addTerm(let suggestion):
                self.dictionary.accept(suggestion)
                self.overlay.confirmAdded(suggestion)
            case .dismissTerm(let suggestion):
                self.dictionary.dismiss(suggestion)
                self.overlay.hide()
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
                let result = await self.processTranscript(entry.rawText, scope: entry.dictionaryContext)
                return HistoryReprocessResult(rawText: result.rawText, finalText: result.finalText,
                    tone: result.tone.rawValue, polished: result.polished, model: entry.model,
                    latencies: result.timings, warning: result.warning?.message)
            }
        } else { history.rewriteAction = nil }
        history.retranscribeAction = servicesEnabled ? { [weak self] entry, audioURL in
            guard let self, !self.shuttingDown, let audioURL else { throw RecordedAudioError.invalidFile }
            let lease = try self.speechModels.beginSession(
                vocabulary: self.dictionary.entries.vocabulary(in: entry.dictionaryContext))
            defer { self.speechModels.endSession(lease) }
            let engine = try await self.speechModels.readyEngine(for: lease)
            let run = try await RecordedAudioPipeline(engine: engine, options: lease.options).transcribe(audioURL)
            try Task.checkCancellation()
            let result = await self.processTranscript(run.rawText, scope: entry.dictionaryContext)
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
        var microphoneRanking: Data?

        init(_ defaults: UserDefaults) {
            overlayPosition = defaults.string(forKey: "overlayPosition")
            rewriteSettings = defaults.data(forKey: RewriteSettingsStore.preferenceKey)
            rewriteKeys = defaults.dictionary(forKey: RewriteKeyStore.preferenceKey) as? [String: String]
            keepMicrophoneWarm = defaults.bool(forKey: "audio.keepMicrophoneWarm")
            microphoneRanking = defaults.data(forKey: MicrophoneRanking.preferenceKey)
        }
    }

    /// `scope` is the app and project dictated into; it selects their dictionary terms. `context` is where the text lands.
    /// `reportsOutcome: false` leaves a provider failure unshown, for a draft cleanup that may be discarded.
    func processTranscript(_ raw: String, scope: DictionaryScope, context: DictationContext? = nil,
                           reportsOutcome: Bool = true) async -> TranscriptProcessingResult {
        let operation = UUID()
        diagnostics.developmentLog.record(.processingStarted, area: .application, operation: operation)
        var completed = DevelopmentDetails()
        defer { diagnostics.developmentLog.record(.processingFinished, area: .application, severity: completed.failure == nil ? .info : .warning, operation: operation, details: completed) }
        let inputs = processingInputs
        let settings = inputs.settings, tone = inputs.tone
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
        let result = await processor.process(raw, dictionaryEntries: inputs.entries.active(in: scope), tone: tone,
                                             rewriteSettings: settings, apiKey: key, context: context)
        // A draft's cleanup cancelled for the final transcript is not a provider failure.
        let cancelled = Task.isCancelled
        completed.failure = cancelled ? nil : result.warning
        completed.timings = result.timings
        completed.succeeded = cancelled ? nil : result.warning == nil
        if rewriting {
            diagnostics.developmentLog.record(cancelled ? .rewriteCancelled : .rewriteFinished, area: .rewrite,
                                              severity: cancelled || result.warning == nil ? .info : .warning, operation: operation, details: completed)
        }
        if reportsOutcome { reportProcessingOutcome(result) }
        return result
    }

    /// What processing reads besides the transcript and where it lands. A draft's cleanup stands only while these are
    /// unchanged, so changing Cleanup, the tone or the dictionary mid-take never pastes a result made with the old ones.
    private var processingInputs: ProcessingInputs {
        ProcessingInputs(settings: RewriteSettingsStore.load(defaults: defaults),
                         tone: DictationTone(rawValue: defaults.string(forKey: DictationTone.preferenceKey) ?? "") ?? .formal,
                         entries: dictionary.entries)
    }

    private func reportProcessingOutcome(_ result: TranscriptProcessingResult) {
        if let warning = result.warning { showFailure(warning) }
        else { diagnostics.resolve(.rewrite) }
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
            else if hotkeys.secureInput, secureTarget() { failure = .secureInputEnabled }
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

    /// Whether the app or field a take would type into is guarded by Secure Input. Another app's password field isn't.
    private func secureTarget() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return true }
        return SecureInput.guards(pid) || FocusedText.capture(timeout: 0.1)?.secure == true
    }

    private func beginDictation() {
        guard activeCapture == nil else { return }
        finishEditObservation()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let quirks = frontmost.map { AppInsertionQuirks.forBundle($0.bundleIdentifier ?? "", at: $0.bundleURL) }
        let treeRequested = quirks?.requestsAccessibilityTree == true && frontmost.map { FocusedText.requestAccessibilityTree(pid: $0.processIdentifier) } == true
        let session = DictationSession(target: frontmost, destination: insertion.destination)
        let cleanup = RewriteSettingsStore.load(defaults: defaults)
        if servicesEnabled { Task { [processor] in await processor.prewarm(cleanup) } }
        if let target = session.target, quirks?.credentialManager == false, cleanup.enabled, cleanup.cleanup != .none, cleanup.usesScreenContext {
            let pid = target.processIdentifier
            session.nearbyReading = Task.detached(priority: .userInitiated) {
                // A tree asked for just now arrives a moment later, while the user is still talking.
                if treeRequested { try? await Task.sleep(for: .milliseconds(400)) }
                return FocusedText.nearbyText(pid: pid)
            }
        }
        if let target = session.target, dictionary.suggestsTerms || dictionary.entries.contains(where: { !$0.projects.isEmpty }) {
            // Runs while the user speaks; recognition starts with app-scoped terms and never waits for it.
            let pid = target.processIdentifier, bundle = target.bundleIdentifier
            session.projectDetection = Task { [projectDetector] in await projectDetector.detect(pid: pid, bundleIdentifier: bundle) }
        }
        let lease: SpeechModelLease
        do { lease = try speechModels.beginSession(vocabulary: dictionary.entries.vocabulary(in: DictionaryScope(application: session.dictionaryScope))) }
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
        if servicesEnabled, cleanup.enabled, cleanup.cleanup != .none {
            // Each pause settles text; its AI cleanup starts while the talk key is still held. At key-up it is kept only
            // when the final transcript has the same words, so a take that ends at a pause pastes almost at once.
            active.earlyCleanupTask = Task { @MainActor [weak self, weak active] in
                guard let stream = active?.live.settledTexts else { return }
                for await text in stream {
                    guard let self, let active, !session.cancelled, !active.stopping else { break }
                    if let current = active.earlyCleanup, DraftTranscriptMatch(draft: current.text, final: text) == .same { continue }
                    active.earlyCleanup?.task.cancel()
                    active.earlyCleanup = DraftCleanup(text: text, inputs: self.processingInputs, task: Task { @MainActor [weak self] in
                        await self?.cleanup(text, session: session, reportsOutcome: false, showsProgress: false)
                    })
                }
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
                active.captureID = try await self.capture.start(ranking: self.microphones.ranking,
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
        case .ready(let id, let input):
            guard id == active.captureID, !active.stopping, let overlayID = session.overlayID else { return }
            // A switch is never silent: the first take on a different microphone names it.
            if let previous = lastMicrophoneUID, previous != input.device.uid {
                overlay.setMicrophoneLine("Using \(input.device.name)", session: overlayID)
            }
            lastMicrophoneUID = input.device.uid
            if active.audioReduction == nil {
                active.audioReduction = AudioReductionSession(
                    pauseMedia: defaults.bool(forKey: "audio.pauseMediaWhileDictating"),
                    muteAudio: defaults.bool(forKey: "audio.muteWhileDictating"))
            }
            diagnostics.resolve(.microphone)
            diagnostics.developmentLog.record(.firstBuffer, area: .microphone, operation: session.id)
            overlay.update(.listening, session: overlayID)
        case .switched(let id, let from, let to):
            guard id == active.captureID else { return }
            lastMicrophoneUID = to.device.uid
            var details = DevelopmentDetails(reason: .configurationChanged)
            details.resolvedDevice = diagnostics.developmentLog.deviceID(to.device.uid)
            diagnostics.developmentLog.record(.deviceResolved, area: .microphone, operation: session.id, details: details)
            // A reopened device needs no words; a different one does.
            guard from.uid != to.device.uid, !active.stopping, let overlayID = session.overlayID else { return }
            overlay.setMicrophoneLine("\(from.name) dropped out · now \(to.device.name)", session: overlayID)
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
        // The audio received so far is decoded at once and its AI cleanup starts while capture closes, instead of after.
        // People stop talking before they let go, so it usually has the final transcript's words; see `completeDictation`.
        let settings = RewriteSettingsStore.load(defaults: defaults)
        let speculates = servicesEnabled && settings.enabled && settings.cleanup != .none
        let session = active.session
        active.releaseCleanup = Task { @MainActor [weak self] in
            guard speculates, let text = await active.live.releaseText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let self, !session.cancelled else { return nil }
            return DraftCleanup(text: text, inputs: self.processingInputs, task: Task { @MainActor [weak self] in
                await self?.cleanup(text, session: session, reportsOutcome: false)
            })
        }
        // Capture closes and the final transcript starts off the main actor. The overlay's change to Transcribing renders
        // there meanwhile, and capture's close used to wait behind it twice, about 45 ms, before decoding could start.
        // A take whose capture is still opening keeps the stop task's own path.
        if let captureID = active.captureID, !active.session.cancelled {
            let live = active.live, capture = self.capture, frames = active.frameTask
            let closing = Task.detached { () async throws -> CapturedAudio in
                await live.stopPreview()
                return try await capture.stop(sessionID: captureID)
            }
            active.captureStop = closing
            // Capture's terminal event ends the frame stream, so the transcriber has every frame once its consumer returns.
            active.finalTranscript = Task.detached { () async throws -> LiveEnding in
                _ = try await closing.value
                await frames?.value
                return try await live.finishWithDraft()
            }
        }
        active.stopTask = Task { @MainActor [weak self] in
            if active.captureStop == nil { await active.live.stopPreview() }
            await active.startTask?.value
            guard let self else { throw CancellationError() }
            defer {
                active.captureMilliseconds = Self.milliseconds(since: active.session.captureStarted)
                active.finishEvents()
            }
            // A close already under way is always collected: once it has finished, the capture service no longer owns its
            // recording, so a cancelled take deletes it through `active.audio` when it completes.
            if active.captureStop == nil { try active.session.checkCancellation() }
            guard let captureID = active.captureID else { throw active.failure ?? AudioCaptureFailure(.startFailed) }
            let audio: CapturedAudio
            do {
                if let closing = active.captureStop { audio = try await closing.value }
                else { audio = try await self.capture.stop(sessionID: captureID) }
            } catch {
                active.sounds?.end(sessionID: active.session.id, playStop: false)
                await active.audioReduction?.finish()
                throw error
            }
            var stopped = DevelopmentDetails()
            stopped.sealMilliseconds = audio.stopTiming?.seal
            stopped.fileMilliseconds = audio.stopTiming?.file
            stopped.bufferMilliseconds = audio.stopTiming?.buffer
            self.diagnostics.developmentLog.record(.captureStopped, area: .microphone, operation: active.session.id, details: stopped)
            active.audioReduction?.end()
            active.sounds?.end(sessionID: active.session.id, playStop: !active.session.cancelled)
            active.audio = audio
            await active.frameTask?.value
            await active.eventTask?.value
            self.applyWarmMicrophone()
            return audio
        }
        let stop = active.stopTask
        // Media and output restore when capture ends; only the next capture waits for their helpers to exit.
        captureDrainTask = Task { @MainActor in
            _ = try? await stop?.value
            await active.audioReduction?.finish()
        }
        enqueueDictation(active)
    }

    private func enqueueDictation(_ active: ActiveDictation) {
        guard !active.enqueued else { return }
        active.enqueued = true
        processingQueue.enqueue(active.session, operation: { [weak self] in
            guard let self else { return }
            var drafts: [DraftCleanup] = []
            defer { for draft in drafts { draft.task.cancel() } }
            do {
                guard let stop = active.stopTask else { throw CancellationError() }
                let audio = try await stop.value
                await active.frameTask?.value
                try active.session.checkCancellation()
                // AI cleanup starts before the final transcript: at the last pause while the key was held, at key-up
                // for anything said since, then from the window's draft if the recording itself is recognized. A
                // draft's cleanup is kept only when the final transcript has the same words; see `completeDictation`.
                let settings = RewriteSettingsStore.load(defaults: self.defaults)
                let speculates = self.servicesEnabled && settings.enabled && settings.cleanup != .none
                let session = active.session
                active.earlyCleanupTask?.cancel()
                if let early = active.earlyCleanup { drafts.append(early); active.earlyCleanup = nil }
                @MainActor func startDraftCleanup(_ text: String) {
                    guard speculates, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !drafts.contains(where: { DraftTranscriptMatch(draft: $0.text, final: text) == .same }) else { return }
                    drafts.append(DraftCleanup(text: text, inputs: self.processingInputs, task: Task { @MainActor [weak self] in
                        await self?.cleanup(text, session: session, reportsOutcome: false)
                    }))
                }
                var release = await active.releaseCleanup?.value
                // An earlier take that pasted after this one read its field leaves that reading stale, and every
                // cleanup built on it, as does moving to another field when text goes to the current one: read the
                // field again now that it's this take's turn.
                let moved = session.destination == .currentField && session.contextField?.isStillFocused() == false
                if let read = session.contextInsertions, read != self.insertions || moved {
                    for draft in drafts + [release].compactMap({ $0 }) { draft.task.cancel() }
                    drafts.removeAll()
                    release = nil
                    session.completionContext = nil
                    session.contextInsertions = nil
                    session.contextField = nil
                }
                if let release {
                    if drafts.contains(where: { DraftTranscriptMatch(draft: $0.text, final: release.text) == .same }) { release.task.cancel() }
                    else { drafts.append(release) }
                } else { startDraftCleanup(await active.live.speculativeText()) }
                // The clipboard is saved while the text is prepared, so pasting only rereads it if it changed.
                self.insertion.prepareClipboard()
                let ending: LiveEnding
                if let final = active.finalTranscript {
                    ending = try await withTaskCancellationHandler { try await final.value } onCancel: { final.cancel() }
                } else { ending = try await active.live.finishWithDraft() }
                await active.textTask?.value
                try active.session.checkCancellation()
                var timings = DictationTimings(captureMilliseconds: active.captureMilliseconds,
                                               asrMilliseconds: await active.live.computeMilliseconds)
                let raw: String
                if let result = ending.result {
                    raw = result.text
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.speechPresence == .notDetected {
                        self.diagnostics.developmentLog.record(.speechNotDetected, area: .application, operation: active.session.id)
                    }
                }
                else {
                    self.diagnostics.developmentLog.record(.liveFinalRecovery, area: .application, operation: active.session.id)
                    if let draft = ending.draft { startDraftCleanup(draft) }
                    let engine = try await active.readiness.value
                    try active.session.checkCancellation()
                    let run = try await RecordedAudioPipeline(engine: engine, options: active.lease.options).transcribe(audio.fileURL)
                    raw = run.rawText
                    timings.asrMilliseconds += run.timings.asrMilliseconds
                }
                self.diagnostics.developmentLog.record(.transcriptReady, area: .application, operation: active.session.id)
                try await self.completeDictation(raw, model: active.lease.modelID, audioURL: audio.fileURL,
                    duration: audio.duration, timings: timings, session: active.session, drafts: drafts)
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
            active.earlyCleanupTask?.cancel()
            active.earlyCleanup?.task.cancel()
            // A take that ended before its operation took the key-up cleanup leaves it to cancel here.
            active.releaseCleanup?.cancel()
            if let release = await active.releaseCleanup?.value { release.task.cancel() }
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
        // A close already under way is settled by the capture service's cancel below; its transcript isn't needed.
        active.finalTranscript?.cancel()
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
        // Retranscribing from History should still use project terms detected while recording.
        await session.resolveProject()
        let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let entry = HistoryEntry(id: session.id, rawText: "", finalText: "", targetBundleIdentifier: session.target?.bundleIdentifier,
            targetApplicationName: session.target?.localizedName, dictionaryBundleIdentifier: session.dictionaryScope,
            dictionaryProject: session.dictionaryProject?.name, createdAt: session.createdAt,
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
        let ranking = microphones.ranking
        warmTask = Task { [previous = warmTask, capture, weak self] in
            await previous?.value
            do { try await capture.setWarmMicrophone(enabled: enabled, ranking: ranking) }
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
                                  session: DictationSession, drafts: [DraftCleanup] = []) async throws {
        try session.checkCancellation()
        // A draft whose words match, processed with the current settings, stands for the final transcript; exact matches
        // are tried first.
        let inputs = processingInputs
        var candidates: [(draft: DraftCleanup, match: DraftTranscriptMatch)] = []
        for draft in drafts where draft.inputs == inputs {
            let match = DraftTranscriptMatch(draft: draft.text, final: raw)
            if match == .same { candidates.insert((draft, match), at: 0) }
            else if match != .different { candidates.append((draft, match)) }
        }
        var drafted: TranscriptProcessingResult?
        for (draft, match) in candidates {
            // Cancelling the take stops the provider request instead of waiting out its deadline.
            let task = draft.task
            let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            try session.checkCancellation()
            guard let result = value else { continue }
            if match.keeps(result) {
                // History keeps the final transcript, not the draft's spelling of the same words.
                drafted = TranscriptProcessingResult(rawText: raw, finalText: result.finalText, tone: result.tone, polished: result.polished,
                                                     warning: result.warning, timings: result.timings)
                break
            }
            if let fallback = match.providerFallback(result, final: raw) { drafted = fallback; break }
        }
        for draft in drafts { draft.task.cancel() }
        try session.checkCancellation()
        if let drafted {
            diagnostics.developmentLog.record(.draftCleanupUsed, area: .rewrite, severity: drafted.warning == nil ? .info : .warning,
                                              operation: session.id)
            reportProcessingOutcome(drafted)
        } else if !drafts.isEmpty {
            diagnostics.developmentLog.record(.draftCleanupDiscarded, area: .rewrite, operation: session.id)
        }
        let result: TranscriptProcessingResult
        if let drafted { result = drafted }
        else { result = await cleanup(raw, session: session, reportsOutcome: true) }
        try await finishDictation(result, model: model, audioURL: audioURL, duration: duration, timings: timings, session: session)
    }

    /// Shows the transcript being polished, then processes it with the take's project and landing-field context.
    /// `showsProgress: false` leaves the overlay alone, for a cleanup started while the user is still talking.
    private func cleanup(_ raw: String, session: DictationSession, reportsOutcome: Bool,
                         showsProgress: Bool = true) async -> TranscriptProcessingResult {
        let settings = RewriteSettingsStore.load(defaults: defaults)
        if showsProgress, let overlayID = session.overlayID, !session.cancelled, settings.enabled, settings.cleanup != .none,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlay.model.cleanupLabel = "\(settings.cleanup.title) · \(settings.provider.title)"
            overlay.update(.polishing, committed: raw, tentative: "", session: overlayID)
        }
        let context = await completionContext(for: session)
        return await processTranscript(raw, scope: session.dictionaryContext, context: context, reportsOutcome: reportsOutcome)
    }

    /// Settles the project and reads where the text lands, once per take.
    private func completionContext(for session: DictationSession) async -> DictationContext? {
        if let settled = session.completionContext { return await settled.value }
        let task = Task { @MainActor [weak self] () -> DictationContext? in
            guard let self else { return nil }
            // Without project terms only suggestions need the project, and they can wait for slow detection in the background.
            let needsProject = dictionary.entries.contains { !$0.projects.isEmpty }
            await session.resolveProject(within: .milliseconds(needsProject ? 300 : 20))
            dictionary.lastContext = (session.target?.localizedName, session.dictionaryScope, session.dictionaryProject)
            if let project = session.dictionaryProject { dictionary.offerTerms(from: project) }
            else if !needsProject, session.projectDetection != nil {
                Task { [weak self] in
                    await session.resolveProject(within: .milliseconds(1500))
                    guard let self, let project = session.dictionaryProject else { return }
                    // A later dictation may have finished first; its context stays.
                    if dictionary.lastContext?.bundleIdentifier == session.dictionaryScope, dictionary.lastContext?.project == nil {
                        dictionary.lastContext = (session.target?.localizedName, session.dictionaryScope, project)
                    }
                    dictionary.offerTerms(from: project)
                }
            }
            session.contextInsertions = insertions
            let context = await session.currentContext()
            var read = DevelopmentDetails()
            read.succeeded = context != nil
            read.fieldCharacters = context.map { ($0.textBefore + $0.selectedText + $0.textAfter).count }
            read.nearbyCharacters = context?.nearbyText.count
            read.nearbyElements = session.nearby?.elements
            read.nearbyMilliseconds = session.nearby?.milliseconds
            diagnostics.developmentLog.record(.screenContextRead, area: .application, operation: session.id, details: read)
            return context
        }
        session.completionContext = task
        return await task.value
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
                    await insertion.insert(result.finalText, into: insertionTarget, onPasteSent: { [weak self] in
                        self?.diagnostics.developmentLog.record(.pasteSent, area: .insertion, operation: session.id)
                        showChip()
                    })
                    insertions += 1
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
            targetApplicationName: deliveryApplication?.localizedName, dictionaryBundleIdentifier: session.dictionaryScope,
            dictionaryProject: session.dictionaryProject?.name, createdAt: session.createdAt, completedAt: Date(), audioDuration: duration, model: model, latencies: timings,
            processingWarning: warning)
        let saved = await history.record(entry, untrimmedAudioURL: audioURL, ownsAudioSource: true)
        if saved, pendingEditObservationID == session.id, insertion.watchEdits, !shuttingDown,
           let anchor = insertionAnchor {
            let dictated = result.finalText, scope = session.dictionaryContext
            editWatcher.start(entryID: entry.id, anchor: anchor) { [weak self] observation in
                Task { @MainActor in
                    await self?.history.applyEditObservation(observation)
                    if observation.outcome == .edited, let edited = observation.editedText, let self {
                        let offers = self.dictionary.offerCorrection(dictated: dictated, edited: edited, scope: scope)
                        // One at a time: the overlay queues each offer behind the one on screen.
                        if self.defaults.object(forKey: "overlay.termSuggestions") as? Bool ?? true {
                            offers.forEach(self.overlay.showSuggestion)
                        }
                    }
                }
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
            case .hidden, .inserted, .milestone, .newMicrophone, .termSuggestion, .termAdded: state = .idle
            }
        }
        if mascotState != state { mascotState = state }
    }
}

/// An AI cleanup started before the final transcript, from the text the live path had so far.
struct DraftCleanup {
    let text: String
    let inputs: ProcessingInputs
    let task: Task<TranscriptProcessingResult?, Never>
}

/// The settings, tone and dictionary processing used, besides the transcript.
struct ProcessingInputs: Equatable {
    let settings: RewriteSettings
    let tone: DictationTone
    let entries: [DictionaryEntry]
}
