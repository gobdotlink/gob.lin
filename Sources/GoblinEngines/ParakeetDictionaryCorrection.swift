import AppKit
import FluidAudio
import Foundation
import GoblinCore
import NaturalLanguage

/// Dictionary correction for Parakeet models that share v3's vocabulary: CTC 110M rescoring of a finished recognition,
/// the spelling guard, then text join. The CTC model and the spell checker are English, so correction runs only on
/// English dictation. Measurements and the qualifying models are in docs/evaluation/dictionary-biasing.md.
public actor ParakeetDictionaryCorrection {
    public static let cacheFolder = "parakeet-ctc-110m-coreml"
    public static var downloadBytes: Int64 { SpeechModelAssets.manifest(for: manifestID).files.reduce(0) { $0 + $1.size } }
    static let manifestID = "dictionary-correction"

    public nonisolated let directory: URL
    private typealias Models = (spotter: CtcKeywordSpotter, tokenizer: CtcTokenizer)
    private var models: Models?
    private var loading: Task<Models, Error>?
    /// Bumped by `unload`, so a load that finishes afterwards is discarded rather than published.
    private var generation = 0
    private var prepared: (key: VocabularyKey, context: CustomVocabularyContext, rescorer: VocabularyRescorer)?

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public nonisolated var isDownloaded: Bool {
        SpeechModelAssets.manifest(for: Self.manifestID).files.allSatisfy {
            let url = directory.appendingPathComponent($0.destination)
            return FileManager.default.isReadableFile(atPath: url.path)
                && (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.size)
        }
    }

    public var isLoaded: Bool { models != nil }

    /// Loads only installed files whose SHA-256 matches the pinned manifest, so a modified or stale cache never loads.
    /// Concurrent calls share one load. Returns false when `unload` ran meanwhile; the result is then discarded.
    /// Acquisition belongs to `SpeechRuntimeFactory.dictionaryCorrectionStore`.
    @discardableResult public func load() async throws -> Bool {
        if models != nil { return true }
        let generation = self.generation
        let task: Task<Models, Error>
        if let loading { task = loading } else {
            guard isDownloaded else { throw SpeechRuntimeError.modelNotInstalled }
            let directory = directory
            // Hashing and Core ML loading run off this actor, so `correct` callers never wait behind them.
            task = Task.detached { try await Self.loadModels(from: directory) }
            loading = task
        }
        let result: Models
        do { result = try await task.value }
        catch {
            if self.generation == generation { loading = nil }
            throw error
        }
        guard self.generation == generation else { return false }
        loading = nil
        models = result
        return true
    }

    private static func loadModels(from directory: URL) async throws -> Models {
        for file in SpeechModelAssets.manifest(for: manifestID).files {
            guard try ModelAssetDownload.digest(directory.appendingPathComponent(file.destination)) == file.sha256 else {
                throw SpeechModelStoreError.invalidCache
            }
        }
        let ctc = try await CtcModels.loadDirect(from: directory)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        try Task.checkCancellation()
        return (CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count), tokenizer)
    }

    public func unload() {
        generation += 1
        loading?.cancel()
        loading = nil
        models = nil
        prepared = nil
    }

    /// The app's correction: rescore, keep only replacements of words the spell checker doesn't know (or pure
    /// re-spacings of a term), then rejoin terms split across words. Returns the recognized text unchanged when the
    /// dictation isn't English or nothing was replaced. `candidates` are the recognizer's languages, for automatic detection.
    public func correct(_ recognition: TranscriptionResult, samples: [Float], terms: [String], language: String?,
                        candidates: [String]) async throws -> String {
        guard !terms.isEmpty, !recognition.text.isEmpty,
              Self.isEnglish(recognition.text, language: language, candidates: candidates) else { return recognition.text }
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0, weight: Self.termWeight) })
        let rescored = try await rescore(recognition, samples: samples, vocabulary: vocabulary).text
        var text = recognition.text
        if rescored != recognition.text {
            let original = ParakeetCorrectionGuard.recognizedWords(recognition)
            // NSSpellChecker is main-thread AppKit state; one hop checks every recognized word.
            let unknown = await MainActor.run { Set(original.map(\.surface).filter { !ParakeetCorrectionGuard.isKnownEnglishWord($0) }) }
            text = ParakeetCorrectionGuard.apply(.spelling, original: original, corrected: rescored, terms: terms,
                                                 isKnownWord: { !unknown.contains($0) }).text
        }
        return ParakeetCorrectionGuard.textJoin(text, terms: terms)
    }

    /// CTC rescoring alone. Evaluation passes vocabularies with research thresholds; the app uses FluidAudio's defaults.
    public func rescore(_ recognition: TranscriptionResult, samples: [Float], vocabulary: CustomVocabularyContext) async throws
        -> (text: String, replacements: Int, detectedTerms: Int) {
        guard let models else { throw SpeechRuntimeError.modelNotInstalled }
        let key = VocabularyKey(vocabulary)
        if prepared?.key != key {
            let tokenized = vocabulary.terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = models.tokenizer.encode(term.text)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term.text, weight: term.weight, aliases: term.aliases,
                                            ctcTokenIds: ids, minSimilarity: term.minSimilarity)
            }
            let context = CustomVocabularyContext(terms: tokenized, alpha: vocabulary.alpha, minCtcScore: vocabulary.minCtcScore,
                minSimilarity: vocabulary.minSimilarity, minCombinedConfidence: vocabulary.minCombinedConfidence,
                minTermLength: vocabulary.minTermLength)
            prepared = (key, context, try await VocabularyRescorer.create(spotter: models.spotter, vocabulary: context, ctcModelDirectory: directory))
        }
        guard let prepared, !prepared.context.terms.isEmpty else { return (recognition.text, 0, 0) }
        let evidence = try await models.spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: prepared.context, minScore: nil)
        try Task.checkCancellation()
        guard !evidence.logProbs.isEmpty else { return (recognition.text, 0, evidence.detections.count) }
        let tokens = recognition.tokens.map {
            TokenTiming(token: $0.text, tokenId: $0.tokenID ?? 0, startTime: $0.startSeconds, endTime: $0.endSeconds, confidence: $0.confidence)
        }
        let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: prepared.context.terms.count)
        let result = prepared.rescorer.ctcTokenRescore(transcript: recognition.text, tokenTimings: tokens,
            logProbs: evidence.logProbs, frameDuration: evidence.frameDuration, cbw: tuning.cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: max(prepared.context.minSimilarity, tuning.minSimilarity))
        return (result.text, result.replacements.filter(\.shouldReplace).count, evidence.detections.count)
    }

    /// FluidAudio's weight for plain term lists, which is what the evaluation glossaries used.
    static let termWeight: Float = 10

    /// An explicit language must be English; automatic recognition must produce text that reads as English among the
    /// languages the model can write. Unconstrained detection reads "Kalikan approved the design" as Indonesian.
    /// Very short dictations ("OK.") may not read as English and then go uncorrected.
    static func isEnglish(_ text: String, language: String?, candidates: [String]) -> Bool {
        if let language { return SpeechModelCatalog.canonicalLanguage(language) == "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: SpeechModelCatalog.canonicalLanguage($0)) }
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    private struct VocabularyKey: Equatable {
        let terms: [String]
        let thresholds: [Float]
        init(_ vocabulary: CustomVocabularyContext) {
            terms = vocabulary.terms.map { "\($0.text)\u{0}\($0.weight ?? 0)\u{0}\($0.minSimilarity ?? -1)\u{0}\(($0.aliases ?? []).joined(separator: "\u{1}"))" }
            thresholds = [vocabulary.alpha, vocabulary.minCtcScore, vocabulary.minSimilarity, vocabulary.minCombinedConfidence,
                          Float(vocabulary.minTermLength)]
        }
    }
}

public extension ParakeetCorrectionGuard {
    /// Recognized words with token confidences, aligned to the whitespace words of the transcript.
    static func recognizedWords(_ recognition: TranscriptionResult) -> [Word] {
        var spoken: [(key: String, confidence: Float)] = []
        var boundary = true
        for token in recognition.tokens {
            // A standalone boundary piece (" " or "▁") starts the next word even though it has no letters.
            if token.text.hasPrefix(" ") || token.text.hasPrefix("\u{2581}") { boundary = true }
            let piece = key(token.text)
            guard !piece.isEmpty else { continue }
            if boundary || spoken.isEmpty { spoken.append((piece, token.confidence)) }
            else { spoken[spoken.count - 1].key += piece; spoken[spoken.count - 1].confidence = min(spoken[spoken.count - 1].confidence, token.confidence) }
            boundary = false
        }
        var result = words(recognition.text)
        var cursor = 0
        for index in result.indices where !result[index].key.isEmpty {
            // Token words and transcript words normally match one-to-one; skip any that drift.
            if cursor < spoken.count, let match = spoken[cursor...].firstIndex(where: { $0.key == result[index].key }), match - cursor <= 2 {
                result[index].confidence = spoken[match].confidence
                cursor = match + 1
            }
        }
        return result
    }

    // NSSpellChecker knows inflections ("manages", "windows") that plain word lists lack.
    // Proper nouns are accepted in their capitalized form ("Monday"). Words the user taught macOS count as known.
    @MainActor static func isKnownEnglishWord(_ surface: String) -> Bool {
        let word = surface.trimmingCharacters(in: .punctuationCharacters)
        guard word.contains(where: \.isLetter) else { return true }
        let checker = NSSpellChecker.shared
        func known(_ value: String) -> Bool {
            checker.checkSpelling(of: value, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
        let lower = word.lowercased()
        return known(lower) || known(lower.prefix(1).uppercased() + lower.dropFirst())
    }
}
