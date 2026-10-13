import CryptoKit
import FluidAudio
import Foundation
import GoblinCore
import Synchronization

public enum SpeechModelStoreError: Error, LocalizedError {
    case invalidDirectory, busy, invalidCache, listingStalled

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "The model cache must use its dedicated model folder."
        case .busy: "A model installation is already running."
        case .invalidCache: "The cached model failed its integrity check. Download it again to repair it."
        case .listingStalled: "The model server did not finish listing files within two minutes. Check your connection and retry."
        }
    }
}

/// Owns acquisition only; the speech runtime loads the installed files locally.
public actor ParakeetModelStore: SpeechModelAcquiring {
    public nonisolated let directory: URL
    private var validated = false
    private var acquiring = false
    private static let inventoryName = ".goblin-integrity.json"
    private static let required = ModelNames.ASR.requiredModelsV3(precision: .int8)
        .union([ModelNames.ASR.vocabularyFile])

    public static func defaultDirectory() throws -> URL {
        try HistoryStore.defaultDirectory().appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        guard directory.isFileURL, directory.lastPathComponent == Repo.parakeetV3.folderName else {
            throw SpeechModelStoreError.invalidDirectory
        }
        guard !acquiring else { throw SpeechModelStoreError.busy }
        acquiring = true
        defer { acquiring = false }
        try Task.checkCancellation()
        progress(.init(phase: .checkingCache))
        // Hash once at launch; idle reloads reuse that validation and the OS's compiled cache.
        if validated { return .cached }
        let inventoryURL = directory.appendingPathComponent(Self.inventoryName)
        if FileManager.default.fileExists(atPath: inventoryURL.path) {
            let inventory: Inventory
            do { inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: inventoryURL)) }
            catch { throw SpeechModelStoreError.invalidCache }
            try inventory.verify(at: directory, required: Self.required)
            validated = true
            return .cached
        }

        // Adopt a complete staged SDK cache locally; missing/partial files still enter resumable download.
        if AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8) {
            do {
                let inventory = try Inventory.capture(at: directory, required: Self.required)
                try save(inventory, to: inventoryURL)
                validated = true
                return .cached
            } catch is CancellationError { throw CancellationError() }
            catch SpeechModelStoreError.invalidCache { /* Incomplete SDK cache: resume below. */ }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        progress(.init(phase: .downloading))
        for attempt in 0..<2 {
            do { try await download(progress: progress); break }
            catch SpeechModelStoreError.listingStalled where attempt == 0 {
                progress(.init(phase: .downloading, component: "Retrying model server…"))
                try await Task.sleep(for: .seconds(2))
            }
        }
        try Task.checkCancellation()
        progress(.init(phase: .checkingCache, component: "Verifying installed files"))
        let inventory = try Inventory.capture(at: directory, required: Self.required)
        try save(inventory, to: inventoryURL)
        validated = true
        return .installed
    }

    private func download(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws {
        let directory = directory
        // The SDK guards stalled byte streams; its metadata listing has no progress watchdog.
        try await Self.guardListing { transferStarted in
            // Download-only: compilation never falls under this network watchdog.
            try await ModelHub.download(.parakeetV3, to: directory.deletingLastPathComponent(), variant: "int8",
                                        additionalModelNames: [ModelNames.ASR.vocabularyFile],
                                        progressHandler: { update in
                switch update.phase {
                case .listing: progress(.init(phase: .downloading, component: "Finding model files"))
                case .downloading(let complete, let total):
                    transferStarted()
                    // ModelHub reserves its upper half for compilation, which this API never performs.
                    progress(.init(phase: .downloading, fractionCompleted: update.fractionCompleted * 2,
                                   component: "\(complete) of \(total) files"))
                case .compiling(let name):
                    transferStarted()
                    progress(.init(phase: .compiling, component: name))
                }
            })
        }
    }

    nonisolated static func guardListing(timeout: Duration = .seconds(120),
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> Void
    ) async throws {
        let listing = ListingState()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation { listing.active.withLock { $0 = false } }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if listing.active.withLock({ $0 }) { throw SpeechModelStoreError.listingStalled }
                // Once transfer starts, the SDK owns its retry/resume/stall policy.
                while true { try await Task.sleep(for: .seconds(30)) }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private final class ListingState: Sendable {
        let active = Mutex(true)
    }

    private func save(_ inventory: Inventory, to url: URL) throws {
        try Task.checkCancellation()
        try JSONEncoder().encode(inventory).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Explicit repair is separate from retry so interrupted downloads keep their partial bytes.
    public func removeCachedModel() throws {
        guard !acquiring else { throw SpeechModelStoreError.busy }
        guard directory.isFileURL, directory.lastPathComponent == Repo.parakeetV3.folderName else {
            throw SpeechModelStoreError.invalidDirectory
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        validated = false
    }

    private struct Inventory: Codable {
        struct File: Codable, Equatable {
            let path: String
            let size: Int64
            let sha256: String
        }
        let version: Int
        let modelID: String
        let files: [File]

        static func capture(at directory: URL, required: Set<String>) throws -> Self {
            let fm = FileManager.default
            var entries: [File] = []
            for name in required.sorted() {
                let url = directory.appendingPathComponent(name)
                if name.hasSuffix(".mlmodelc") {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                          fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path),
                          let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                        throw SpeechModelStoreError.invalidCache
                    }
                    for case let file as URL in enumerator {
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isSymbolicLink != true, file.pathExtension != "partial" else { throw SpeechModelStoreError.invalidCache }
                        if values.isRegularFile == true {
                            entries.append(try digest(file, relativeTo: directory))
                        }
                    }
                } else { entries.append(try digest(url, relativeTo: directory)) }
            }
            guard !entries.isEmpty else { throw SpeechModelStoreError.invalidCache }
            return Self(version: 1, modelID: SpeechModelCatalog.parakeet.id, files: entries.sorted { $0.path < $1.path })
        }

        func verify(at directory: URL, required: Set<String>) throws {
            guard version == 1, modelID == SpeechModelCatalog.parakeet.id,
                  self.files == (try Self.capture(at: directory, required: required)).files else {
                throw SpeechModelStoreError.invalidCache
            }
        }

        private static func digest(_ url: URL, relativeTo directory: URL) throws -> File {
            let root = directory.resolvingSymlinksInPath().path + "/"
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root),
                  try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SpeechModelStoreError.invalidCache
            }
            let file = try FileHandle(forReadingFrom: resolved)
            defer { try? file.close() }
            var digest = SHA256()
            var size: Int64 = 0
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                size += Int64(bytes.count)
                digest.update(data: bytes)
            }
            return File(path: String(resolved.path.dropFirst(root.count)), size: size,
                        sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
