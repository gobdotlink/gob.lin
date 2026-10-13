import AppKit
import Combine
import CryptoKit
import FluidAudio
import Foundation
@testable import GoblinEngines
import SwiftUI

private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

private actor CheckEngine: PCMSpeechEngine {
    nonisolated let identifier = SpeechModelCatalog.parakeet.id
    nonisolated let maximumWindowSamples = 240_000
    var events: [String] = []
    func prepare() async throws {
        events.append("prepare")
        try await Task.sleep(for: .milliseconds(40))
        events.append("ready")
    }
    func unload() async {
        events.append("unload")
        try? await Task.sleep(for: .milliseconds(40))
        events.append("unloaded")
    }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { .init(text: "") }
    func transcribe(samples: [Float]) async throws -> TranscriptionResult { .init(text: "") }
}

private actor CheckStore: SpeechModelAcquiring {
    nonisolated let directory = URL(fileURLWithPath: "/tmp/model-check-cache")
    var attempts = 0
    var failNext = false
    var callback: (@Sendable (SpeechModelPreparationProgress) -> Void)?
    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        attempts += 1
        callback = progress
        progress(.init(phase: .downloading, fractionCompleted: 0.4))
        try await Task.sleep(for: .milliseconds(40))
        if failNext { failNext = false; throw CheckFailure(message: "Simulated transfer failure") }
        return .cached
    }
    func failOnce() { failNext = true }
    func emitLateProgress() { callback?(.init(phase: .downloading, fractionCompleted: 0.1)) }
    func removeCachedModel() async throws { try await Task.sleep(for: .milliseconds(40)) }
}

