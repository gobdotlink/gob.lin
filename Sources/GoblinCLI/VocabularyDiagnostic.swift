import Foundation
import FluidAudio
import GoblinEngines

/// Benchmark-only acoustic rescoring. The app does not advertise vocabulary support before accuracy validation.
struct VocabularyDiagnostic {
    let terms: CustomVocabularyContext
    let directory: URL

    init(termsURL: URL, modelDirectory: URL) throws {
        terms = try CustomVocabularyContext.loadVocabularyFile(at: termsURL)
        guard !terms.terms.isEmpty, terms.terms.count <= 1_000 else {
            throw CommandError.usage("Vocabulary benchmark requires 1...1000 terms")
        }
        directory = modelDirectory.deletingLastPathComponent().appendingPathComponent(Repo.parakeetCtc110m.folderName)
    }

    func load() async throws -> Loaded {
        // Direct local loading prevents benchmark audio/text from causing network acquisition.
        let models = try await CtcModels.loadDirect(from: directory)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let tokenized = terms.terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term.text, weight: term.weight, aliases: term.aliases,
                                        ctcTokenIds: ids, minSimilarity: term.minSimilarity)
        }
        guard !tokenized.isEmpty else { throw CommandError.usage("No vocabulary terms could be tokenized") }
        let context = CustomVocabularyContext(terms: tokenized, alpha: terms.alpha, minCtcScore: terms.minCtcScore,
                                              minSimilarity: terms.minSimilarity, minCombinedConfidence: terms.minCombinedConfidence,
                                              minTermLength: terms.minTermLength)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: context, ctcModelDirectory: directory)
        return Loaded(context: context, spotter: spotter, rescorer: rescorer)
    }

    struct Loaded {
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
        var termCount: Int { context.terms.count }

        func rescore(_ recognition: TranscriptionResult, samples: [Float]) async throws -> Output {
            let evidence = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context, minScore: nil)
            guard !evidence.logProbs.isEmpty else { throw CommandError.usage("CTC vocabulary benchmark returned no acoustic evidence") }
            let tokens = recognition.tokens.map {
                TokenTiming(token: $0.text, tokenId: $0.tokenID ?? 0, startTime: $0.startSeconds, endTime: $0.endSeconds, confidence: $0.confidence)
            }
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
            let result = rescorer.ctcTokenRescore(transcript: recognition.text, tokenTimings: tokens,
                                                logProbs: evidence.logProbs, frameDuration: evidence.frameDuration,
                                                cbw: tuning.cbw, marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                                                minSimilarity: max(context.minSimilarity, tuning.minSimilarity))
            return Output(text: result.text, replacements: result.replacements.filter(\.shouldReplace).count,
                          detectedTerms: evidence.detections.count)
        }
    }

    struct Output {
        let text: String
        let replacements: Int
        let detectedTerms: Int
    }
}
