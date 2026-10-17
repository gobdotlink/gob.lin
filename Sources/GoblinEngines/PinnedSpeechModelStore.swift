import CryptoKit
import Foundation

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

/// Installs reviewed upstream bytes; runtime loading never owns acquisition.
public actor PinnedSpeechModelStore: SpeechModelAcquiring {
    public nonisolated let directory: URL
    private let cache: SpeechArtifactCache
    private let detector: SpeechArtifactCache
    private var acquiring = false
    private let cacheFolder: String

    public init(model: SpeechModelDescriptor, directory: URL) {
        self.directory = directory.standardizedFileURL
        cacheFolder = model.cacheFolder
        cache = SpeechArtifactCache(directory: directory, manifest: SpeechModelAssets.manifest(for: model.id))
        detector = SpeechArtifactCache(directory: directory.deletingLastPathComponent()
            .appendingPathComponent(SpeechActivityDetector.cacheFolder, isDirectory: true),
            manifest: SpeechModelAssets.manifest(for: "speech-detector"))
    }

    public func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        guard !acquiring else { throw SpeechModelStoreError.busy }
        guard directory.lastPathComponent == cacheFolder else { throw SpeechModelStoreError.invalidDirectory }
        acquiring = true
        defer { acquiring = false }
        let modelUse = try await cache.ensureAvailable(progress: progress)
        let detectorUse = try await detector.ensureAvailable { update in
            progress(.init(phase: update.phase, fractionCompleted: update.fractionCompleted, component: "Speech detection"))
        }
        return modelUse == .installed || detectorUse == .installed ? .installed : .cached
    }

    public func removeCachedModel() async throws {
        guard !acquiring else { throw SpeechModelStoreError.busy }
        guard directory.lastPathComponent == cacheFolder else { throw SpeechModelStoreError.invalidDirectory }
        acquiring = true
        defer { acquiring = false }
        try await cache.remove()
        try await detector.remove()
    }

    public nonisolated static func isDownloaded(model: SpeechModelDescriptor, directory: URL) -> Bool {
        SpeechModelAssets.manifest(for: model.id).files.allSatisfy {
            let url = directory.appendingPathComponent($0.destination)
            return FileManager.default.isReadableFile(atPath: url.path)
                && (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.size)
        }
    }
}

actor SpeechArtifactCache {
    let directory: URL
    private let manifest: SpeechModelManifest
    private let configuration: URLSessionConfiguration
    private var validated = false
    private var acquiring = false

    init(directory: URL, manifest: SpeechModelManifest, configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory.standardizedFileURL
        self.manifest = manifest
        self.configuration = configuration
    }

    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        guard !acquiring else { throw SpeechModelStoreError.busy }
        acquiring = true
        defer { acquiring = false }
        try Task.checkCancellation()
        guard directory.isFileURL, !manifest.files.isEmpty else { throw SpeechModelStoreError.invalidDirectory }
        progress(.init(phase: .checkingCache))
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        var complete: Int64 = 0
        var downloaded = false
        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let destination = try safeDestination(file)
            if FileManager.default.fileExists(atPath: destination.path) {
                try verify(file, at: destination, hash: !validated)
            } else {
                validated = false
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let prior = complete
                let component = "Downloading \(index + 1) of \(manifest.files.count) files"
                progress(.init(phase: .downloading, fractionCompleted: total == 0 ? nil : Double(prior) / Double(total), component: component))
                try await ModelAssetDownload.download(file, to: destination, configuration: configuration) { bytes in
                    progress(.init(phase: .downloading, fractionCompleted: total == 0 ? nil : Double(prior + bytes) / Double(total),
                                   component: component))
                }
                try verify(file, at: destination, hash: false)
                downloaded = true
            }
            complete += file.size
        }
        validated = true
        return downloaded ? .installed : .cached
    }

    func remove() throws {
        guard !acquiring else { throw SpeechModelStoreError.busy }
        guard directory.isFileURL, directory.pathComponents.count > 2,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw SpeechModelStoreError.invalidDirectory
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        validated = false
    }

    private func safeDestination(_ file: SpeechModelAsset) throws -> URL {
        let parts = file.destination.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !file.destination.hasPrefix("/"), file.size >= 0,
              file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit),
              file.revision.count == 40, file.revision.allSatisfy(\.isHexDigit) else {
            throw SpeechModelStoreError.invalidDirectory
        }
        let destination = directory.appendingPathComponent(file.destination)
        let root = directory.resolvingSymlinksInPath().path + "/"
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              destination.resolvingSymlinksInPath().path.hasPrefix(root) else { throw SpeechModelStoreError.invalidDirectory }
        return destination
    }

    private func verify(_ file: SpeechModelAsset, at url: URL, hash: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == Int(file.size) else {
            throw SpeechModelStoreError.invalidCache
        }
        if hash, try ModelAssetDownload.digest(url) != file.sha256 { throw SpeechModelStoreError.invalidCache }
    }
}
