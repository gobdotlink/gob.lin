import AppKit
import Combine
import GoblinCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let defaults: UserDefaults
    let servicesEnabled: Bool
    let overlay = OverlayController()
    let processor = TranscriptPostprocessor()
    let diagnostics: DiagnosticsModel
    let dictionary: DictionaryModel
    let history: HistoryModel
    let permissions: PermissionModel
    let hotkeys: HotkeyService
    let insertion: TextInsertionService
    let audioPreview: AudioPreviewModel
    @Published var mascotState: MascotState = .idle
    @Published var settingsSelection: SettingsSection? = .general
    @Published var lastTranscript: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var insertionTask: Task<Void, Never>?
    private var shuttingDown = false

    init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard, servicesEnabled: Bool = true,
         diagnosticEnvironment: DiagnosticEnvironment? = nil) {
        self.defaults = defaults
        self.servicesEnabled = servicesEnabled
        diagnostics = DiagnosticsModel(environment: diagnosticEnvironment, logDirectory: dataDirectory?.appendingPathComponent("logs", isDirectory: true))
        history = HistoryModel(directory: dataDirectory, defaults: defaults)
        dictionary = DictionaryModel(repository: dataDirectory.map { DictionaryRepository(url: $0.appendingPathComponent("dictionary.json")) } ?? .applicationDefault)
        permissions = PermissionModel(snapshot: servicesEnabled ? nil : .init(microphone: .notDetermined, accessibility: false, inputMonitoring: false), monitorSystem: servicesEnabled, diagnostics: diagnostics)
        hotkeys = HotkeyService(permissions: permissions, defaults: defaults, monitorSystem: servicesEnabled, diagnostics: diagnostics)
        insertion = TextInsertionService(pasteboard: servicesEnabled ? .general : .withUniqueName(), defaults: defaults, registerShortcuts: servicesEnabled)
        audioPreview = AudioPreviewModel(devices: servicesEnabled ? nil : [InputDevice(id: 0, uid: "preview-input", name: "Preview microphone")], diagnostics: diagnostics)
        for child in [permissions.objectWillChange, hotkeys.objectWillChange, insertion.objectWillChange,
                      history.objectWillChange, dictionary.objectWillChange, audioPreview.objectWillChange, diagnostics.objectWillChange, overlay.model.objectWillChange] {
            child.sink { [weak self] _ in
                Task { @MainActor in self?.synchronizeMascot(); self?.objectWillChange.send() }
            }.store(in: &subscriptions)
        }
        permissions.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in self?.refreshDiagnostics(snapshot: snapshot) }
        }.store(in: &subscriptions)
        hotkeys.$secureInput.sink { [weak self] secure in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.diagnostics.refresh(permissions: self.permissions.snapshot, secureInput: secure)
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
        insertion.$outcome.sink { [weak self] outcome in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                switch outcome {
                case .failure(let failure): self.showFailure(failure)
                case .success: self.diagnostics.resolve(.insertion)
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
        hotkeys.onAction = { [weak self] action in self?.handleHotkey(action) }
        insertion.lastTranscript = { [weak self] in self?.lastTranscript }
        insertion.onPasteRequested = { [weak self] in self?.pasteLastTranscript() }
        history.onRecorded = { [weak self] entry in
            self?.lastTranscript = entry.finalText
            self?.diagnostics.recordTimings(entry.latencies)
        }
        refreshConfiguration()
        refreshDiagnostics(snapshot: permissions.snapshot)
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
        insertionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let operation = UUID()
            self.diagnostics.developmentLog.record(.insertionStarted, area: .insertion, operation: operation)
            await self.insertion.insert(text)
            var details = DevelopmentDetails()
            if case .failure(let failure) = self.insertion.outcome { details.failure = failure; details.succeeded = false }
            else if case .success = self.insertion.outcome { details.succeeded = true }
            self.diagnostics.developmentLog.record(.insertionFinished, area: .insertion, operation: operation, details: details)
            self.insertionTask = nil
        }
    }

    func refreshConfiguration() {
        guard !shuttingDown else { return }
        overlay.position = OverlayPosition(rawValue: defaults.string(forKey: "overlayPosition") ?? "") ?? .bottom
        let settings = RewriteSettingsStore.load(defaults: defaults)
        if settings.enabled && settings.cleanup != .none {
            history.rewriteAction = { [weak self] entry, _ in
                guard let self, !self.shuttingDown else { throw CancellationError() }
                let result = await self.processTranscript(entry.rawText)
                return HistoryReprocessResult(rawText: result.rawText, finalText: result.finalText,
                    tone: result.tone.rawValue, polished: result.polished, model: entry.model,
                    latencies: result.timings, warning: result.warning?.message)
            }
        } else { history.rewriteAction = nil }
        history.retranscribeAction = nil
        objectWillChange.send()
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
            do { key = try RewriteKeychain.load(for: settings) }
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
            hotkeys.cancelRecording()
            if permissions.snapshot.microphone != .authorized { showFailure(.microphonePermissionMissing) }
            else if !permissions.snapshot.accessibility { showFailure(.requiredPermissionsMissing) }
            else if permissions.tapFailure != nil { showFailure(.hotkeyUnavailable) }
            else if hotkeys.secureInput { showFailure(.secureInputEnabled) }
            else { showFailure(.modelUnavailable) }
        case .finishRecording:
            diagnostics.developmentLog.record(.hotkeyFinish, area: .hotkeys)
            hotkeys.processingCompleted()
        case .cancelRecording:
            diagnostics.developmentLog.record(.hotkeyCancel, area: .hotkeys)
            overlay.hide()
        }
    }

    func showFailure(_ failure: DiagnosticFailure) {
        guard !shuttingDown else { return }
        diagnostics.report(failure)
        mascotState = .warning
        let session = overlay.begin { [weak self] in self?.overlay.hide() }
        overlay.update(.error(failure.message), session: session)
        overlay.hide(after: 4, session: session)
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        diagnostics.developmentLog.record(.shutdownRequested, area: .application)
        hotkeys.shutdown()
        permissions.stop()
        insertionTask?.cancel()
        await insertionTask?.value
        insertionTask = nil
        insertion.shutdown()
        history.stopAudio()
        audioPreview.stop(reason: .shutdown)
        overlay.shutdown()
        subscriptions.removeAll()
        diagnostics.developmentLog.record(.appStopped, area: .application)
    }

    private func refreshDiagnostics(snapshot: PermissionModel.Snapshot) {
        guard !shuttingDown else { return }
        diagnostics.refresh(permissions: snapshot, secureInput: hotkeys.secureInput, engineStatus: .awaitingSelection)
    }

    private func synchronizeMascot() {
        if diagnostics.hasWarning { mascotState = .warning; return }
        switch overlay.model.phase {
        case .arming, .listening: mascotState = .recording
        case .transcribing, .polishing: mascotState = .transcribing
        case .error: mascotState = .warning
        case .hidden: mascotState = .idle
        }
    }
}
