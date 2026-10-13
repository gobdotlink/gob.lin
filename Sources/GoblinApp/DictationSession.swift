import AppKit

@MainActor
final class DictationSession {
    let id = UUID()
    let createdAt = Date()
    let captureStarted = ContinuousClock.now
    let target: NSRunningApplication?
    var overlayID: UUID?
    var audioOwnedByHistory = false
    private(set) var cancelled = false

    init(target: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        self.target = target?.processIdentifier == getpid() ? nil : target
    }

    func cancel() { cancelled = true }

    func checkCancellation() throws {
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
    }

    var targetIsFocused: Bool {
        guard let target, !target.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }
}

/// Capture continues independently; completed dictations retain their output order.
@MainActor
final class DictationProcessingQueue {
    private var tail: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool { tasks.isEmpty }

    func enqueue(_ session: DictationSession, operation: @escaping @MainActor () async -> Void,
                 completed: @escaping @MainActor () async -> Void) {
        let previous = tail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            if !session.cancelled && !Task.isCancelled { await operation() }
            await completed()
            self?.tasks[session.id] = nil
            if self?.tasks.isEmpty == true { self?.tail = nil }
        }
        tasks[session.id] = task
        tail = task
    }

    func cancel(_ session: DictationSession) {
        session.cancel()
        tasks[session.id]?.cancel()
    }

    func shutdown() async {
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        tasks.removeAll()
        tail = nil
    }
}
