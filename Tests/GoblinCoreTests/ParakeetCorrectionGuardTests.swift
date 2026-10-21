import Foundation
import Testing
@testable import GoblinCore

private let terms = ["PostHog", "Kalikin", "Luna", "Panorama", "CodeRabbit", "Node.js", "C++", "TypeSafe Watcher", "Postgres"]
// A fixed stand-in for the system spell checker: everything is a word except these mishearings.
private let unknown: Set<String> = ["kalican", "postgas", "postbaz"]
private func known(_ surface: String) -> Bool {
    !unknown.contains(surface.trimmingCharacters(in: .punctuationCharacters).lowercased())
}
private func guarded(_ original: String, _ corrected: String, policy: ParakeetCorrectionGuard.Policy = .spelling,
                     confidences: [Float?]? = nil) -> ParakeetCorrectionGuard.Outcome {
    var words = ParakeetCorrectionGuard.words(original)
    if let confidences { for index in words.indices { words[index].confidence = confidences[index] } }
    return ParakeetCorrectionGuard.apply(policy, original: words, corrected: corrected, terms: terms, isKnownWord: known)
}

@Test func textJoinRejoinsSplitTermsAndKeepsOuterPunctuation() {
    #expect(ParakeetCorrectionGuard.textJoin("Ask post hog for the numbers.", terms: terms) == "Ask PostHog for the numbers.")
    #expect(ParakeetCorrectionGuard.textJoin("Ask code rab bit to review", terms: terms) == "Ask CodeRabbit to review")
    #expect(ParakeetCorrectionGuard.textJoin("(post hog), then", terms: terms) == "(PostHog), then")
    #expect(ParakeetCorrectionGuard.textJoin("Install node js now", terms: terms) == "Install Node.js now")
    // A single word is recased to a term; punctuation inside the term is not repeated around it.
    #expect(ParakeetCorrectionGuard.textJoin("postgres is up.", terms: terms) == "Postgres is up.")
    #expect(ParakeetCorrectionGuard.textJoin("(Node js).", terms: terms) == "(Node.js).")
}

@Test func textJoinNeverCrossesPunctuationOrInventsSymbols() {
    // "post. Hog" is two sentences, so the words stay apart.
    #expect(ParakeetCorrectionGuard.textJoin("We stopped the post. Hog farms opened.", terms: terms) == "We stopped the post. Hog farms opened.")
    // A single word is only recased to a term without punctuation, so "C" never becomes "C++".
    #expect(ParakeetCorrectionGuard.textJoin("Write it in C today", terms: terms) == "Write it in C today")
    // Real words that only resemble part of a multi-word term stay as spoken.
    #expect(ParakeetCorrectionGuard.textJoin("Type safe code is easier", terms: terms) == "Type safe code is easier")
    // At most three words join.
    #expect(ParakeetCorrectionGuard.textJoin("ask c o d e rabbit", terms: terms) == "ask c o d e rabbit")
    #expect(ParakeetCorrectionGuard.textJoin("nothing to join here", terms: []) == "nothing to join here")
    // Contractions keep their spelling even when their letters equal a term, with straight or curly apostrophes.
    #expect(ParakeetCorrectionGuard.textJoin("I'd like to check the id.", terms: ["ID", "ITS"]) == "I'd like to check the ID.")
    #expect(ParakeetCorrectionGuard.textJoin("I’d say it’s working, and it's done.", terms: ["ID", "ITS"])
            == "I’d say it’s working, and it's done.")
    #expect(ParakeetCorrectionGuard.textJoin("post-hog and post.hog", terms: terms) == "post-hog and post.hog")
    #expect(ParakeetCorrectionGuard.textJoin("we'll post hog", terms: ["WellPost", "PostHog"]) == "we'll PostHog")
}

@Test func spellingGuardKeepsCorrectionsOfUnknownWordsOnly() {
    let unknownName = guarded("Ask Kalican about it", "Ask Kalikin about it")
    #expect(unknownName.text == "Ask Kalikin about it" && unknownName.accepted == 1 && unknownName.rejected == 0)
    // Real words the recognizer heard are restored: "lunch" never becomes "Luna", "manage" never "Panorama".
    let ordinary = guarded("They manage to grab lunch", "They Panorama to grab Luna")
    #expect(ordinary.text == "They manage to grab lunch" && ordinary.accepted == 0 && ordinary.rejected == 2)
    #expect(guarded("Postgas is down", "Postgres is down").text == "Postgres is down")
}

@Test func spellingGuardJudgesAdjacentReplacementsSeparately() {
    // An unknown "Kalican" must not license its neighbour "lunch" -> "Luna".
    let outcome = guarded("Ask Kalican lunch today", "Ask Kalikin Luna today")
    #expect(outcome.text == "Ask Kalikin lunch today" && outcome.accepted == 1 && outcome.rejected == 1)
}

@Test func spellingGuardKeepsRespacingAndRejectsDeletion() {
    // Re-spacing a term is kept even though both words are real.
    #expect(guarded("Open post hog dashboards", "Open PostHog dashboards").text == "Open PostHog dashboards")
    // A correction that only deletes a word is never kept.
    let deletion = guarded("Ask the Kalikin team", "Ask Kalikin team")
    #expect(deletion.text == "Ask the Kalikin team" && deletion.accepted == 0)
    // Punctuation never stands in for a word, and an inserted term with no unknown word behind it is dropped.
    let dash = guarded("Wait — then go", "Wait Luna then go")
    #expect(dash.text == "Wait — then go" && dash.accepted == 0)
}

@Test func unchangedCorrectionAndPolicyNoneAreIdentity() {
    #expect(guarded("Nothing changed here", "Nothing changed here").text == "Nothing changed here")
    let none = guarded("They manage to", "They Panorama to", policy: .none)
    #expect(none.text == "They Panorama to" && none.accepted == 0 && none.rejected == 0)
}

@Test func confidencePolicyAdmitsUncertainRealWords() {
    // Evaluation-only policy: a real word heard below the threshold may be replaced.
    let low = guarded("Check posters today", "Check Postgres today", policy: .confidence(0.8), confidences: [0.99, 0.4, 0.99])
    #expect(low.text == "Check Postgres today")
    let high = guarded("Check posters today", "Check Postgres today", policy: .confidence(0.8), confidences: [0.99, 0.95, 0.99])
    #expect(high.text == "Check posters today")
    // Missing confidences never count as uncertain.
    #expect(guarded("Check posters today", "Check Postgres today", policy: .confidence(0.8)).text == "Check posters today")
}

@Test func guardThenJoinMatchesTheAppOrder() {
    // The app rescores, guards, then joins: a rejected real-word change is restored before the join sees it.
    let guardedText = guarded("Ask post hog and grab lunch", "Ask post hog and grab Luna").text
    #expect(ParakeetCorrectionGuard.textJoin(guardedText, terms: terms) == "Ask PostHog and grab lunch")
}
