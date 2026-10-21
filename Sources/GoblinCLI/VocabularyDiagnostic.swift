import Foundation
import FluidAudio
import GoblinEngines

/// Research access to Parakeet's CTC rescoring with glossary-file thresholds; the app's correction uses the same rescorer.
struct VocabularyDiagnostic {
    let terms: CustomVocabularyContext
    let directory: URL

    init(termsURL: URL, modelDirectory: URL) throws {
        terms = try CustomVocabularyContext.loadVocabularyFile(at: termsURL)
        guard !terms.terms.isEmpty, terms.terms.count <= 1_000 else {
            throw CommandError.usage("Vocabulary benchmark requires 1...1000 terms")
        }
        directory = modelDirectory.deletingLastPathComponent().appendingPathComponent(ParakeetDictionaryCorrection.cacheFolder)
    }

    func load() async throws -> Loaded {
        // Direct local loading prevents benchmark audio/text from causing network acquisition.
        let correction = ParakeetDictionaryCorrection(directory: directory)
        try await correction.load()
        return Loaded(context: terms, correction: correction)
    }

    struct Loaded {
        let context: CustomVocabularyContext
        let correction: ParakeetDictionaryCorrection
        var termCount: Int { context.terms.count }

        func rescore(_ recognition: TranscriptionResult, samples: [Float]) async throws -> Output {
            let result = try await correction.rescore(recognition, samples: samples, vocabulary: context)
            return Output(text: result.text, replacements: result.replacements, detectedTerms: result.detectedTerms)
        }
    }

    struct Output {
        let text: String
        let replacements: Int
        let detectedTerms: Int
    }
}
