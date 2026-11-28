import Foundation

public struct TranscriptProcessingResult: Sendable {
    public let rawText: String
    public let finalText: String
    public let tone: DictationTone
    public let polished: Bool
    public let warning: DiagnosticFailure?
    public let timings: DictationTimings
    /// The take ended a finished sentence whose full stop isn't in `finalText`: the tone removed it here, or cleanup,
    /// told to write that tone, left it out.
    public let removedFullStop: Bool
    /// `finalText` starts the sentence after gob.lin's previous take, which lost its full stop to the tone and still ends
    /// the field: insertion types that full stop back first. It is never part of `finalText`, so History, the last
    /// transcript and the edit watch keep what was dictated.
    public let restoresFullStop: Bool

    /// A successful cleanup can remove every hesitation sound without producing
    /// an insertion. Keep this distinct from missing ASR output or a failed rewrite.
    public var intentionallyEmpty: Bool {
        polished && warning == nil && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(rawText: String, finalText: String, tone: DictationTone, polished: Bool,
                warning: DiagnosticFailure? = nil, timings: DictationTimings = DictationTimings(),
                removedFullStop: Bool = false, restoresFullStop: Bool = false) {
        self.rawText = rawText; self.finalText = finalText; self.tone = tone
        self.polished = polished; self.warning = warning; self.timings = timings
        self.removedFullStop = removedFullStop; self.restoresFullStop = restoresFullStop
    }
}

/// How the draft transcript a cleanup started from compares with the final transcript.
public enum DraftTranscriptMatch: Sendable, Equatable {
    case same, sameIgnoringCaseAndPunctuation, different

    public init(draft: String, final: String) {
        let draftWords = draft.split(whereSeparator: \.isWhitespace), finalWords = final.split(whereSeparator: \.isWhitespace)
        if draftWords == finalWords { self = .same; return }
        // Only sentence punctuation at a word's edges, which cleanup sets itself; signs and symbols change meaning
        // ("-5", "$50", "50%", "C++").
        let plain = { (words: [Substring]) in
            words.map { $0.lowercased().trimmingCharacters(in: Self.sentencePunctuation) }.filter { !$0.isEmpty }
        }
        self = plain(draftWords) == plain(finalWords) ? .sameIgnoringCaseAndPunctuation : .different
    }

    private static let sentencePunctuation = CharacterSet(charactersIn: ".,!?;:…\"“”‘’'¡¿")

    /// Whether the draft's processing stands for the final transcript. Processing reads words, so the same words
    /// give the same result. Words differing only in case or edge punctuation qualify once AI cleanup polished
    /// them, because that cleanup sets case and punctuation itself.
    public func keeps(_ result: TranscriptProcessingResult) -> Bool {
        guard result.warning == nil else { return false }
        switch self {
        case .same: return true
        case .sameIgnoringCaseAndPunctuation: return result.polished
        case .different: return false
        }
    }

    /// When the provider itself failed on the draft's words (deadline, connection or HTTP status), the final
    /// transcript's raw-text fallback, as one attempt on it would have produced. A second full deadline would only
    /// delay it. Nil when the final transcript deserves its own attempt.
    public func providerFallback(_ result: TranscriptProcessingResult, final: String) -> TranscriptProcessingResult? {
        guard self != .different, let warning = result.warning, Self.isProviderFailure(warning) else { return nil }
        return TranscriptProcessingResult(rawText: final, finalText: final, tone: result.tone, polished: false, warning: warning,
                                          timings: result.timings)
    }

