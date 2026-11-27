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

@Test func diffKeepsLineBreaks() {
    #expect(TextDiff.joined(TextDiff.tokens("Plan:\n1. Ship\n\nDone.")) == "Plan:\n1. Ship\n\nDone.")
    #expect(TextDiff.changes(from: "one ship two test", to: "1. Ship\n2. Test") == [
        .removed("one ship two test"), .added("1. Ship\n2. Test"),
    ])
    #expect(!TextDiff.needsSpace(after: "The plan", before: ":\n1. Ship"))
    // Rejoined tokens keep a space before a dotted part, so a fix of that space still reads as a change.
    #expect(TextDiff.joined(["gob", ".lin"]) == "gob .lin")
}
