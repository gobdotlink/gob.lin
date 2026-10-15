import Testing
@testable import GoblinCore

@Test func diffMarksCutFillersSwappedCaseAndAddedPunctuation() {
    #expect(TextDiff.changes(from: "um so i think we should ship it", to: "I think we should ship it.") == [
        .removed("um so i"), .added("I"), .kept("think we should ship it"), .added("."),
    ])
    #expect(TextDiff.changes(from: "", to: "Hello.") == [.added("Hello.")])
    #expect(TextDiff.changes(from: "same words", to: "same words") == [.kept("same words")])
    #expect(TextDiff.joined(TextDiff.tokens("Wait, it's done!")) == "Wait, it's done!")
}