    private static func isProviderFailure(_ warning: DiagnosticFailure) -> Bool {
        switch warning {
        case .rewriteTimeout, .rewriteTransport, .rewriteHTTPStatus: true
        default: false
        }
    }
}

/// Shared by the app and CLI; credentials are supplied by their platform shells.
public actor TranscriptPostprocessor {
    private let rewriteClient: RewriteClient

    public init(rewriteClient: RewriteClient = RewriteClient()) { self.rewriteClient = rewriteClient }

    /// Opens the cleanup provider's connection ahead of `process`; see `RewriteClient.prewarm`.
    public func prewarm(_ settings: RewriteSettings) async { await rewriteClient.prewarm(settings) }

    /// `context` fits the text to where it lands. It leaves the Mac only when the settings allow it for their provider.
    /// `customPrompt` replaces gob.lin's cleanup instructions; `formatsTone: false` then types cleanup's text as written,
    /// without the tone's own pass.
    public func process(_ rawText: String, dictionaryEntries: [DictionaryEntry], tone: DictationTone,
                        rewriteSettings: RewriteSettings, apiKey: String = "", context: DictationContext? = nil,
                        customPrompt: String? = nil, formatsTone: Bool = true) async -> TranscriptProcessingResult {
        let start = ContinuousClock.now
        let entries: [DictionaryEntry]
        do { entries = try DictionaryRepository.validated(dictionaryEntries) }
        catch { return result(rawText, final: rawText, tone: tone, polished: false, warning: .dictionaryUnavailable, start: start) }
        let corrected = DictionaryCorrector.correct(rawText, entries: entries, allowFuzzy: false).text
        let preferred = entries.map(\.spelling)
        // After gob.lin's own finished take a dictation starts a sentence, unless it opens with a joining word.
        func continues(_ text: String) -> Bool { context.map { $0.continuesSentence || $0.joinsPreviousTake(text) } ?? false }
        func restores(_ text: String) -> Bool { context.map { $0.restoresFullStop && !$0.joinsPreviousTake(text) } ?? false }
        if rewriteSettings.enabled && rewriteSettings.cleanup != .none {
            // Callers pass the active terms most important first; the prompt gets the same limit as recognition.
            let rewritten = await rewriteClient.rewrite(corrected, settings: rewriteSettings, apiKey: apiKey, tone: tone,
                                                        preferredSpellings: Array(preferred.prefix(DictionaryScope.activeLimit)), context: context,
                                                        customPrompt: customPrompt)
            if let failure = rewritten.failure {
                // A failed rewrite must recover the original ASR output, before dictionary or tone edits.
                return result(rawText, final: rawText, tone: tone, polished: false, warning: .rewrite(failure), start: start)
            }
            // Cleanup may lower a first word to fit the previous take; outside `continues` this pass gives it its capital back.
            let output = rewritten.outputText
            guard formatsTone else {
                return result(rawText, final: output, tone: tone, polished: rewritten.wasRewritten, warning: nil, start: start,
                              restoresFullStop: restores(output))
            }
            let formatted = ToneFormatter.formatted(output, tone: tone, protectedTerms: preferred, continuesSentence: continues(output))
            // Cleanup is told the tone too, so it usually leaves a casual take's full stop out itself.
            let finished = formatted.removedFullStop || ToneFormatter.leftOutFullStop(said: corrected, typed: formatted.text, tone: tone)
            return result(rawText, final: formatted.text, tone: tone, polished: rewritten.wasRewritten, warning: nil, start: start,
                          removedFullStop: finished, restoresFullStop: restores(output))
        }
        let formatted = ToneFormatter.formatted(corrected, tone: tone, protectedTerms: preferred, continuesSentence: continues(corrected))
        return result(rawText, final: formatted.text, tone: tone, polished: false, warning: nil, start: start,
                      removedFullStop: formatted.removedFullStop, restoresFullStop: restores(corrected))
    }

    private func result(_ raw: String, final: String, tone: DictationTone, polished: Bool, warning: DiagnosticFailure?,
                        start: ContinuousClock.Instant, removedFullStop: Bool = false, restoresFullStop: Bool = false) -> TranscriptProcessingResult {
        let elapsed = start.duration(to: .now).components
        return TranscriptProcessingResult(rawText: raw, finalText: final, tone: tone, polished: polished, warning: warning,
            timings: DictationTimings(rewriteMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15),
            removedFullStop: removedFullStop, restoresFullStop: restoresFullStop)
    }
}
