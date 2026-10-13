import CryptoKit
import FluidAudio
import Foundation
import GoblinCore

public enum SpeechModelStoreError: Error, LocalizedError {
    case invalidDirectory, busy, invalidCache

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "The model cache must use its dedicated model folder."
        case .busy: "A model installation is already running."
        case .invalidCache: "The cached model failed its integrity check. Download it again to repair it."
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

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        progress(.init(phase: .downloading))
        // Use download-only SDK APIs so installation never creates a second runtime loader.
        try await ModelHub.download(.parakeetV3, to: directory.deletingLastPathComponent(), variant: "int8",
                                    additionalModelNames: [ModelNames.ASR.vocabularyFile],
                                    progressHandler: { update in
            switch update.phase {
            case .listing: progress(.init(phase: .downloading, component: "Finding model files"))
            case .downloading(let complete, let total):
                // ModelHub reserves its upper half for compilation, which this API never performs.
                progress(.init(phase: .downloading, fractionCompleted: update.fractionCompleted * 2,
                               component: "\(complete) of \(total) files"))
            case .compiling(let name): progress(.init(phase: .compiling, component: name))
            }
        })
        try Task.checkCancellation()
        progress(.init(phase: .checkingCache, component: "Verifying installed files"))
        let inventory = try Inventory.capture(at: directory, required: Self.required)
        try JSONEncoder().encode(inventory).write(to: inventoryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inventoryURL.path)
        validated = true
        return .installed
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
