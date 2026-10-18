import Foundation
import Testing
@testable import GoblinCore

@Test func graphemeDistanceCountsClusterEdits() {
    #expect(EditObservation.graphemeDistance("hello world", "hello world") == 0)
    #expect(EditObservation.graphemeDistance("teh quick", "the quick") == 2)
    #expect(EditObservation.graphemeDistance("yes", "no") == 3)
    #expect(EditObservation.graphemeDistance("", "added") == 5)
    #expect(EditObservation.graphemeDistance("gone", "") == 4)
    // Family emoji is one grapheme cluster; swapping it is one edit, not many.
    #expect(EditObservation.graphemeDistance("a 👨‍👩‍👧 b", "a 🎉 b") == 1)
}

@Test func evaluateLocatesThePastedSpan() {
    let prefix = "Earlier sentence. "
    let inserted = "the meeting is at noon"
    let suffix = " — bring notes."
    #expect(EditObservation.evaluate(prefix: prefix, inserted: inserted, suffix: suffix,
                                     current: prefix + inserted + suffix) == .region(text: inserted, distance: 0))
    // A small fix inside the span is located and measured against the inserted text only.
    let fixed = "the meeting is at 12pm"
    #expect(EditObservation.evaluate(prefix: prefix, inserted: inserted, suffix: suffix,
                                     current: prefix + fixed + suffix)
        == .region(text: fixed, distance: EditObservation.graphemeDistance(inserted, fixed)!))
    // Typing that continues the span still locates it.
    let continued = inserted + " in the main room"
    #expect(EditObservation.evaluate(prefix: prefix, inserted: inserted, suffix: suffix,
                                     current: prefix + continued + suffix)
        == .region(text: continued, distance: 17))
}

@Test func evaluateReportsDeletedAnchorLostAndTooLong() {
    #expect(EditObservation.evaluate(prefix: "a ", inserted: "gone", suffix: " b", current: "a  b") == .deleted)
    #expect(EditObservation.evaluate(prefix: "a ", inserted: "gone", suffix: " b", current: "x gone b") == .anchorLost)
    #expect(EditObservation.evaluate(prefix: "a ", inserted: "gone", suffix: " b", current: "a gone x") == .anchorLost)
    let huge = String(repeating: "x", count: EditObservation.maximumFieldCharacters + 1)
    #expect(EditObservation.evaluate(prefix: "", inserted: "gone", suffix: "", current: huge) == .tooLong)
}

@Test func classifyBandsMatchTheThreshold() {
    // Kept, including edit-then-restore (maximum seen, final back to zero).
    #expect(EditObservation.classify(finalDistance: 0, maximumDistance: 0, insertedCount: 50, regionDeleted: false, fresh: true) == .kept)
    #expect(EditObservation.classify(finalDistance: 0, maximumDistance: 6, insertedCount: 50, regionDeleted: false, fresh: false) == .kept)
    // Silence with no seen edit never counts as kept.
    #expect(EditObservation.classify(finalDistance: 0, maximumDistance: 0, insertedCount: 50, regionDeleted: false, fresh: false) == .unobservable)
    #expect(EditObservation.classify(finalDistance: nil, maximumDistance: nil, insertedCount: 50, regionDeleted: false, fresh: true) == .unobservable)
    // Deleted span wins over everything.
    #expect(EditObservation.classify(finalDistance: 50, maximumDistance: 50, insertedCount: 50, regionDeleted: true, fresh: false) == .rejected)
    // Half of a 100-grapheme dictation may change and still count as edited; beyond is a rewrite.
    #expect(EditObservation.classify(finalDistance: 50, maximumDistance: 50, insertedCount: 100, regionDeleted: false, fresh: true) == .edited)
    #expect(EditObservation.classify(finalDistance: 51, maximumDistance: 51, insertedCount: 100, regionDeleted: false, fresh: true) == .rewritten)
    // The 10-grapheme floor keeps short dictations editable: "yes" → "no" is an edit.
    #expect(EditObservation.classify(finalDistance: 3, maximumDistance: 3, insertedCount: 3, regionDeleted: false, fresh: true) == .edited)
    #expect(EditObservation.classify(finalDistance: 11, maximumDistance: 11, insertedCount: 3, regionDeleted: false, fresh: true) == .rewritten)
}

@Test func historyStoreRecordsEditObservationAndGatesEditedText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(directory: directory)
    let entry = try await store.insert(HistoryEntry(rawText: "teh meeting is at noon", finalText: "The meeting is at noon"))

    // Entries written before observation existed decode with no outcome.
    #expect(entry.editOutcome == nil)

    try await store.updateEditObservation(id: entry.id, outcome: .edited, editDistance: 4,
                                          maximumEditDistance: 6, editedText: "The meeting is at 12pm")
    var saved = try await store.entry(id: entry.id)
    #expect(saved.editOutcome == .edited)
    #expect(saved.editDistance == 4)
    #expect(saved.maximumEditDistance == 6)
    #expect(saved.editedText == "The meeting is at 12pm")

    // A rewrite records metrics only; supplied text must not persist.
    try await store.updateEditObservation(id: entry.id, outcome: .rewritten, editDistance: 90,
                                          maximumEditDistance: 90, editedText: "something else entirely")
    saved = try await store.entry(id: entry.id)
    #expect(saved.editOutcome == .rewritten)
    #expect(saved.editedText == nil)

    await #expect(throws: HistoryError.self) {
        try await store.updateEditObservation(id: UUID(), outcome: .kept, editDistance: 0,
                                              maximumEditDistance: 0, editedText: nil)
    }
}
