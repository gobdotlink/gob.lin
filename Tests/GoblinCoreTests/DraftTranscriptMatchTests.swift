import Testing
@testable import GoblinCore

struct DraftTranscriptMatchTests {
    private func result(polished: Bool, warning: DiagnosticFailure? = nil) -> TranscriptProcessingResult {
        TranscriptProcessingResult(rawText: "draft", finalText: "Cleaned.", tone: .formal, polished: polished, warning: warning)
    }

    @Test func matchingComparesWordsOnly() {
        #expect(DraftTranscriptMatch(draft: "ship it  now", final: "ship it now") == .same)
        #expect(DraftTranscriptMatch(draft: "So, ship it. Now", final: "so ship it now?") == .sameIgnoringCaseAndPunctuation)
        // Words, not characters: punctuation inside a word, a merged name or a missing word all differ.
        #expect(DraftTranscriptMatch(draft: "open AI models", final: "OpenAI models") == .different)
        #expect(DraftTranscriptMatch(draft: "check example com", final: "check example.com") == .different)
        #expect(DraftTranscriptMatch(draft: "ship it", final: "ship it now") == .different)
        // Signs and symbols change meaning, so they are never ignored like sentence punctuation.
        #expect(DraftTranscriptMatch(draft: "pay $50", final: "pay 50%") == .different)
        #expect(DraftTranscriptMatch(draft: "write C++", final: "write C") == .different)
        #expect(DraftTranscriptMatch(draft: "it was -5", final: "it was 5") == .different)
        #expect(DraftTranscriptMatch(draft: "“Ship it,” she said", final: "ship it she said!") == .sameIgnoringCaseAndPunctuation)
    }

    @Test func onlyAPolishedCleanupCoversPunctuationDifferences() {
        #expect(DraftTranscriptMatch.same.keeps(result(polished: false)))
        #expect(DraftTranscriptMatch.sameIgnoringCaseAndPunctuation.keeps(result(polished: true)))
        // Without AI cleanup the draft's own punctuation would be inserted, so the final transcript is processed instead.
        #expect(!DraftTranscriptMatch.sameIgnoringCaseAndPunctuation.keeps(result(polished: false)))
        #expect(!DraftTranscriptMatch.different.keeps(result(polished: true)))
        // A failed draft cleanup is never kept.
        #expect(!DraftTranscriptMatch.same.keeps(result(polished: false, warning: .rewrite(.timeout))))
    }

    @Test func aProviderFailureOnTheSameWordsFallsBackWithoutASecondDeadline() {
        let timedOut = result(polished: false, warning: .rewrite(.timeout))
        let fallback = DraftTranscriptMatch.sameIgnoringCaseAndPunctuation.providerFallback(timedOut, final: "So ship it now")
        // The final transcript's own raw text, unedited, with the provider's warning: what one attempt on it gives.
        #expect(fallback?.rawText == "So ship it now" && fallback?.finalText == "So ship it now")
        #expect(fallback?.polished == false && fallback?.warning == .rewrite(.timeout))
        #expect(DraftTranscriptMatch.same.providerFallback(result(polished: false, warning: .rewrite(.httpStatus(503))), final: "x") != nil)
        // Content failures and different words get their own attempt on the final transcript.
        #expect(DraftTranscriptMatch.same.providerFallback(result(polished: false, warning: .rewrite(.invalidResponse)), final: "x") == nil)
        #expect(DraftTranscriptMatch.different.providerFallback(timedOut, final: "x") == nil)
        #expect(DraftTranscriptMatch.same.providerFallback(result(polished: true), final: "x") == nil)
    }
}
