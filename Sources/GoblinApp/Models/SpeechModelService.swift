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
    fileprivate init(modelID: String) { id = UUID(); self.modelID = modelID }
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
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var preparationStartedAt: Date?
    @Published private(set) var lastLoadTiming: SpeechModelLoadTiming?
    @Published var idleTimeout: ModelIdleTimeout {
        didSet { defaults.set(idleTimeout.rawValue, forKey: "modelIdleUnloadMinutes") }
    }
    var models: [SpeechModelDescriptor] { SpeechModelCatalog.supported }
    var directory: URL { store.directory }
    var isPreparing: Bool { preparationTask != nil }
    var canChangeModel: Bool { leases.isEmpty && !isPreparing && unloadTask == nil && !stopping }

    private let defaults: UserDefaults
    private let engine: any PCMSpeechEngine
    private let store: any SpeechModelAcquiring
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

    init(engine: any PCMSpeechEngine, store: any SpeechModelAcquiring, defaults: UserDefaults = .standard) {
        precondition(engine.identifier == SpeechModelCatalog.parakeet.id)
        self.engine = engine
        self.store = store
        self.defaults = defaults
        selectedModel = SpeechModelCatalog.supported.first { $0.id == defaults.string(forKey: "speechModelID") }
            ?? SpeechModelCatalog.defaultModel
        idleTimeout = defaults.object(forKey: "modelIdleUnloadMinutes") == nil ? .fifteenMinutes
            : ModelIdleTimeout(rawValue: defaults.integer(forKey: "modelIdleUnloadMinutes")) ?? .fifteenMinutes
        defaults.set(selectedModel.id, forKey: "speechModelID")
        defaults.set(idleTimeout.rawValue, forKey: "modelIdleUnloadMinutes")
    }

    func preload() { startMaintenance(); startPreparation() }

    /// Acquire before capture starts and retain until every recognition/fallback worker exits.
    func beginSession() throws -> SpeechModelLease {
        guard !stopping else { throw SpeechModelServiceError.stopped }
        guard !repairing else { throw SpeechModelServiceError.modelInUse }
        let lease = SpeechModelLease(modelID: selectedModel.id)
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
                if state == .cancelled { continue }
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
    }

    func selectModel(id: String) throws {
        guard canChangeModel else { throw SpeechModelServiceError.modelInUse }
        guard let descriptor = models.first(where: { $0.id == id }) else { throw SpeechModelServiceError.unsupportedModel }
        selectedModel = descriptor
        defaults.set(id, forKey: "speechModelID")
    }

    func retry() {
        guard leases.isEmpty, !stopping else { return }
        preload()
    }

    func cancelPreparation() {
        guard leases.isEmpty, let preparationTask, !stopping else { return }
        state = .cancelling
        preparationTask.cancel()
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
        guard !stopping, loaded, leases.isEmpty, preparationTask == nil, unloadTask == nil,
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
        guard !stopping, !loaded, preparationTask == nil else { return }
        let id = UUID()
        preparationID = id
        acquisitionID = id
        preparationStartedAt = Date()
        state = .preparing(.init(phase: .checkingCache))
        let previousUnload = unloadTask
        preparationTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let start = ContinuousClock.now
            do {
                if let previousUnload { await previousUnload.value }
                try Task.checkCancellation()
                let cache = try await self.store.ensureAvailable { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.preparationID == id, self.acquisitionID == id,
                              self.state != .cancelling, !self.stopping else { return }
                        self.state = .preparing(progress)
                    }
                }
                self.acquisitionID = nil
                try Task.checkCancellation()
                self.state = .preparing(.init(phase: .compiling, component: "Core ML"))
                let loadStart = ContinuousClock.now
                try await self.engine.prepare()
                self.loaded = true
                try Task.checkCancellation()
                self.lastLoadTiming = SpeechModelLoadTiming(cache: cache, preparationMilliseconds: Self.milliseconds(since: start),
                                                          runtimeLoadMilliseconds: Self.milliseconds(since: loadStart))
                self.preparationID = nil
                self.preparationTask = nil
                self.lastActivity = .now
                self.preparationStartedAt = nil
                self.state = .ready
            } catch {
                // A cancelled CoreML load may already have completed; drain it before a retry.
                if self.loaded { await self.engine.unload(); self.loaded = false }
                self.preparationID = nil
                self.acquisitionID = nil
                self.preparationTask = nil
                self.preparationStartedAt = nil
                self.state = self.stopping ? .stopped : (Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
                throw error
            }
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
