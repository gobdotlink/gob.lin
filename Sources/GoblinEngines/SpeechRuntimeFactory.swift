import Foundation

public struct SpeechModelRuntime: Sendable {
    public let engine: any PCMSpeechEngine
    public let store: any SpeechModelAcquiring
    public init(engine: any PCMSpeechEngine, store: any SpeechModelAcquiring) { self.engine = engine; self.store = store }
}

public enum SpeechRuntimeFactory {
    public static var modelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/models", isDirectory: true)
    }

    public static func directory(for model: SpeechModelDescriptor) -> URL {
        modelRoot.appendingPathComponent(model.cacheFolder, isDirectory: true)
    }

    public static func make(_ model: SpeechModelDescriptor, directory: URL? = nil) -> SpeechModelRuntime {
        let directory = directory ?? self.directory(for: model)
        let engine: any PCMSpeechEngine
        switch model.kind {
        case .parakeet:
            // Correction shares one cache beside the model folders, whichever qualifying model is selected.
            let correction = model.capabilities.dictionaryCorrection
                ? ParakeetDictionaryCorrection(directory: directory.deletingLastPathComponent()
                    .appendingPathComponent(ParakeetDictionaryCorrection.cacheFolder, isDirectory: true)) : nil
            engine = ParakeetSpeechEngine(model: model, modelDirectory: directory, dictionaryCorrection: correction)
        case .whisper: engine = WhisperSpeechEngine(model: model, directory: directory)
        case .senseVoice: engine = SenseVoiceSpeechEngine(directory: directory)
        case .nemotron: engine = NemotronSpeechEngine(directory: directory)
        }
        return SpeechModelRuntime(engine: engine, store: PinnedSpeechModelStore(model: model, directory: directory))
    }

    /// The pinned CTC 110M download for dictionary correction. It is acquired only once a qualifying model has
    /// dictionary terms to correct, never as part of the speech model itself.
    public static func dictionaryCorrectionStore(root: URL? = nil) -> any SpeechModelAcquiring {
        DictionaryCorrectionStore(directory: (root ?? modelRoot).appendingPathComponent(ParakeetDictionaryCorrection.cacheFolder, isDirectory: true))
    }
}

/// Installs the reviewed CTC 110M bytes. A cache that fails its integrity check is replaced once.
actor DictionaryCorrectionStore: SpeechModelAcquiring {
    nonisolated let directory: URL
    private let cache: SpeechArtifactCache

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        cache = SpeechArtifactCache(directory: directory, manifest: SpeechModelAssets.manifest(for: ParakeetDictionaryCorrection.manifestID))
    }

    func ensureAvailable(progress: @escaping @Sendable (SpeechModelPreparationProgress) -> Void) async throws -> SpeechModelCacheUse {
        guard directory.lastPathComponent == ParakeetDictionaryCorrection.cacheFolder else { throw SpeechModelStoreError.invalidDirectory }
        do { return try await cache.ensureAvailable(progress: progress) }
        catch SpeechModelStoreError.invalidCache {
            // Earlier CLI diagnostics downloaded this folder unpinned; replace anything that isn't the reviewed revision.
            try await cache.remove()
            return try await cache.ensureAvailable(progress: progress)
        }
    }

    func removeCachedModel() async throws {
        guard directory.lastPathComponent == ParakeetDictionaryCorrection.cacheFolder else { throw SpeechModelStoreError.invalidDirectory }
        try await cache.remove()
    }
}

extension RecognitionOptions {
    func validatedLanguage(for model: SpeechModelDescriptor) throws -> String? {
        guard let language else {
            if model.capabilities.languageControl == .fixed { return model.capabilities.languageCodes.first }
            guard model.capabilities.automaticLanguage else { throw SpeechRuntimeError.languageRequired }
            return nil
        }
        guard let supported = model.capabilities.languageCodes.first(where: {
            SpeechModelCatalog.canonicalLanguage($0) == SpeechModelCatalog.canonicalLanguage(language)
        }) else { throw SpeechRuntimeError.unsupportedLanguage(language) }
        return supported
    }
}
