import Combine
import Foundation
import GoblinEngines

enum ModelIdleTimeout: Int, CaseIterable, Identifiable {
    case never = 0, fiveMinutes = 5, fifteenMinutes = 15, sixtyMinutes = 60
    var id: Int { rawValue }
    var label: String { self == .never ? "Never" : "\(rawValue) minutes" }
}

struct SpeechModelLease: Hashable, Sendable {
    let id: UUID
    let modelID: String
    let options: RecognitionOptions
    let livePreview: Bool
    fileprivate init(model: SpeechModelDescriptor, options: RecognitionOptions) {
        id = UUID(); modelID = model.id; self.options = options; livePreview = model.capabilities.livePreview
    }
}

enum SpeechModelServiceError: Error, LocalizedError {
    case stopped, expiredLease, modelInUse, unsupportedModel, notReady
    var errorDescription: String? {
        switch self {
        case .stopped: "The speech model service has stopped."
        case .expiredLease: "This dictation no longer owns the speech model."
        case .modelInUse: "Finish the active dictations before changing the model."
        case .unsupportedModel: "This speech model is not supported."
        case .notReady: "The speech model is not ready. Retry preparation in Model settings."
        }
    }
}

enum SpeechModelState: Equatable {
    case notPrepared, preparing(SpeechModelPreparationProgress), ready, unloading, unloaded, cancelling, cancelled, failed(String), stopped
}

struct SpeechModelLoadTiming: Equatable {
    let cache: SpeechModelCacheUse
    let preparationMilliseconds: Double
    let runtimeLoadMilliseconds: Double
}

@MainActor
final class SpeechModelService: ObservableObject {
    @Published private(set) var state: SpeechModelState = .notPrepared
    @Published private(set) var selectedModel: SpeechModelDescriptor
    @Published private(set) var pendingModel: SpeechModelDescriptor?
    @Published private(set) var selectionProgress: SpeechModelPreparationProgress?
    @Published private(set) var preferredLanguage: String
    @Published private(set) var selectionFailure: String?
    @Published private(set) var selectionFailureModelID: String?
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var preparationStartedAt: Date?
    @Published private(set) var lastLoadTiming: SpeechModelLoadTiming?
    @Published var idleTimeout: ModelIdleTimeout {
        didSet { defaults.set(idleTimeout.rawValue, forKey: "modelIdleUnloadMinutes") }
    }
    var models: [SpeechModelDescriptor] { SpeechModelCatalog.supported }
    var directory: URL { store.directory }
    var isPreparing: Bool { preparationTask != nil || switchTask != nil }
    var canChangeModel: Bool { leases.isEmpty && !isPreparing && unloadTask == nil && !stopping && !repairing }
    var recognitionOptions: RecognitionOptions { selectedModel.capabilities.options(for: preferredLanguage) }

    private let defaults: UserDefaults
    private var engine: any PCMSpeechEngine
    private var store: any SpeechModelAcquiring
    private let makeRuntime: @Sendable (SpeechModelDescriptor) -> SpeechModelRuntime
    private var switchTask: Task<Void, Error>?
    private var switchingRuntime = false
    private var leaseDrain: AsyncStream<Void>.Continuation?
    private var leases: Set<SpeechModelLease> = []
    private var preparationTask: Task<Void, Error>?
    private var preparationID: UUID?
    private var acquisitionID: UUID?
    private var unloadTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var loaded = false
    private var stopping = false
    private var repairing = false