@main private struct ModelChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--real") { try await realCache(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > index + 1 {
            try await capture(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-real"), CommandLine.arguments.count > index + 1 {
            try await capture(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), real: true); return
        }
        try await lifecycle()
        try await integrity()
        try await listingGuard()
        print("PASS model lease, idle, cancellation, retry, stale progress, repair and integrity checks")
    }

    @MainActor private static func settle(_ service: SpeechModelService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.isPreparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(!service.isPreparing, "Preparation did not settle")
    }

    @MainActor private static func lifecycle() async throws {
        let suite = "app.goblin.model-check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown-model", forKey: "speechModelID")
        defaults.set(77, forKey: "modelIdleUnloadMinutes")
        let runtime = CheckEngine(), store = CheckStore()
        let service = SpeechModelService(engine: runtime, store: store, defaults: defaults)
        try expect(service.idleTimeout == .fifteenMinutes && service.selectedModel.id == runtime.identifier, "Invalid settings were not healed")
        service.preload()
        let capture = try service.beginSession(), queuedRecognition = try service.beginSession()
        try expect(service.activeSessionCount == 2, "Capture leases must protect before loading")
        _ = try await service.readyEngine(for: capture)
        _ = try await service.readyEngine(for: queuedRecognition)
        let acquisitionCount = await store.attempts
        try expect(acquisitionCount == 1, "Concurrent sessions installed twice")
        service.unloadIfIdle(now: .now.advanced(by: .seconds(7_200)))
        try expect(service.state == .ready, "Unloaded during long capture")
        do { try service.selectModel(id: runtime.identifier); throw CheckFailure(message: "Changed model during capture") }
        catch SpeechModelServiceError.modelInUse { }
        service.cancelPreparation()
        service.endSession(capture)
        service.unloadIfIdle(now: .now.advanced(by: .seconds(7_200)))
        try expect(service.state == .ready, "Unloaded during queued inference")
        service.endSession(queuedRecognition)
        service.endSession(queuedRecognition)
        service.idleTimeout = .never
        service.unloadIfIdle(now: .now.advanced(by: .seconds(7_200)))
        try expect(service.state == .ready, "Never policy unloaded")
        service.idleTimeout = .fiveMinutes
        service.unloadIfIdle()
        try expect(service.state == .ready, "Lease release did not reset idle")
        service.unloadIfIdle(now: .now.advanced(by: .seconds(301)))
        try expect(service.state == .unloading, "Idle model did not unload")
        let nextCapture = try service.beginSession()
        _ = try await service.readyEngine(for: nextCapture)
        let events = await runtime.events
        try expect(events == ["prepare", "ready", "unload", "unloaded", "prepare", "ready"], "Reload raced idle unload")
        await store.emitLateProgress()
        try await Task.sleep(for: .milliseconds(10))
        try expect(service.state == .ready, "Obsolete download callback overwrote ready state")
        service.endSession(nextCapture)
        do { _ = try await service.readyEngine(for: nextCapture); throw CheckFailure(message: "Expired lease was accepted") }
        catch SpeechModelServiceError.expiredLease { }
        let repair = Task { await service.repair() }
        try await Task.sleep(for: .milliseconds(5))
        do { _ = try service.beginSession(); throw CheckFailure(message: "Capture raced cache replacement") }
        catch SpeechModelServiceError.modelInUse { }
        await repair.value
        try await settle(service)
        try expect(service.state == .ready, "Repair did not restore readiness")
        await service.shutdown()
        try expect(service.state == .stopped, "Shutdown did not drain")
        do { _ = try service.beginSession(); throw CheckFailure(message: "New lease after shutdown") }
        catch SpeechModelServiceError.stopped { }

        let failingStore = CheckStore()
        await failingStore.failOnce()
        let failing = SpeechModelService(engine: CheckEngine(), store: failingStore, defaults: defaults)
        let lease = try failing.beginSession()
        _ = try? await failing.readyEngine(for: lease)
        failing.endSession(lease)
        if case .failed = failing.state { } else { throw CheckFailure(message: "Failure state missing") }
        failing.retry()
        let retryLease = try failing.beginSession()
        _ = try await failing.readyEngine(for: retryLease)
        failing.endSession(retryLease)
        let retryCount = await failingStore.attempts
        try expect(retryCount == 2, "Retry did not rerun acquisition")
        await failing.shutdown()

        let cancelled = SpeechModelService(engine: CheckEngine(), store: CheckStore(), defaults: defaults)
        cancelled.preload()
        cancelled.cancelPreparation()
        try await settle(cancelled)
        try expect(cancelled.state == .cancelled, "Cancel state missing")
        cancelled.retry()
        let resumed = try cancelled.beginSession()
        _ = try await cancelled.readyEngine(for: resumed)
        cancelled.endSession(resumed)
        try expect(cancelled.state == .ready, "Cancelled preparation could not resume")
        await cancelled.shutdown()

        let hotkeyRace = SpeechModelService(engine: CheckEngine(), store: CheckStore(), defaults: defaults)
        hotkeyRace.preload()
        hotkeyRace.cancelPreparation()
        let bufferedCapture = try hotkeyRace.beginSession()
        _ = try await hotkeyRace.readyEngine(for: bufferedCapture)
        try expect(hotkeyRace.state == .ready, "Hotkey joining cancelled preparation did not resume")
        hotkeyRace.endSession(bufferedCapture)
        await hotkeyRace.shutdown()
    }

    private static func integrity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-integrity-\(UUID())")
        let directory = root.appendingPathComponent(Repo.parakeetV3.folderName)
        defer { try? FileManager.default.removeItem(at: root) }
        let required = ModelNames.ASR.requiredModelsV3().sorted()
        for name in required {
            let bundle = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let store = ParakeetModelStore(directory: directory)
        do {
            _ = try await store.ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "An upgraded cache without speech detection was reported available offline")
        } catch DownloadError.networkDisabled { }
        do {
            try await ParakeetSpeechEngine(modelDirectory: directory).prepare()
            throw CheckFailure(message: "Runtime silently accepted a missing speech detector")
        } catch SpeechRuntimeError.speechDetectorNotInstalled { }
        let detectorDirectory = root.appendingPathComponent(Repo.vad.folderName)
        for name in ModelNames.VAD.requiredModels {
            let bundle = detectorDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        let staged = try await store.ensureAvailable(progress: { _ in })
        try expect(staged == .cached, "Staged offline cache was not adopted")
        let reopened = ParakeetModelStore(directory: directory)
        let reopenedCache = try await reopened.ensureAvailable(progress: { _ in })
        try expect(reopenedCache == .cached, "Offline inventory validation failed")
        let detectorFile = detectorDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile).appendingPathComponent("coremldata.bin")
        try Data("changed".utf8).write(to: detectorFile)
        do {
            _ = try await ParakeetModelStore(directory: directory).ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "A corrupted detector was reported ready")
        } catch SpeechModelStoreError.invalidCache { }
        try Data("fixture".utf8).write(to: detectorFile)
        let changed = directory.appendingPathComponent(required[0]).appendingPathComponent("coremldata.bin")
        try Data("changed".utf8).write(to: changed)
        do {
            _ = try await ParakeetModelStore(directory: directory).ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "Same-size damaged file was accepted")
        } catch SpeechModelStoreError.invalidCache { }
        try await store.removeCachedModel()
        try expect(!FileManager.default.fileExists(atPath: directory.path), "Explicit repair kept corrupt cache")
        try expect(!FileManager.default.fileExists(atPath: detectorDirectory.path), "Explicit repair kept the detector cache")
        print("PASS offline staged adoption, inventory reload and same-size corruption rejection (synthetic files, no CoreML)")
    }

    private static func listingGuard() async throws {
        do {
            try await ParakeetModelStore.guardListing(timeout: .milliseconds(20)) { _ in
                try await Task.sleep(for: .seconds(60))
            }
            throw CheckFailure(message: "Stalled metadata listing was accepted")
        } catch SpeechModelStoreError.listingStalled { }
        try await ParakeetModelStore.guardListing(timeout: .milliseconds(20)) { transferStarted in
            transferStarted()
            try await Task.sleep(for: .milliseconds(80))
        }
        let cancelled = Task {
            try await ParakeetModelStore.guardListing { _ in try await Task.sleep(for: .seconds(60)) }
        }
        cancelled.cancel()
        do { try await cancelled.value; throw CheckFailure(message: "Cancelled listing continued") }
        catch is CancellationError { }
        print("PASS stalled listing guard, transfer handoff and structured cancellation checks (simulated operations)")
    }

    private static func realCache() async throws {
        let store = ParakeetModelStore(directory: try ParakeetModelStore.defaultDirectory())
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let start = ContinuousClock.now
        let cache = try await store.ensureAvailable { progress in print("Cache phase: \(progress.phase)") }
        let runtime = ParakeetSpeechEngine(modelDirectory: store.directory)
        let first = ContinuousClock.now
        try await runtime.prepare()
        let firstDuration = first.duration(to: .now)
        await runtime.unload()
        let reload = ContinuousClock.now
        _ = try await store.ensureAvailable(progress: { _ in })
        try await runtime.prepare()
        print("Real offline cache=\(cache.rawValue), total validation=\(start.duration(to: .now)), initial local load=\(firstDuration), cached unload/reload=\(reload.duration(to: .now))")
        await runtime.unload()
    }

    @MainActor private static func capture(to directory: URL, real: Bool = false) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "app.goblin.model-layout.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service: SpeechModelService
        if real {
            ModelHub.offlineMode = true
            let store = ParakeetModelStore(directory: try ParakeetModelStore.defaultDirectory())
            service = SpeechModelService(engine: ParakeetSpeechEngine(modelDirectory: store.directory), store: store, defaults: defaults)
        } else {
            let store = CheckStore()
            await store.failOnce()
            service = SpeechModelService(engine: CheckEngine(), store: store, defaults: defaults)
        }
        defer { ModelHub.offlineMode = false }
        service.preload()
        let host = NSHostingView(rootView: ScrollView { ModelSettingsView(service: service) }.preferredColorScheme(.dark)
            .frame(width: 620, height: 820, alignment: .topLeading).background(Color(red: 0.09, green: 0.10, blue: 0.12)))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 820)
        try snapshot(host, to: directory.appendingPathComponent("model-preparation-layout.png"))
        if real {
            preparation: for await state in service.$state.values {
                switch state {
                case .preparing(let progress) where progress.phase == .compiling:
                    try snapshot(host, to: directory.appendingPathComponent("model-coreml-layout.png"))
                case .ready: break preparation
                case .failed(let error): throw CheckFailure(message: error)
                default: break
                }
            }
        } else {
            try await settle(service)
            try snapshot(host, to: directory.appendingPathComponent("model-failure-layout.png"))
            service.retry()
            try await settle(service)
        }
        try snapshot(host, to: directory.appendingPathComponent("model-ready-layout.png"))
        await service.shutdown()
        print("Captured native model-settings layouts with \(real ? "real offline runtime" : "simulated preparation states"); no microphone or permissions requested")
    }

    @MainActor private static func snapshot(_ view: NSView, to url: URL) throws {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure(message: "No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(message: "No PNG") }
        try png.write(to: url)
    }
}
