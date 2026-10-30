import Foundation

public struct TranscriptProcessingResult: Sendable {
    public let rawText: String
    public let finalText: String
    public let tone: DictationTone
    public let polished: Bool
    public let warning: DiagnosticFailure?
    public let timings: DictationTimings

    /// A successful cleanup can remove every hesitation sound without producing
    /// an insertion. Keep this distinct from missing ASR output or a failed rewrite.
    public var intentionallyEmpty: Bool {
        polished && warning == nil && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(rawText: String, finalText: String, tone: DictationTone, polished: Bool,
                warning: DiagnosticFailure? = nil, timings: DictationTimings = DictationTimings()) {
        self.rawText = rawText; self.finalText = finalText; self.tone = tone
        self.polished = polished; self.warning = warning; self.timings = timings
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
    public func process(_ rawText: String, dictionaryEntries: [DictionaryEntry], tone: DictationTone,
                        rewriteSettings: RewriteSettings, apiKey: String = "", context: DictationContext? = nil) async -> TranscriptProcessingResult {
        let start = ContinuousClock.now
        let entries: [DictionaryEntry]
        do { entries = try DictionaryRepository.validated(dictionaryEntries) }
        catch { return result(rawText, final: rawText, tone: tone, polished: false, warning: .dictionaryUnavailable, start: start) }
        let corrected = DictionaryCorrector.correct(rawText, entries: entries, allowFuzzy: false).text
        let preferred = entries.map(\.spelling)
        let continues = context?.continuesSentence ?? false
        if rewriteSettings.enabled && rewriteSettings.cleanup != .none {
            // Callers pass the active terms most important first; the prompt gets the same limit as recognition.
            let rewritten = await rewriteClient.rewrite(corrected, settings: rewriteSettings, apiKey: apiKey, tone: tone,
                                                        preferredSpellings: Array(preferred.prefix(DictionaryScope.activeLimit)), context: context)
            if let failure = rewritten.failure {
                // A failed rewrite must recover the original ASR output, before dictionary or tone edits.
                return result(rawText, final: rawText, tone: tone, polished: false, warning: .rewrite(failure), start: start)
            }
            return result(rawText, final: ToneFormatter.format(rewritten.outputText, tone: tone, protectedTerms: preferred, continuesSentence: continues),
                          tone: tone, polished: rewritten.wasRewritten, warning: nil, start: start)
        }
        return result(rawText, final: ToneFormatter.format(corrected, tone: tone, protectedTerms: preferred, continuesSentence: continues),
                      tone: tone, polished: false, warning: nil, start: start)
    }

    private func result(_ raw: String, final: String, tone: DictationTone, polished: Bool,
                        warning: DiagnosticFailure?, start: ContinuousClock.Instant) -> TranscriptProcessingResult {
        let elapsed = start.duration(to: .now).components
        return TranscriptProcessingResult(rawText: raw, finalText: final, tone: tone, polished: polished, warning: warning,
            timings: DictationTimings(rewriteMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
    }
}
