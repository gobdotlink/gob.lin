import Foundation

@main
struct DirectInsertionCheck {
    @MainActor static func main() async {
        let unchanged = await DirectInsertionVerification.wait(expected: "draft transcript ",
            readValue: { "draft " }, isSafe: { true })
        precondition(!unchanged, "an accepted write without an editor change must not succeed")
        let unavailable = await DirectInsertionVerification.wait(expected: "transcript ",
            readValue: { nil }, isSafe: { true })
        precondition(!unavailable, "missing editor evidence must not succeed")
        var reads = 0
        let delayed = await DirectInsertionVerification.wait(expected: "draft new 🧌 ending",
            readValue: { reads += 1; return reads > 2 ? "draft new 🧌 ending" : "draft old ending" },
            isSafe: { true })
        precondition(delayed && reads == 3, "wait for the complete edit, including selection replacement")
        var focused = true
        let moved = await DirectInsertionVerification.wait(expected: "transcript ",
            readValue: { focused = false; return "transcript " }, isSafe: { focused })
        precondition(!moved, "matching value after focus/security changes must not succeed")
        let cancelled = Task { @MainActor in
            await DirectInsertionVerification.wait(expected: "transcript ",
                readValue: { "transcript " }, isSafe: { true })
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(!cancelledResult, "cancelled verification must not succeed")
        print("Direct insertion evidence checks passed; no desktop or clipboard interaction")
    }
}