    init(defaults: UserDefaults = .standard,
         makeRuntime: @escaping @Sendable (SpeechModelDescriptor) -> SpeechModelRuntime = { SpeechRuntimeFactory.make($0) }) {
        self.defaults = defaults
        self.makeRuntime = makeRuntime
        let selected = SpeechModelCatalog.supported.first { $0.id == defaults.string(forKey: "speechModelID") }
            ?? SpeechModelCatalog.defaultModel
        selectedModel = selected
        let runtime = makeRuntime(selected)
        precondition(runtime.engine.identifier == selected.id)
        engine = runtime.engine
        store = runtime.store
        let language = SpeechModelCatalog.canonicalLanguage(defaults.string(forKey: "speechLanguage") ?? "auto")
        preferredLanguage = language == "auto" || SpeechModelCatalog.supported.contains(where: {
            $0.capabilities.languageCodes.contains(where: { SpeechModelCatalog.canonicalLanguage($0) == language })
        }) ? language : "auto"
        idleTimeout = defaults.object(forKey: "modelIdleUnloadMinutes") == nil ? .fifteenMinutes
            : ModelIdleTimeout(rawValue: defaults.integer(forKey: "modelIdleUnloadMinutes")) ?? .fifteenMinutes
        defaults.set(selectedModel.id, forKey: "speechModelID")
        defaults.set(preferredLanguage, forKey: "speechLanguage")
        defaults.set(idleTimeout.rawValue, forKey: "modelIdleUnloadMinutes")
    }

    convenience init(engine: any PCMSpeechEngine, store: any SpeechModelAcquiring, defaults: UserDefaults = .standard) {
        defaults.set(engine.identifier, forKey: "speechModelID")
        self.init(defaults: defaults, makeRuntime: { model in
            precondition(model.id == engine.identifier)
            return SpeechModelRuntime(engine: engine, store: store)
        })
    }

    func preload() { startMaintenance(); startPreparation() }

    /// Acquire before capture starts and retain until every recognition/fallback worker exits.
    func beginSession(vocabulary: [String] = []) throws -> SpeechModelLease {
        guard !stopping else { throw SpeechModelServiceError.stopped }
        guard !repairing, !switchingRuntime, switchTask == nil || loaded else { throw SpeechModelServiceError.modelInUse }
        // Only Whisper's decoder takes preferred spellings; other models leave the terms to aliases and Cleanup.
        let terms = selectedModel.capabilities.customVocabulary ? vocabulary : []
        let options = RecognitionOptions(language: recognitionOptions.language, vocabulary: terms)
        let lease = SpeechModelLease(model: selectedModel, options: options)
        leases.insert(lease)
        activeSessionCount = leases.count
        lastActivity = .now
        preload()
        return lease
    }

    func readyEngine(for lease: SpeechModelLease) async throws -> any PCMSpeechEngine {
        try validate(lease)
        while !loaded {
            startPreparation()
            guard let preparationTask else { throw SpeechModelServiceError.notReady }
            do { try await preparationTask.value }
            catch {
                try Task.checkCancellation()
                try validate(lease)
                // A hotkey can arrive while a settings cancellation is draining; resume for its new lease.
                if preparationTask.isCancelled { continue }
                throw error
            }
        }
        try Task.checkCancellation()
        try validate(lease)
        guard loaded else { throw SpeechModelServiceError.notReady }
        return engine
    }

    func endSession(_ lease: SpeechModelLease) {
        guard leases.remove(lease) != nil else { return }
        activeSessionCount = leases.count
        lastActivity = .now
        if leases.isEmpty { leaseDrain?.yield(()) }
    }

