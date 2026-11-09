import AppKit
import Combine
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import GoblinCore
@testable import GoblinEngines
@testable import GoblinApp
import SwiftUI
import Synchronization

private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message: message) }
}

private actor CheckEngine: PCMSpeechEngine {
    nonisolated let identifier: String
    nonisolated let maximumWindowSamples = 240_000
    var events: [String] = []
    var optionsUsed: [RecognitionOptions] = []
    var failNext = false
    init(_ identifier: String = SpeechModelCatalog.parakeet.id) { self.identifier = identifier }
    func failOnce() { failNext = true }
    func prepare() async throws {
        events.append("prepare")
        try await Task.sleep(for: .milliseconds(40))
        if failNext { failNext = false; throw CheckFailure(message: "Simulated model load failure") }
        events.append("ready")
    }
    func unload() async {
        events.append("unload")
        try? await Task.sleep(for: .milliseconds(40))
        events.append("unloaded")
    }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        optionsUsed.append(request.options); return .init(text: "recognized")
    }
    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        optionsUsed.append(options); return .init(text: "recognized")
    }
}

private actor CheckStore: SpeechModelAcquiring {
    nonisolated let directory: URL
    let delay: Duration
    var attempts = 0
    var failNext = false
    var callback: (@Sendable (SpeechModelPreparationProgress) -> Void)?
    init(delay: Duration = .milliseconds(40), directory: URL = URL(fileURLWithPath: "/tmp/model-check-cache")) {
        self.delay = delay; self.directory = directory
    }
    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        attempts += 1
        callback = progress
        progress(.init(phase: .downloading, fractionCompleted: 0.4))
        try await Task.sleep(for: delay)
        if failNext { failNext = false; throw CheckFailure(message: "Simulated transfer failure") }
        return .cached
    }
    func failOnce() { failNext = true }
    func emitLateProgress() { callback?(.init(phase: .downloading, fractionCompleted: 0.1)) }
    func removeCachedModel() async throws { try await Task.sleep(for: .milliseconds(40)) }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        var headers: [String: String] = [:]
        var suspend = false
    }
    private static let handler = Mutex<(@Sendable (URLRequest) -> Reply)?>(nil)
    static func respond(_ value: @escaping @Sendable (URLRequest) -> Reply) { handler.withLock { $0 = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.handler.withLock { $0! }(request)
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(reply.body.count) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if !reply.suspend { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

@main private struct ModelChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        if CommandLine.arguments.contains("--real") { try await realCache(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--whisper-real"), CommandLine.arguments.count > index + 1 {
            try await realWhisper(hebrewSpeech: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--dictionary-real"), CommandLine.arguments.count > index + 2 {
            try await realDictionary(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                     audio: URL(fileURLWithPath: CommandLine.arguments[index + 2])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-dictionary"), CommandLine.arguments.count > index + 2 {
            try await captureDictionary(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                        modelDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 2])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > index + 1 {
            try await capture(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-real"), CommandLine.arguments.count > index + 1 {
            try await capture(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), real: true); return
        }
        try await lifecycle()
        try await switching()
        try await integrity()
        try downloadProgress()
        try await tokenizerBoundary()
        try whisperSuppression()
        try dictionaryCapacity()
        try await dictionaryRouting()
        try await expandedCatalog()
        print("PASS catalog, language, switching, leases, idle, cancellation, retry, acquisition and integrity checks")
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
        do { try await service.selectModel(id: runtime.identifier); throw CheckFailure(message: "Changed model during capture") }
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

    @MainActor private static func switching() async throws {
        let suite = "app.goblin.model-switch-check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engines = Dictionary(uniqueKeysWithValues: SpeechModelCatalog.supported.map { ($0.id, CheckEngine($0.id)) })
        let stores = Dictionary(uniqueKeysWithValues: SpeechModelCatalog.supported.map { ($0.id, CheckStore()) })
        let factory: @Sendable (SpeechModelDescriptor) -> SpeechModelRuntime = {
            SpeechModelRuntime(engine: engines[$0.id]!, store: stores[$0.id]!)
        }
        let service = SpeechModelService(defaults: defaults, makeRuntime: factory)
        try expect(service.selectedModel == SpeechModelCatalog.defaultModel, "Default model was not selected")
        let initial = try service.beginSession(vocabulary: ["Parakeet"])
        try expect(initial.options.vocabulary.isEmpty, "Parakeet received recognition terms; only Whisper's decoder takes them")
        _ = try await service.readyEngine(for: initial)
        service.endSession(initial)
        try await service.selectModel(id: SpeechModelCatalog.whisperTiny.id)
        try expect(service.selectedModel.id == SpeechModelCatalog.whisperTiny.id && service.state == .ready, "Selection did not activate a different runtime")
        try expect(defaults.string(forKey: "speechModelID") == service.selectedModel.id, "Successful switch was not persisted")
        try service.selectLanguage("ja-JP")
        let first = try service.beginSession(vocabulary: ["Postgres"])
        let runtime = try await service.readyEngine(for: first)
        try expect(runtime.identifier == SpeechModelCatalog.whisperTiny.id, "Selector only changed metadata")
        try service.selectLanguage("fr")
        let second = try service.beginSession(vocabulary: ["CodeRabbit"])
        try expect(first.options.language == "ja" && second.options.language == "fr", "Language change mutated an existing recording")
        try expect(first.options.vocabulary == ["Postgres"] && second.options.vocabulary == ["CodeRabbit"],
                   "Dictionary change mutated an existing recording")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("model-options-\(UUID()).wav")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await RecordedAudioPipeline(engine: runtime, options: first.options).transcribe(file)
        let options = await engines[SpeechModelCatalog.whisperTiny.id]!.optionsUsed
        try expect(options == [first.options], "Original-file recovery used different language options")
        service.endSession(first); service.endSession(second)
        try service.selectLanguage("ja")
        try await service.selectModel(id: SpeechModelCatalog.parakeet.id)
        try expect(service.preferredLanguage == "ja" && service.recognitionOptions.language == nil, "Unsupported model overwrote language intent")
        try await service.selectModel(id: SpeechModelCatalog.whisperTiny.id)
        try expect(service.recognitionOptions.language == "ja", "Returning to a compatible model lost the preference")

        let turbo = engines[SpeechModelCatalog.whisperTurbo.id]!
        await turbo.failOnce()
        let failure = Task { try await service.selectModel(id: SpeechModelCatalog.whisperTurbo.id) }
        try await waitForSwitch(service)
        try expect(!service.canChangeModel, "Parallel switch remained available")
        let duringDownload = try service.beginSession()
        let downloadRuntime = try await service.readyEngine(for: duringDownload)
        try expect(downloadRuntime.identifier == SpeechModelCatalog.whisperTiny.id, "Candidate download interrupted current-model recording")
        do { try await service.selectModel(id: SpeechModelCatalog.parakeet.id); throw CheckFailure(message: "Two model switches overlapped") }
        catch SpeechModelServiceError.modelInUse { }
        try await Task.sleep(for: .milliseconds(70))
        try expect(service.state == .ready && service.activeSessionCount == 1, "Switch unloaded a leased model")
        service.endSession(duringDownload)
        do { try await failure.value; throw CheckFailure(message: "Model load failure was swallowed") }
        catch let error as CheckFailure { try expect(error.message == "Simulated model load failure", "Unexpected model failure") }
        try expect(service.selectedModel.id == SpeechModelCatalog.whisperTiny.id && service.state == .ready, "Failed switch did not restore the previous runtime")
        try expect(defaults.string(forKey: "speechModelID") == SpeechModelCatalog.whisperTiny.id, "Failed candidate replaced saved selection")
        try expect(service.selectionFailureModelID == SpeechModelCatalog.whisperTurbo.id && service.selectionFailure != nil,
                   "Failed switch lost the model needed to show its retry action after reopening Settings")
        await stores[SpeechModelCatalog.whisperTurbo.id]!.emitLateProgress()
        try await Task.sleep(for: .milliseconds(10))
        try expect(service.state == .ready, "Failed candidate's stale progress overwrote restored state")

        await stores[SpeechModelCatalog.whisperLarge.id]!.failOnce()
        do { try await service.selectModel(id: SpeechModelCatalog.whisperLarge.id); throw CheckFailure(message: "Download failure was swallowed") }
        catch let error as CheckFailure { try expect(error.message == "Simulated transfer failure", "Unexpected download failure") }
        try expect(service.state == .ready && service.selectedModel.id == SpeechModelCatalog.whisperTiny.id, "Download failure stranded the old model")
        let cancellation = Task { try await service.selectModel(id: SpeechModelCatalog.whisperTurbo.id) }
        try await waitForSwitch(service)
        service.cancelPreparation()
        do { try await cancellation.value; throw CheckFailure(message: "Cancelled switch completed") }
        catch is CancellationError { }
        try expect(service.state == .ready && service.canChangeModel && service.selectedModel.id == SpeechModelCatalog.whisperTiny.id,
                   "Cancelled switch did not drain and restore")
        try expect(service.selectionFailureModelID == nil, "Cancellation left an unrelated model marked as failed")

        let leasedCancellation = Task { try await service.selectModel(id: SpeechModelCatalog.whisperTurbo.id) }
        try await waitForSwitch(service)
        let retained = try service.beginSession()
        service.cancelPreparation()
        do { try await leasedCancellation.value; throw CheckFailure(message: "An old-model lease prevented candidate cancellation") }
        catch is CancellationError { }
        _ = try await service.readyEngine(for: retained)
        try expect(service.state == .ready && service.activeSessionCount == 1, "Candidate cancellation disturbed an active old-model session")
        service.endSession(retained)

        try service.selectLanguage("auto")
        try await service.selectModel(id: SpeechModelCatalog.senseVoice.id)
        let batchOnly = try service.beginSession()
        try expect(batchOnly.options.language == nil && !batchOnly.livePreview && service.preferredLanguage == "auto", "Batch model lost automatic recognition or invented preview")
        service.endSession(batchOnly)
        let relaunched = SpeechModelService(defaults: defaults, makeRuntime: factory)
        try expect(relaunched.selectedModel.id == SpeechModelCatalog.senseVoice.id && relaunched.recognitionOptions.language == nil, "Restart ignored selected backend")
        await relaunched.shutdown()
        defaults.set("cohere-transcribe", forKey: "speechModelID")
        let excluded = SpeechModelService(defaults: defaults, makeRuntime: factory)
        try expect(excluded.selectedModel == SpeechModelCatalog.defaultModel
                   && defaults.string(forKey: "speechModelID") == SpeechModelCatalog.defaultModel.id,
                   "An excluded saved model did not recover to the default")
        await excluded.shutdown()
        let shutdownSwitch = Task { try await service.selectModel(id: SpeechModelCatalog.whisperTiny.id) }
        try await waitForSwitch(service)
        await service.shutdown()
        _ = try? await shutdownSwitch.value
        try expect(service.state == .stopped && !service.isPreparing, "Shutdown left candidate work or restored a running service")

        for model in SpeechModelCatalog.supported {
            let manifest = SpeechModelAssets.manifest(for: model.id)
            try expect(model.downloadBytes > 0 && Set(manifest.files.map(\.destination)).count == manifest.files.count, "Catalog contains empty or overlapping assets")
            try expect(manifest.files.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.size >= 0 }, "Catalog has mutable or unverified assets")
            try expect(Set(model.capabilities.languageCodes).count == model.capabilities.languageCodes.count, "Duplicate catalog languages")
            if model.kind == .parakeet {
                let components = Set(manifest.files.map { $0.destination.split(separator: "/").first.map(String.init)! })
                let version = ParakeetSpeechEngine.version(for: model)
                let required = version.hasFusedEncoder ? ModelNames.ASR.requiredModelsFused : ModelNames.ASR.requiredModelsV3(precision: .int8)
                try expect(required.isSubset(of: components), "Pinned assets do not match the loaded encoder precision")
            }
        }
        try expect(SpeechModelCatalog.whisperTiny.capabilities.options(for: "nb-NO").language == "no", "Norwegian alias was lost")
        try expect(SpeechModelCatalog.whisperTiny.capabilities.options(for: "fil").language == "tl", "Filipino alias was lost")
        print("PASS actual backend switching, rollback, cancellation, shutdown, immutable language leases, aliases and pinned catalog")
    }

    @MainActor private static func waitForSwitch(_ service: SpeechModelService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.pendingModel == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try expect(service.pendingModel != nil, "Switch did not start")
    }

    private static func integrity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-assets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("fixture".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = SpeechModelAsset(repository: "test/speech", revision: String(repeating: "a", count: 40),
                                     path: "model.bin", destination: "model.bin", size: Int64(data.count), sha256: digest)
        let manifest = SpeechModelManifest(languages: ["en"], files: [asset])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let destination = directory.appendingPathComponent("model.bin")
        DownloadFixtureProtocol.respond { _ in .init(status: 200, body: data) }
        let store = SpeechArtifactCache(directory: directory, manifest: manifest, configuration: configuration)
        try expect(try await store.ensureAvailable(progress: { _ in }) == .installed, "Fresh verified acquisition failed")
        try expect(try Data(contentsOf: destination) == data, "Installed bytes differ from upstream hash")
        DownloadFixtureProtocol.respond { _ in .init(status: 400, body: Data()) }
        let reopened = SpeechArtifactCache(directory: directory, manifest: manifest, configuration: configuration)
        try expect(try await reopened.ensureAvailable(progress: { _ in }) == .cached, "Offline cache needed network")
        try Data("changed".utf8).write(to: destination)
        do {
            _ = try await SpeechArtifactCache(directory: directory, manifest: manifest, configuration: configuration).ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "Same-size cache corruption was accepted")
        } catch SpeechModelStoreError.invalidCache { }
        try await store.remove()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try data.prefix(3).write(to: partial)
        DownloadFixtureProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "Range") == "bytes=3-", "Interrupted transfer did not resume")
            return .init(status: 206, body: data.dropFirst(3), headers: ["Content-Range": "bytes 3-6/7"])
        }
        try await ModelAssetDownload.download(asset, to: destination, configuration: configuration, progress: { _ in })
        try expect(try Data(contentsOf: destination) == data, "Range resume duplicated or lost bytes")
        try FileManager.default.removeItem(at: destination)
        try data.prefix(3).write(to: partial)
        DownloadFixtureProtocol.respond { _ in .init(status: 200, body: data) }
        try await ModelAssetDownload.download(asset, to: destination, configuration: configuration, progress: { _ in })
        try expect(try Data(contentsOf: destination) == data, "Ignored Range did not restart safely")
        try FileManager.default.removeItem(at: destination)
        try data.write(to: partial)
        DownloadFixtureProtocol.respond { _ in .init(status: 400, body: Data()) }
        try await ModelAssetDownload.download(asset, to: destination, configuration: configuration, progress: { _ in })
        try expect(try Data(contentsOf: destination) == data, "Complete partial was not verified locally")
        try FileManager.default.removeItem(at: destination)
        DownloadFixtureProtocol.respond { _ in .init(status: 200, body: Data("changed".utf8)) }
        do {
            try await ModelAssetDownload.download(asset, to: destination, configuration: configuration, progress: { _ in })
            throw CheckFailure(message: "Wrong upstream hash was accepted")
        } catch ModelAssetDownloadError.invalidDigest { }
        try expect(!FileManager.default.fileExists(atPath: partial.path) && !FileManager.default.fileExists(atPath: destination.path), "Corrupt transfer was promoted or retained")
        let stream = Data(repeating: 0x62, count: 262_144)
        let streamDigest = SHA256.hash(data: stream).map { String(format: "%02x", $0) }.joined()
        let streamAsset = SpeechModelAsset(repository: asset.repository, revision: asset.revision, path: asset.path,
                                          destination: asset.destination, size: Int64(stream.count), sha256: streamDigest)
        let streamedPrefix = 65_536
        DownloadFixtureProtocol.respond { _ in .init(status: 200, body: stream.prefix(streamedPrefix), headers: ["Content-Length": "262144"], suspend: true) }
        let cancel = Task { try await ModelAssetDownload.download(streamAsset, to: destination, configuration: configuration, progress: { _ in }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ModelAssetDownload.fileSize(partial) != Int64(streamedPrefix), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        cancel.cancel()
        do { try await cancel.value; throw CheckFailure(message: "Cancelled transfer completed") }
        catch is CancellationError { }
        try expect(try Data(contentsOf: partial) == stream.prefix(streamedPrefix), "Cancellation discarded received bytes")
        DownloadFixtureProtocol.respond { _ in .init(status: 206, body: stream.dropFirst(streamedPrefix), headers: ["Content-Range": "bytes 65536-262143/262144"]) }
        try await ModelAssetDownload.download(streamAsset, to: destination, configuration: configuration, progress: { _ in })
        try expect(try Data(contentsOf: destination) == stream, "Cancelled transfer could not resume")
        let outside = root.appendingPathComponent("outside.bin")
        try data.write(to: outside)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        do {
            _ = try await SpeechArtifactCache(directory: directory, manifest: manifest, configuration: configuration).ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "Model cache followed an external symlink")
        } catch SpeechModelStoreError.invalidDirectory { }
        let unsafe = SpeechModelAsset(repository: asset.repository, revision: asset.revision, path: asset.path,
                                      destination: "../outside.bin", size: asset.size, sha256: asset.sha256)
        do {
            _ = try await SpeechArtifactCache(directory: directory, manifest: .init(languages: [], files: [unsafe]), configuration: configuration).ensureAvailable(progress: { _ in })
            throw CheckFailure(message: "Manifest escaped the dedicated cache")
        } catch SpeechModelStoreError.invalidDirectory { }
        print("PASS direct download, offline validation, corruption rejection, Range restart/resume, complete partial, cancellation and path boundaries")
    }

    private static func downloadProgress() throws {
        let start = ContinuousClock.now
        var trickle = ModelDownloadProgressWindow(now: start)
        try trickle.record(bytes: 1, at: start.advanced(by: .seconds(119)))
        do {
            try trickle.record(bytes: 1, at: start.advanced(by: .seconds(120)))
            throw CheckFailure(message: "A trickling transfer reset the useful-progress deadline")
        } catch let error as URLError { try expect(error.code == .timedOut, "Slow transfer was not retryable") }
        var healthy = ModelDownloadProgressWindow(now: start)
        try healthy.record(bytes: 1_048_576, at: start.advanced(by: .seconds(120)))
        try healthy.record(bytes: 1, at: start.advanced(by: .seconds(239)))
        do {
            try healthy.record(bytes: 1, at: start.advanced(by: .seconds(240)))
            throw CheckFailure(message: "Earlier useful progress hid a later stalled transfer")
        } catch let error as URLError { try expect(error.code == .timedOut, "Later stall was not retryable") }
        print("PASS trickling download deadline, useful-progress reset and retryable timeout")
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

    private static func realWhisper(hebrewSpeech: URL) async throws {
        let engine = WhisperSpeechEngine(model: SpeechModelCatalog.whisperTiny,
            directory: SpeechRuntimeFactory.directory(for: SpeechModelCatalog.whisperTiny))
        try await engine.prepare()
        for language in ["he", nil] as [String?] {
            let result = try await engine.transcribe(.init(audioFileURL: hebrewSpeech, options: .init(language: language)))
            try expect(result.text.range(of: "[\\u0590-\\u05FF]", options: .regularExpression) != nil,
                       "Hebrew speech did not produce Hebrew in \(language ?? "auto") mode")
            try expect(!result.text.contains("[BLANK_AUDIO]"), "Non-speech annotation escaped model suppression")
        }
        let silence = try await engine.transcribe(samples: [Float](repeating: 0, count: 32_000), options: .init(language: "he"))
        try expect(silence.text.isEmpty && silence.speechPresence == .notDetected, "Silent input generated text")
        if let index = CommandLine.arguments.firstIndex(of: "--short-speech"), CommandLine.arguments.count > index + 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let samples = try AudioConverter().resampleAudioFile(file)
            try expect(!samples.isEmpty && samples.count <= 16_000, "Short-speech fixture exceeds one second")
            let pcm = try await engine.transcribe(samples: samples, options: .init(language: "en"))
            let recorded = try await engine.transcribe(.init(audioFileURL: file, options: .init(language: "en")))
            guard case .detected = pcm.speechPresence else { throw CheckFailure(message: "Short fixture contains no detected speech") }
            try expect(!pcm.text.isEmpty && !recorded.text.isEmpty,
                       "Short speech-positive PCM or file skipped decoding")
            print("PASS real Whisper short speech on PCM and file paths (\(samples.count) samples)")
        }
        await engine.unload()
        try await engine.prepare()
        let reloaded = try await engine.transcribe(.init(audioFileURL: hebrewSpeech, options: .init(language: "he")))
        try expect(reloaded.text.range(of: "[\\u0590-\\u05FF]", options: .regularExpression) != nil,
                   "Unload/reload lost multilingual decoding")
        await engine.unload()
        print("PASS real Whisper Tiny Hebrew, automatic detection, silence and local unload/reload")
    }

    private static func whisperSuppression() throws {
        for endToken in [50256, 50257] {
            let config = try JSONDecoder().decode(WhisperGenerationConfiguration.self,
                from: Data("{\"suppress_tokens\":[58,59,90,91],\"begin_suppress_tokens\":[220,\(endToken)]}".utf8))
            let options = try config.decodingOptions(vocabularySize: 51865)
            try expect(!options.suppressBlank && options.suppressTokens == [58, 59, 90, 91] && options.skipSpecialTokens,
                       "Published non-speech suppression was lost or inferred whitespace suppression was used")
            let sampleBegin = endToken == 50256 ? 2 : 4
            let filter = WhisperBeginSuppressionFilter(tokens: config.beginSuppressTokens, sampleBegin: sampleBegin)
            let logits = try MLMultiArray(shape: [1, 1, 51865], dataType: .float16)
            logits[220] = 1; logits[endToken] = 1; logits[100] = 1
            _ = filter.filterLogits(logits, withTokens: [Int](repeating: 0, count: sampleBegin))
            try expect(logits[220].floatValue == -.infinity && logits[endToken].floatValue == -.infinity
                       && logits[100].floatValue == 1, "First-token filter suppressed the wrong published IDs")
            logits[220] = 1; logits[endToken] = 1
            _ = filter.filterLogits(logits, withTokens: [Int](repeating: 0, count: sampleBegin + 1))
            try expect(logits[220].floatValue == 1 && logits[endToken].floatValue == 1,
                       "First-token suppression prevented later spaces or end-of-text")
        }
        for json in ["{\"suppress_tokens\":[-1],\"begin_suppress_tokens\":[]}",
                     "{\"suppress_tokens\":[51865],\"begin_suppress_tokens\":[]}",
                     "{\"suppress_tokens\":[],\"begin_suppress_tokens\":[51865]}"] {
            let config = try JSONDecoder().decode(WhisperGenerationConfiguration.self, from: Data(json.utf8))
            do {
                _ = try config.decodingOptions(vocabularySize: 51865)
                throw CheckFailure(message: "Invalid suppression configuration reached decoding")
            } catch SpeechModelStoreError.invalidCache { }
        }
        print("PASS Whisper published suppression, English/multilingual first-token mapping and invalid-token rejection")
    }

    @MainActor private static func dictionaryCapacity() throws {
        // Character tokens make the exact boundary, separator cost and whole-entry behavior explicit.
        let encode: (String) -> [Int] = { $0.utf8.map(Int.init) }
        let empty = try WhisperDictionary.prompt(terms: [], encode: encode)
        try expect(empty.tokens.isEmpty && empty.usage.excluded.isEmpty, "Empty dictionary generated a prompt")
        let first = "A" + String(repeating: "x", count: WhisperDictionary.tokenLimit - 2)
        let boundary = try WhisperDictionary.prompt(terms: [first, "Z"], encode: encode)
        try expect(boundary.tokens.count == WhisperDictionary.tokenLimit && boundary.usage.included == [first]
                   && boundary.usage.excluded == ["Z"], "Exact-fit entry or separator boundary was truncated")
        let oversized = "A" + String(repeating: "x", count: WhisperDictionary.tokenLimit)
        let rejected = try WhisperDictionary.prompt(terms: [oversized, "Z"], encode: encode)
        try expect(rejected.tokens.isEmpty && rejected.usage.excluded == [oversized, "Z"],
                   "Oversized first entry was split or later terms silently jumped the cutoff")
        let ordered = try WhisperDictionary.prompt(terms: ["Zoo", "Beta", "alpha"], encode: encode)
        try expect(ordered.usage.included == ["Zoo", "Beta", "alpha"] && ordered.tokens == encode(" Zoo, Beta, alpha"),
                   "Dictionary prompt reordered the priority order it was given")
        // One-character terms fit the token limit, so only the active limit cuts the last one.
        let many = Array("abcdefghijklmnopqrstuvwxyz0123456789".prefix(DictionaryScope.activeLimit + 1)).map(String.init)
        let capped = try WhisperDictionary.prompt(terms: many, encode: encode)
        try expect(capped.usage.included == Array(many.dropLast()) && capped.usage.excluded == [many.last!],
                   "Dictionary prompt sent more terms than the active limit")
        let legacy = try JSONDecoder().decode(RecognitionOptions.self, from: Data("{\"language\":\"en\"}".utf8))
        try expect(legacy == .init(language: "en"), "Old recognition options no longer decode")
        // Options saved while Parakeet's dictionary correction existed carry a key that is now ignored.
        let corrected = try JSONDecoder().decode(RecognitionOptions.self,
            from: Data(#"{"language":"en","vocabulary":["Kalikin"],"dictionaryCorrection":true}"#.utf8))
        try expect(corrected == .init(language: "en", vocabulary: ["Kalikin"]), "Options saved with dictionary correction no longer decode")
        for model in SpeechModelCatalog.supported {
            try expect(model.capabilities.customVocabulary == (model.kind == .whisper), "Native dictionary capability routed to another backend")
        }
        for (word, known) in [("lunch", true), ("manages", true), ("Monday", true), ("lunch,", true), ("Kalican", false), ("postgas", false)] {
            try expect(TermSuggestions.isKnownEnglishWord(word) == known, "Spell checker disagrees about \(word)")
        }
        for type in [MLMultiArrayDataType.float16, .float32, .double] {
            let original = try MLMultiArray(shape: [8, 4], dataType: type)
            for index in 0..<32 { original[index] = NSNumber(value: index) }
            let shifted = try WhisperDictionarySegmentSeeker.alignmentView(original, dropping: 3)
            try expect(shifted.shape == [5, 4] && shifted[0].intValue == 12 && shifted[19].intValue == 31,
                       "Alignment prefix removal reads the wrong rows")
            original[12] = 99
            try expect(shifted[0].intValue == 99, "Alignment view unexpectedly copied its cache")
        }
        print("PASS dictionary whole-entry capacity, stable order, legacy options, backend gating and alignment strides")
    }

    /// Only Whisper's decoder takes preferred spellings; every other model leaves terms to aliases and Cleanup.
    @MainActor private static func dictionaryRouting() async throws {
        let suite = "app.goblin.dictionary-routing-check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engines = Dictionary(uniqueKeysWithValues: SpeechModelCatalog.supported.map { ($0.id, CheckEngine($0.id)) })
        let service = SpeechModelService(defaults: defaults, makeRuntime: {
            SpeechModelRuntime(engine: engines[$0.id]!, store: CheckStore())
        })
        service.preload()
        try await settle(service)
        for model in [SpeechModelCatalog.parakeet, SpeechModelCatalog.whisperTiny, SpeechModelCatalog.parakeetUltra, SpeechModelCatalog.parakeetCompact] {
            if service.selectedModel.id != model.id { try await service.selectModel(id: model.id) }
            let lease = try service.beginSession(vocabulary: ["Kalikin"])
            try expect(lease.options.vocabulary == (model.capabilities.customVocabulary ? ["Kalikin"] : []),
                       "\(model.name) received the wrong recognition terms")
            service.endSession(lease)
        }
        await service.shutdown()
        print("PASS dictionary terms reach recognition through Whisper's prompt only")
    }

    private static func realDictionary(directory: URL, audio: URL) async throws {
        let model: SpeechModelDescriptor
        if let index = CommandLine.arguments.firstIndex(of: "--model"), CommandLine.arguments.count > index + 1,
           let selected = SpeechModelCatalog.model(id: CommandLine.arguments[index + 1]) { model = selected }
        else { model = SpeechModelCatalog.whisperTurbo }
        let engine = WhisperSpeechEngine(model: model, directory: directory)
        try await engine.prepare()
        let samples = try AudioConverter().resampleAudioFile(audio)
        let terms = ["CodeRabbit", "Postgres", "Kalikin"]
        let options = RecognitionOptions(language: "en", vocabulary: terms)
        let preview = try await WhisperSpeechEngine.dictionaryUsage(terms: terms, model: model, directory: directory)
        let file = try await engine.transcribe(.init(audioFileURL: audio, options: options))
        let pcm = try await engine.transcribe(samples: samples, options: options)
        for result in [file, pcm] {
            try expect(!result.text.isEmpty && !result.tokens.isEmpty, "Dictionary prompting discarded recognized speech or word timing")
            try expect(result.dictionaryUsage == preview, "Recognition and Dictionary settings disagree about included terms")
            try expect(result.tokens.allSatisfy { $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.startSeconds >= 0
                && $0.endSeconds > $0.startSeconds && $0.endSeconds <= Double(samples.count) / 16_000 + 0.1 },
                "Prompted recognition returned invalid word timing")
        }
        let clean = try await engine.transcribe(samples: samples, options: .init(language: "en"))
        try expect(clean.dictionaryUsage?.included.isEmpty == true && !clean.text.isEmpty && !clean.tokens.isEmpty,
                   "A previous session's dictionary leaked into an empty-dictionary session")
        let silence = try await engine.transcribe(samples: [Float](repeating: 0, count: 16_000), options: options)
        try expect(silence.text.isEmpty && silence.dictionaryUsage == preview, "Dictionary produced words from silence")
        let automatic = try await engine.transcribe(samples: samples, options: .init(vocabulary: terms))
        try expect(!automatic.text.isEmpty && !automatic.tokens.isEmpty && automatic.dictionaryUsage == preview,
                   "Automatic language detection lost the dictionary or its word alignment")
        let live = LiveTranscriber(engine: Task<any PCMSpeechEngine, Error> { engine }, options: options)
        await live.append(samples, at: 0)
        let finished = try await live.finish()
        try expect(finished?.text.isEmpty == false, "Prompted live recognition required recovery or discarded its final text")
        if let index = CommandLine.arguments.firstIndex(of: "--long-file"), CommandLine.arguments.count > index + 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let result = try await engine.transcribe(.init(audioFileURL: file, options: options))
            try expect(result.tokens.last?.endSeconds ?? 0 > 30 && result.text.lowercased().contains("order to the store"),
                       "Missing final-window speech or timing (last word: \(result.tokens.last?.endSeconds ?? 0)s; ending: \(result.text.suffix(90)))")
            print("PASS prompted long-file word timing through \(result.tokens.last!.endSeconds) seconds and final-window speech")
        }
        print("PASS real prompted Whisper file/PCM word timing, shared tokenizer preview, request isolation and silence; \(file.text)")
        await engine.unload()
    }

    private static func tokenizerBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-tokenizer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rejected = false
        do { _ = try await WhisperSpeechEngine.validateLocalTokenizer(model: SpeechModelCatalog.whisperTiny, directory: directory) }
        catch { rejected = true }
        try expect(rejected, "Missing tokenizer was allowed to enter the SDK network fallback")
        let conflicting = directory.appendingPathComponent("models/openai/whisper-tiny")
        try FileManager.default.createDirectory(at: conflicting, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: conflicting.appendingPathComponent("tokenizer.json"))
        do {
            _ = try await WhisperSpeechEngine.validateLocalTokenizer(model: SpeechModelCatalog.whisperTiny, directory: directory)
            throw CheckFailure(message: "A stale Hub tokenizer overrode the pinned local tokenizer")
        } catch SpeechModelStoreError.invalidCache { }
        print("PASS local tokenizer preflight and stale Hub-cache rejection")
    }

    private static func expandedCatalog() async throws {
        let all = SpeechModelCatalog.supported
        try expect(all.count == 17 && Set(all.map(\.id)).count == 17, "Expanded catalog contains missing or duplicate models")
        try expect(SpeechModelCatalog.recommended.count == 4, "Recommendation shortlist expanded with the full catalog")
        let japanese = SpeechModelCatalog.matching(language: "ja-JP", livePreviewOnly: true)
        try expect(japanese.contains(SpeechModelCatalog.nemotron) && !japanese.contains(SpeechModelCatalog.senseVoice)
                   && !japanese.contains(SpeechModelCatalog.whisperTinyEnglish), "Language/preview filters admit incompatible models")
        let englishTiny = SpeechModelCatalog.matching(query: "tiny english-only", language: "en")
        try expect(englishTiny == [SpeechModelCatalog.whisperTinyEnglish], "Catalog search lost the English-only choice")
        try expect(SpeechModelCatalog.matching(query: "does-not-exist").isEmpty, "Catalog search hides its empty result")
        try expect(SpeechModelCatalog.matching(recommendedOnly: true) == SpeechModelCatalog.recommended, "Recommendation filtering changes order or membership")
        for model in all {
            let directory = URL(fileURLWithPath: "/tmp/missing-expanded-model-\(UUID())/\(model.cacheFolder)")
            let runtime = SpeechRuntimeFactory.make(model, directory: directory)
            try expect(runtime.engine.identifier == model.id, "Catalog selection uses the wrong inference adapter")
            do { try await runtime.engine.prepare(); throw CheckFailure(message: "Missing model entered inference or acquisition") }
            catch SpeechRuntimeError.modelNotInstalled { }
            if model.capabilities.languageControl == .fixed {
                try expect(model.capabilities.options(for: "ja").language == "en" && !model.capabilities.automaticLanguage,
                           "A fixed English model advertises automatic detection or changes language")
                try expect(RecognitionOptions().validatedLanguage(for: model) == "en", "A monolingual default requires manual language setup")
            }
            if model.kind == .whisper {
                let variant = WhisperSpeechEngine.variant(for: model)
                let repository = SpeechModelAssets.manifest(for: model.id).files.first { $0.destination == "tokenizer.json" }!.repository
                try expect(repository == "openai/whisper-\(variant.description)", "Whisper uses another size's tokenizer")
            }
        }
        try expect(ParakeetSpeechEngine.version(for: SpeechModelCatalog.parakeetCompact).decoderLayers == 1,
                   "Compact transducer uses the larger model's decoder state")
        let indices = try [nil, "zh", "en", "yue", "ja", "ko"].map { try SenseVoiceSpeechEngine.languageIndex($0) }
        try expect(indices == [0, 3, 4, 7, 11, 12], "SenseVoice hints use token IDs instead of query indices")
        let dictionary = ["en": 0, "ja-JP": 10, "zh-CN": 4, "no": 27, "nb-NO": 103]
        try expect(NemotronSpeechEngine.promptLanguage("ja", dictionary: dictionary) == "ja-JP", "Bare language silently falls back to automatic Nemotron recognition")
        try expect(NemotronSpeechEngine.promptLanguage("no", dictionary: dictionary) == "nb-NO", "Bokmål uses an unsupported generic Norwegian prompt")
        do { _ = try NemotronSpeechEngine.promptLanguage("ko", dictionary: dictionary); throw CheckFailure(message: "A missing language prompt was ignored") }
        catch SpeechRuntimeError.unsupportedLanguage { }
        try expect(!SpeechModelCatalog.nemotron.capabilities.languageCodes.contains("th"), "Adaptation-only language is offered without trained weights")
        let windows = Mutex<[(Int, Float?)]>([])
        var samples = [Float](repeating: 0.1, count: 1_040_000)
        samples[samples.count - 1] = 0.2
        let transcript = try await SenseVoiceSpeechEngine.decodeWindows(samples) { audio in
            windows.withLock { $0.append((audio.count, audio.last)) }
            return "重复完整句子测试文本"
        }
        try expect(windows.withLock { $0.count == 3 && $0.allSatisfy { $0.0 <= 480_000 } && $0.last?.1 == 0.2 },
                   "SenseVoice long-file windows truncate the recording's tail")
        try expect(transcript == "重复完整句子测试文本 重复完整句子测试文本 重复完整句子测试文本", "Whole repeated hypotheses were erased")
        try expect(SenseVoiceSpeechEngine.merge("开头这些中文字符用于确认接缝", "这些中文字符用于确认接缝然后是结尾", overlapping: true)
                   == "开头这些中文字符用于确认接缝然后是结尾", "CJK overlap failed without whitespace word boundaries")
        try expect(SenseVoiceSpeechEngine.merge("hello repeated phrase", "hello repeated phrase", overlapping: false)
                   == "hello repeated phrase hello repeated phrase", "Repetition after silence was erased")
        print("PASS expanded recommendations/search, factory routing, fixed languages, tokenizer variants, decoder shapes, hints and long-file tails")
    }

    @MainActor private static func captureDictionary(to directory: URL, modelDirectory: URL) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "app.goblin.dictionary-layout.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CheckStore(directory: modelDirectory)
        let service = SpeechModelService(defaults: defaults, makeRuntime: { model in
            SpeechModelRuntime(engine: CheckEngine(model.id), store: store)
        })
        let repository = DictionaryRepository(url: scratch.appendingPathComponent("dictionary.json"))
        try repository.save([DictionaryEntry(spelling: "CodeRabbit", aliases: ["code rabbit"]),
                             DictionaryEntry(spelling: "Postgres"), DictionaryEntry(spelling: "Kalikin")])
        let model = DictionaryModel(repository: repository, defaults: defaults)
        @MainActor func shoot(_ name: String, dark: Bool, accessible: Bool = false, height: CGFloat = 700, place: DictionaryPlace = .everywhere) async throws {
            app.appearance = NSAppearance(named: accessible
                ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (dark ? .darkAqua : .aqua))
            let host = NSHostingView(rootView: Form { DictionarySettingsView(model: model, service: service, defaults: defaults, place: place) }
                .formStyle(PlateFormStyle()).preferredColorScheme(dark ? .dark : .light)
                .defaultScrollAnchor(.top)
                .environment(\._colorSchemeContrast, accessible ? .increased : .standard)
                .environment(\._accessibilityReduceMotion, accessible)
                .frame(width: 650, height: height, alignment: .topLeading).caseBackground())
            host.appearance = app.appearance
            host.frame = NSRect(x: 0, y: 0, width: 650, height: height)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            try snapshot(host, to: directory.appendingPathComponent(name + ".png"))
            print("Captured \(name)")
        }
        for dark in [false, true] { try await shoot("dictionary-parakeet-\(dark ? "dark" : "light")", dark: dark) }
        try await service.selectModel(id: SpeechModelCatalog.parakeetCompact.id)
        for dark in [false, true] { try await shoot("dictionary-unsupported-\(dark ? "dark" : "light")", dark: dark) }
        try await service.selectModel(id: SpeechModelCatalog.whisperTurbo.id)
        for dark in [false, true] { try await shoot("dictionary-supported-\(dark ? "dark" : "light")", dark: dark) }
        try expect(model.put(DictionaryEntry(spelling: "PostHog", aliases: ["post hog"], apps: ["com.apple.Terminal", "com.apple.TextEdit"])),
                   "Could not create app-scoped fixture")
        for dark in [false, true] { try await shoot("dictionary-scoped-\(dark ? "dark" : "light")", dark: dark, height: 900) }
        let scopeHost = NSHostingView(rootView: Form { DictionaryAppScopeEditor(apps: .constant(["com.apple.Terminal", "com.apple.TextEdit"])) }
            .formStyle(.grouped).frame(width: 460, height: 260))
        scopeHost.frame = NSRect(x: 0, y: 0, width: 460, height: 260)
        scopeHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(scopeHost, to: directory.appendingPathComponent("dictionary-entry-apps.png"))
        try expect(model.put(DictionaryEntry(spelling: "GPT 6.1 Sol", aliases: ["GPT six point one soul"],
                                             apps: ["com.apple.Terminal"], projects: ["gob.lin"])), "Could not create project-scoped fixture")
        model.lastContext = ("Terminal", "com.apple.Terminal", DetectedProject(name: "gob.lin", source: .repository))
        for dark in [false, true] {
            try await shoot("dictionary-projects-\(dark ? "dark" : "light")", dark: dark, height: 1000, place: .project("gob.lin", app: "com.apple.Terminal"))
        }
        let projectHost = NSHostingView(rootView: Form { DictionaryProjectScopeEditor(projects: .constant(["gob.lin"]), suggestions: ["gob.lin", "harbor"]) }
            .formStyle(.grouped).frame(width: 460, height: 220))
        projectHost.frame = NSRect(x: 0, y: 0, width: 460, height: 220)
        projectHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(projectHost, to: directory.appendingPathComponent("dictionary-entry-projects.png"))
        let fixtureRepository = scratch.appendingPathComponent("gob.lin")
        try FileManager.default.createDirectory(at: fixtureRepository.appendingPathComponent("GoblinCore"), withIntermediateDirectories: true)
        try #"let package = Package(name: "Goblin")"#.write(to: fixtureRepository.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        model.offerTerms(from: DetectedProject(name: "gob.lin", source: .repository, root: fixtureRepository))
        model.offerCorrection(dictated: "ship the go blin build", edited: "ship the gob.lin build", scope: DictionaryScope(application: "com.apple.Terminal", project: "gob.lin"))
        for _ in 0..<50 where model.suggestions.count < 3 { try await Task.sleep(for: .milliseconds(100)) }
        try expect(model.suggestions.map(\.spelling) == ["gob.lin", "PostHog", "GoblinCore"], "Unexpected suggestions: \(model.suggestions.map(\.spelling))")
        for dark in [false, true] { try await shoot("dictionary-suggestions-\(dark ? "dark" : "light")", dark: dark, height: 1300) }
        model.dismiss(model.suggestions[2])
        try expect(model.suggestions.count == 2 && defaults.stringArray(forKey: DictionaryModel.dismissedSuggestionsKey)?.count == 1, "Dismissal didn't stick")
        model.accept(model.suggestions[0])
        try expect(model.entries.last.map { ($0.spelling, $0.aliases, $0.projects) } ?? ("", [], []) == ("gob.lin", ["go blin"], ["gob.lin"]),
                   "Accepting didn't add the project term")
        model.suggestsTerms = false
        try expect(model.suggestions.isEmpty, "Turning suggestions off left the card")
        model.lastContext = nil
        var settings = RewriteSettings()
        settings.enabled = true
        settings.cleanup = .light
        try RewriteSettingsStore.save(settings, defaults: defaults)
        for entry in model.entries { model.delete(entry) }
        for number in 1...32 { try expect(model.put(DictionaryEntry(spelling: String(format: "Project %03d", number))), "Could not create cutoff fixture") }
        let usage = try await WhisperSpeechEngine.dictionaryUsage(terms: model.entries.map(\.spelling), model: service.selectedModel, directory: modelDirectory)
        try expect(!usage.included.isEmpty && !usage.excluded.isEmpty, "Capture fixture doesn't exercise a cutoff")
        for dark in [false, true] {
            try await shoot("dictionary-cutoff-\(dark ? "dark" : "light")", dark: dark, height: 2000)
            try await shoot("dictionary-accessible-\(dark ? "dark" : "light")", dark: dark, accessible: true, height: 2000)
        }
        for entry in model.entries { model.delete(entry) }
        // A dictionary big enough to scroll, across every kind of place.
        for number in 1...40 { try expect(model.put(DictionaryEntry(spelling: String(format: "Word%03d", number))), "Could not create everywhere fixture") }
        for number in 1...8 { try expect(model.put(DictionaryEntry(spelling: "AppTerm\(number)", apps: ["com.apple.Terminal"])), "Could not create app fixture") }
        for number in 1...40 {
            let aliases = number % 5 == 0 ? ["project word \(number)", "prodject \(number)", "pro term \(number)"] : []
            try expect(model.put(DictionaryEntry(spelling: "ProjectTerm\(number)", aliases: aliases, projects: ["gob.lin"])), "Could not create project fixture")
        }
        for number in 1...12 { try expect(model.put(DictionaryEntry(spelling: "EvalTerm\(number)", projects: ["evals"])), "Could not create unassigned fixture") }
        model.lastContext = ("Terminal", "com.apple.Terminal", DetectedProject(name: "gob.lin", source: .repository))
        for dark in [false, true] {
            try await shoot("dictionary-browser-\(dark ? "dark" : "light")", dark: dark, height: 1000, place: .project("gob.lin", app: "com.apple.Terminal"))
        }
        try await shoot("dictionary-browser-accessible", dark: false, accessible: true, height: 1000)
        let words = DictionaryPlace.project("gob.lin", app: "com.apple.Terminal").activeWords(in: model.entries)
        try expect(words.used.count == DictionaryScope.activeLimit && words.missed.count == 56, "Unexpected active words: \(words.used.count), \(words.missed.count)")
        app.appearance = NSAppearance(named: .aqua)
        let activeHost = NSHostingView(rootView: DictionaryActiveWords(used: words.used, missed: words.missed) {
            $0.projects.isEmpty ? ($0.apps.isEmpty ? "Everywhere" : "Terminal") : "gob.lin"
        }.background(GoblinBrand.plate).frame(width: 320, height: 420))
        activeHost.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        activeHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(activeHost, to: directory.appendingPathComponent("dictionary-active-words.png"))
        model.lastContext = nil
        for entry in model.entries { model.delete(entry) }
        try await shoot("dictionary-empty", dark: false)
        await service.shutdown()
        print("PASS production Dictionary views rendered offscreen in light, dark, high contrast and reduced motion; no app launch or microphone")
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
            let store = CheckStore(delay: .milliseconds(800))
            await store.failOnce()
            service = SpeechModelService(defaults: defaults, makeRuntime: { model in
                SpeechModelRuntime(engine: CheckEngine(model.id), store: store)
            })
        }
        defer { ModelHub.offlineMode = false }
        @MainActor func shoot(_ name: String, _ view: some View, width: CGFloat = 650, height: CGFloat = 980,
                              dark: Bool = false, accessible: Bool = false) async throws {
            app.appearance = NSAppearance(named: accessible
                ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (dark ? .darkAqua : .aqua))
            let host = NSHostingView(rootView: view
                .preferredColorScheme(dark ? .dark : .light)
                .frame(width: width, height: height, alignment: .topLeading).caseBackground())
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(for: .milliseconds(30))
            try snapshot(host, to: directory.appendingPathComponent(name + ".png"))
            print("Captured \(name)")
        }
        @MainActor func page(_ all: Bool = false, query: String = "", language: String = "all") -> some View {
            Form { ModelSettingsView(service: service, showAllModels: all, search: query, languageFilter: language) }
                .formStyle(PlateFormStyle())
        }
        service.preload()
        try await shoot("model-preparation-layout", page(), dark: true)
        if real {
            preparation: for await state in service.$state.values {
                switch state {
                case .ready: break preparation
                case .failed(let error): throw CheckFailure(message: error)
                default: break
                }
            }
        } else {
            try await settle(service)
            try await shoot("model-failure-layout", page(), dark: true)
            service.retry()
            try await settle(service)
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await shoot("model-ready-" + suffix, page(), dark: dark)
            try await shoot("model-all-" + suffix, page(true), dark: dark)
            try await shoot("model-hebrew-" + suffix, page(language: "he"), dark: dark)
            try await shoot("model-empty-" + suffix, page(query: "sensevoice"), dark: dark)
            try await shoot("model-languages-" + suffix, ModelLanguagesPopover(model: SpeechModelCatalog.parakeet),
                            width: 320, height: 330, dark: dark)
            try await shoot("model-accessible-" + suffix, page(), dark: dark, accessible: true)
        }
        try await shoot("model-narrow", page(), width: 564, dark: true)
        if !real {
            let switching = Task { try await service.selectModel(id: SpeechModelCatalog.whisperTurbo.id) }
            while service.pendingModel == nil { await Task.yield() }
            try await shoot("model-switch-layout", page(), dark: true)
            try await shoot("model-pending-filter-layout", page(language: "zh"), dark: true)
            service.cancelPreparation()
            do { try await switching.value; throw CheckFailure(message: "Captured switch ignored cancellation") }
            catch is CancellationError { }
            try await shoot("model-cancelled-switch-layout", page(), dark: true)
        }
        await service.shutdown()
        print("Captured production plates/popover in light, dark and high-contrast appearances; isolated defaults, no app launch, microphone or permissions")
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
