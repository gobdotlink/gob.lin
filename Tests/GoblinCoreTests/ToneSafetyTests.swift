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
}