    func selectModel(id: String) async throws {
        guard canChangeModel else { throw SpeechModelServiceError.modelInUse }
        guard let descriptor = models.first(where: { $0.id == id }) else { throw SpeechModelServiceError.unsupportedModel }
        guard descriptor.id != selectedModel.id else { return }
        let candidate = makeRuntime(descriptor)
        precondition(candidate.engine.identifier == descriptor.id)
        let previous = SpeechModelRuntime(engine: engine, store: store)
        let previousState = state
        let wasLoaded = loaded
        let preparationID = UUID()
        self.preparationID = preparationID
        pendingModel = descriptor
        selectionFailure = nil
        selectionFailureModelID = nil
        preparationStartedAt = Date()
        selectionProgress = .init(phase: .checkingCache)
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let start = ContinuousClock.now
            var unloadedPrevious = false
            do {
                let cache = try await self.acquire(candidate.store, id: preparationID)
                self.switchingRuntime = true
                self.selectionProgress = .init(phase: .loading, component: "Waiting for current dictations to finish")
                try await self.waitForSessions()
                self.state = .preparing(.init(phase: .loading, component: "Switching speech model"))
                await previous.engine.unload()
                unloadedPrevious = true
                self.loaded = false
                try Task.checkCancellation()
                let timing = try await self.prepare(candidate, id: preparationID, acquired: cache, start: start)
                try Task.checkCancellation()
                self.engine = candidate.engine
                self.store = candidate.store
                self.selectedModel = descriptor
                self.defaults.set(descriptor.id, forKey: "speechModelID")
                self.loaded = true
                self.lastLoadTiming = timing
                self.lastActivity = .now
                self.state = .ready
            } catch {
                self.acquisitionID = nil
                await candidate.engine.unload()
                self.selectionFailure = error is CancellationError ? "Model switch cancelled. Previous selection kept." : error.localizedDescription
                self.selectionFailureModelID = error is CancellationError ? nil : descriptor.id
                if !self.stopping, wasLoaded, unloadedPrevious {
                    // Restoration runs outside the cancelled switch so the previous model can recover.
                    let restore = Task { try await previous.engine.prepare() }
                    do { try await restore.value; self.loaded = true; self.state = .ready }
                    catch { self.state = .failed("Previous model could not reload: \(error.localizedDescription)") }
                } else { self.state = self.stopping ? .stopped : previousState }
                self.finishSwitch()
                throw error
            }
            self.finishSwitch()
        }
        switchTask = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func selectLanguage(_ intent: String) throws {
        let language = SpeechModelCatalog.canonicalLanguage(intent)
        guard language == "auto" || models.contains(where: {
            $0.capabilities.languageCodes.contains(where: { SpeechModelCatalog.canonicalLanguage($0) == language })
        }) else { throw SpeechRuntimeError.unsupportedLanguage(intent) }
        preferredLanguage = language
        defaults.set(language, forKey: "speechLanguage")
    }

    private func finishSwitch() {
        pendingModel = nil
        selectionProgress = nil
        switchTask = nil
        switchingRuntime = false
        preparationID = nil
        acquisitionID = nil
        preparationStartedAt = nil
    }

    private func waitForSessions() async throws {
        try Task.checkCancellation()
        guard !leases.isEmpty else { return }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        leaseDrain = continuation
        defer { continuation.finish(); leaseDrain = nil }
        for await _ in events {
            try Task.checkCancellation()
            if leases.isEmpty { return }
        }
        throw CancellationError()
    }

    func retry() {
        guard leases.isEmpty, !stopping else { return }
        preload()
    }

    func cancelPreparation() {
        guard !stopping, switchTask != nil || leases.isEmpty,
              let task = switchTask ?? preparationTask else { return }
        acquisitionID = nil
        if switchTask != nil, loaded {
            selectionProgress = .init(phase: .loading, component: "Cancelling model switch")
        } else { state = .cancelling }
        task.cancel()
    }

    func repair() async {
        guard canChangeModel else { return }
        repairing = true
        defer { repairing = false }
        do {
            // No lease or preparation may start while the cache is being replaced.
            let id = UUID()
            preparationID = id
            let runtime = engine
            let store = store
            preparationTask = Task {
                await runtime.unload()
                try Task.checkCancellation()
                try await store.removeCachedModel()
            }
            state = .preparing(.init(phase: .checkingCache, component: "Replacing cached model"))
            loaded = false
            try await preparationTask?.value
            preparationID = nil
            preparationTask = nil
            preload()
        } catch {
            preparationID = nil
            preparationTask = nil
            state = stopping ? .stopped : .failed(error.localizedDescription)
        }
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        maintenanceTask?.cancel()
        maintenanceTask = nil
        preparationTask?.cancel()
        switchTask?.cancel()
        if let switchTask { _ = try? await switchTask.value }
        if let preparationTask { _ = try? await preparationTask.value }
        if let unloadTask { await unloadTask.value }
        await engine.unload()
        loaded = false
        leases.removeAll()
        activeSessionCount = 0
        state = .stopped
    }

