import Foundation
import Testing
@testable import GoblinCore

private func pasted(_ before: String, _ observed: String, _ inserted: String) -> String? {
    InsertionPolicy.pastedRange(before: before, observed: observed, inserted: inserted)
        .map { (observed as NSString).substring(with: $0) }
}

@Test func pastedRangeFindsThePasteWhereverItLanded() {
    // A quote chip's text counts in the value but not in the caret position, so only the values can be compared.
    let draft = "Assistant quote: the composer reports its caret elsewhere\n "
    #expect(InsertionPolicy.pastedRange(before: draft, observed: draft + "testing one two ", inserted: "testing one two ")
        == NSRange(location: (draft as NSString).length, length: 16))
    #expect(pasted("Before after", "Before middle after", "middle ") == "middle ")
    // An empty paragraph's placeholder line break gives way to the text.
    #expect(pasted("Quote\n\n", "Quote\nhello ", "hello ") == "hello ")
    // Replacing a selection.
    #expect(pasted("Keep this old part", "Keep this new part", "new") == "new")
    // Repeated letters leave more than one place it could be; any of them splits the value correctly.
    let range = InsertionPolicy.pastedRange(before: "ab", observed: "abb", inserted: "b")!
    #expect(("abb" as NSString).replacingCharacters(in: range, with: "") == "ab")
    #expect(pasted("👨‍👩‍👧 then", "👨‍👩‍👧 and 🎉 then", "and 🎉 ") == "and 🎉 ")
}

@Test func pastedRangeRejectsAnythingButOnePaste() {
    #expect(InsertionPolicy.pastedRange(before: "unchanged", observed: "unchanged", inserted: "unchanged") == nil)
    #expect(InsertionPolicy.pastedRange(before: "draft", observed: "draft", inserted: "x") == nil)
    // The app rewrote the text as it arrived.
    #expect(InsertionPolicy.pastedRange(before: "a ", observed: "a it’s ", inserted: "it's ") == nil)
    // Something else changed as well.
    #expect(InsertionPolicy.pastedRange(before: "one two", observed: "One two three", inserted: " three") == nil)
    #expect(InsertionPolicy.pastedRange(before: "draft", observed: "", inserted: "") == nil)
    #expect(InsertionPolicy.pastedRange(before: "a long draft", observed: "short", inserted: "x") == nil)
}

@Test func forwardedRangeNeedsTheOnlyCopy() {
    // T3 Code moved a paste made on its page into the empty message box.
    #expect(InsertionPolicy.forwardedRange(of: "testing one two ", in: "testing one two ") == NSRange(location: 0, length: 16))
    #expect(InsertionPolicy.forwardedRange(of: "and 🎉 ", in: "👨‍👩‍👧 and 🎉 then") == NSRange(location: 9, length: 7))
    // The paste never arrived, or the field already held the same words.
    #expect(InsertionPolicy.forwardedRange(of: "testing ", in: "\n") == nil)
    #expect(InsertionPolicy.forwardedRange(of: "You can do this ", in: "You can do this You can do this ") == nil)
    #expect(InsertionPolicy.forwardedRange(of: "aa", in: "aaa") == nil)
    #expect(InsertionPolicy.forwardedRange(of: "", in: "anything") == nil)
}

@Test func clipboardRestoresOnlyAfterThePasteLands() {
    func restores(read: Bool = true, focused: Int32 = 7, before: String? = "Quote ", expected: String? = "Quote hi ",
                  observed: String?, count: Int = 3) -> Bool {
        InsertionPolicy.mayRestoreClipboard(providerRead: read, targetPID: 7, focusedPID: focused, before: before,
                                            expected: expected, observed: observed, inserted: "hi ",
                                            ownedChangeCount: 3, currentChangeCount: count)
    }
    #expect(restores(observed: "Quote hi "))
    // The caret was reported in another text space, so the expected value was wrong; the paste still landed.
    #expect(restores(expected: "Quhi ote ", observed: "Quote hi "))
    #expect(!restores(observed: "Quote "))
    #expect(!restores(read: false, observed: "Quote hi "))
    #expect(!restores(focused: 8, observed: "Quote hi "))
    #expect(!restores(observed: "Quote hi ", count: 4))
    #expect(!restores(before: nil, observed: "Quote hi "))
    #expect(!restores(observed: nil))
}

@Test func aRestoredFullStopSitsBeforeTheTakeAndOutsideItsSpan() {
    #expect(InsertionPolicy.restoredFullStop(before: "Also check the logs", trailingSpace: true) == ". ")
    #expect(InsertionPolicy.restoredFullStop(before: " Also check the logs", trailingSpace: true) == ".")
    // Without the trailing space takes already run together; only the full stop is added.
    #expect(InsertionPolicy.restoredFullStop(before: "Also check the logs", trailingSpace: false) == ".")

    let before = "Please make that change", take = InsertionPolicy.text("Also check the logs", trailingSpace: true)
    let lead = InsertionPolicy.restoredFullStop(before: "Also check the logs", trailingSpace: true)
    let location = (before as NSString).length
    let expected = InsertionPolicy.expectedValue(before: before, selectedRange: NSRange(location: location, length: 0), inserted: lead + take)
    #expect(expected == "Please make that change. Also check the logs ")
    let span = InsertionPolicy.span(of: lead + take, at: location, lead: (lead as NSString).length, in: expected!)
    #expect(span?.prefix == "Please make that change. " && span?.dictated == "Also check the logs " && span?.suffix == "")
    // A later edit is measured against what was dictated; the full stop is part of the text around it.
    #expect(EditObservation.evaluate(prefix: span!.prefix, inserted: span!.dictated, suffix: span!.suffix,
                                     current: "Please make that change. Also check the error logs ")
        == .region(text: "Also check the error logs ", distance: 6))
    #expect(InsertionPolicy.span(of: take, at: location, in: before + take)?.dictated == take)
    #expect(InsertionPolicy.span(of: take, at: location + 1, in: before + take) == nil)
    #expect(InsertionPolicy.span(of: ". ", at: 0, lead: 3, in: ". ") == nil)
}
