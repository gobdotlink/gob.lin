import Testing
@testable import GoblinCore

@Test func tonesKeepProtectedTextAndUseTheSamePreviewFormatter() {
    #expect(DictationTone.formal.preview == "Please send the update to Maya after we check Postgres.")
    #expect(DictationTone.casual.preview == "Please send the update to Maya after we check Postgres")
    #expect(DictationTone.veryCasual.preview == "please send the update to Maya after we check Postgres")
    let text = "Please send `Hello; WORLD.` to Maya. Then visit https://Example.com/A;B."
    #expect(ToneFormatter.format(text, tone: .veryCasual, protectedTerms: ["Maya"]) == "please send `Hello; WORLD.` to Maya. then visit https://Example.com/A;B.")
    #expect(ToneFormatter.format("Maya uses OpenAI and JSON.", tone: .veryCasual, protectedTerms: ["Maya"]) == "Maya uses OpenAI and JSON")
    #expect(ToneFormatter.format("Who did this?", tone: .veryCasual) == "who did this?")
    #expect(ToneFormatter.format("wait...", tone: .casual) == "Wait...")
    #expect(ToneFormatter.format("hello world", tone: .formal) == "Hello world.")
    #expect(ToneFormatter.format("Please visit HTTPS://example.com/a;b", tone: .casual) == "Please visit HTTPS://example.com/a;b")
    #expect(ToneFormatter.format("Please check the U.S.", tone: .veryCasual) == "please check the U.S.")
    #expect([ToneFormatter.format("Please send JSON", tone: .formal), ToneFormatter.format("Please visit https://example.com", tone: .formal)] == ["Please send JSON.", "Please visit https://example.com"])
}

@Test func formatterReportsOnlyAFullStopItRemoved() {
    func removed(_ text: String, _ tone: DictationTone = .casual, terms: [String] = []) -> Bool {
        let formatted = ToneFormatter.formatted(text, tone: tone, protectedTerms: terms)
        #expect(formatted.text == ToneFormatter.format(text, tone: tone, protectedTerms: terms))
        return formatted.removedFullStop
    }
    #expect(removed("Make that change.") && removed("make that change.", .veryCasual) && removed(#""Send it.""#))
    #expect(removed("Send it to Postgres.", terms: ["Postgres"]))
    // Unfinished, or ending in something other than a sentence's full stop.
    #expect(!removed("and I think") && !removed("Really?") && !removed("Great!") && !removed("") && !removed("  "))
    #expect(!removed("wait...") && !removed("wait…") && !removed("Please check the U.S.") && !removed("For example, e.g."))
    #expect(!removed("See https://example.com/a.") && !removed("Run `make test.`") && !removed("Use ```make.```"))
    // Formal never removes it.
    #expect(!removed("Make that change.", .formal) && !removed("make that change", .formal))
}

@Test func aFinishedTakeIsFinishedWhoeverLeftItsFullStopOut() {
    #expect(ToneFormatter.leftOutFullStop(said: "Make that change.", typed: "Make that change", tone: .casual))
    #expect(ToneFormatter.leftOutFullStop(said: "He said \"make that change.\"", typed: "He said \"make that change\"", tone: .veryCasual))
    // Trailed off, an ellipsis, a question, still ending in punctuation, or Formal: not a full stop left out.
    #expect(!ToneFormatter.leftOutFullStop(said: "and I think", typed: "And I think", tone: .casual))
    #expect(!ToneFormatter.leftOutFullStop(said: "and then...", typed: "And then", tone: .casual))
    #expect(!ToneFormatter.leftOutFullStop(said: "Is that right?", typed: "Is that right", tone: .casual))
    #expect(!ToneFormatter.leftOutFullStop(said: "Make that change.", typed: "Make that change!", tone: .casual))
    #expect(!ToneFormatter.leftOutFullStop(said: "Make that change.", typed: "Make that change", tone: .formal))
    #expect(!ToneFormatter.leftOutFullStop(said: "", typed: "", tone: .casual))
}
