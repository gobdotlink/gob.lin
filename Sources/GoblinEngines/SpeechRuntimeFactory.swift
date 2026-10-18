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
        case .parakeet: engine = ParakeetSpeechEngine(model: model, modelDirectory: directory)
        case .whisper: engine = WhisperSpeechEngine(model: model, directory: directory)
        case .senseVoice: engine = SenseVoiceSpeechEngine(directory: directory)
        case .nemotron: engine = NemotronSpeechEngine(directory: directory)
        }
        return SpeechModelRuntime(engine: engine, store: PinnedSpeechModelStore(model: model, directory: directory))
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
