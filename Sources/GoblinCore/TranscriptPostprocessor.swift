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

/// Shared by the app and CLI; credentials are supplied by their platform shells.
public actor TranscriptPostprocessor {
    private let rewriteClient: RewriteClient

    public init(rewriteClient: RewriteClient = RewriteClient()) { self.rewriteClient = rewriteClient }

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
