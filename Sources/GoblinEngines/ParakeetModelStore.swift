import Foundation

/// Retains the default-model acquisition boundary used by the evaluation CLI.
public actor ParakeetModelStore: SpeechModelAcquiring {
    public nonisolated let directory: URL
    private let store: PinnedSpeechModelStore

    public static func defaultDirectory() throws -> URL { SpeechRuntimeFactory.directory(for: SpeechModelCatalog.parakeet) }

    public init(directory: URL) {
        self.directory = directory
        store = PinnedSpeechModelStore(model: SpeechModelCatalog.parakeet, directory: directory)
    }

    public func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        try await store.ensureAvailable(progress: progress)
    }

    public func removeCachedModel() async throws { try await store.removeCachedModel() }
}
