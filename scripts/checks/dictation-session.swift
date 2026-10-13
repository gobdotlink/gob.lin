import AppKit

@main
struct DictationSessionCheck {
    @MainActor static func main() async {
        let queue = DictationProcessingQueue()
        let first = DictationSession(target: nil)
        let cancelled = DictationSession(target: nil)
        let third = DictationSession(target: nil)
        var events: [Int] = []
        var completions = 0
        queue.enqueue(first, operation: {
            events.append(1)
            try? await Task.sleep(for: .milliseconds(40))
            events.append(2)
        }, completed: { completions += 1 })
        queue.enqueue(cancelled, operation: { events.append(-1) }, completed: { completions += 1 })
        queue.enqueue(third, operation: { events.append(3) }, completed: { completions += 1 })
        queue.cancel(cancelled)
        do { try cancelled.checkCancellation(); preconditionFailure("Cancelled output was accepted") }
        catch is CancellationError {}
        catch { preconditionFailure("Unexpected cancellation error") }
        while !queue.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(events == [1, 2, 3], "Output order or cancelled output changed: \(events)")
        precondition(completions == 3, "A processing count was not released exactly once")
        queue.enqueue(DictationSession(target: nil), operation: { events.append(-2) }, completed: { completions += 1 })
        await queue.shutdown()
        precondition(!events.contains(-2) && queue.isEmpty && completions == 4)
        print("Session queue: ordered output, cancellation, completion accounting and shutdown passed.")
    }
}