    // The timer stays alive during capture; leases, rather than recording duration, gate unload.
    func unloadIfIdle(now: ContinuousClock.Instant = .now) {
        guard !stopping, loaded, leases.isEmpty, preparationTask == nil, switchTask == nil, unloadTask == nil,
              idleTimeout != .never, lastActivity.duration(to: now) >= .seconds(idleTimeout.rawValue * 60) else { return }
        loaded = false
        state = .unloading
        let runtime = engine
        unloadTask = Task { [weak self] in
            await runtime.unload()
            guard let self else { return }
            self.unloadTask = nil
            if self.preparationTask == nil, !self.stopping { self.state = .unloaded }
        }
    }

    private func validate(_ lease: SpeechModelLease) throws {
        guard !stopping else { throw SpeechModelServiceError.stopped }
        guard leases.contains(lease), lease.modelID == selectedModel.id else { throw SpeechModelServiceError.expiredLease }
    }

    private func startMaintenance() {
        guard maintenanceTask == nil, !stopping else { return }
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                guard let self else { break }
                self.unloadIfIdle()
            }
        }
    }

    private func startPreparation() {
        guard !stopping, !loaded, preparationTask == nil, switchTask == nil else { return }
        let id = UUID()
        preparationID = id
        preparationStartedAt = Date()
        state = .preparing(.init(phase: .checkingCache))
        let previousUnload = unloadTask
        preparationTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                if let previousUnload { await previousUnload.value }
                try Task.checkCancellation()
                let timing = try await self.prepare(SpeechModelRuntime(engine: self.engine, store: self.store), id: id)
                self.loaded = true
                try Task.checkCancellation()
                self.lastLoadTiming = timing
                self.preparationID = nil
                self.preparationTask = nil
                self.lastActivity = .now
                self.preparationStartedAt = nil
                self.state = .ready
            } catch {
                // A cancelled CoreML load may already have completed; drain it before a retry.
                await self.engine.unload()
                self.loaded = false
                self.preparationID = nil
                self.acquisitionID = nil
                self.preparationTask = nil
                self.preparationStartedAt = nil
                self.state = self.stopping ? .stopped : (Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
                throw error
            }
        }
    }

    private func acquire(_ store: any SpeechModelAcquiring, id: UUID) async throws -> SpeechModelCacheUse {
        acquisitionID = id
        let cache = try await store.ensureAvailable { [weak self] progress in
            Task { @MainActor in
                guard let self, self.preparationID == id, self.acquisitionID == id,
                      self.state != .cancelling, !self.stopping else { return }
                if self.pendingModel != nil { self.selectionProgress = progress }
                else { self.state = .preparing(progress) }
            }
        }
        acquisitionID = nil
        try Task.checkCancellation()
        return cache
    }

    private func prepare(_ runtime: SpeechModelRuntime, id: UUID, acquired: SpeechModelCacheUse? = nil,
                         start: ContinuousClock.Instant = .now) async throws -> SpeechModelLoadTiming {
        let cache: SpeechModelCacheUse
        if let acquired { cache = acquired } else { cache = try await acquire(runtime.store, id: id) }
        try Task.checkCancellation()
        state = .preparing(.init(phase: .compiling, component: "Core ML"))
        if pendingModel != nil { selectionProgress = .init(phase: .compiling, component: "Core ML") }
        let loadStart = ContinuousClock.now
        try await runtime.engine.prepare()
        try Task.checkCancellation()
        return SpeechModelLoadTiming(cache: cache, preparationMilliseconds: Self.milliseconds(since: start),
                                    runtimeLoadMilliseconds: Self.milliseconds(since: loadStart))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
