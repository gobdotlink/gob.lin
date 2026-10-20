import AppKit
import GoblinCore

enum DictationDestination: String {
    case currentField, originalField
}

@MainActor
final class DictationSession {
    let id = UUID()
    let createdAt = Date()
    let captureStarted = ContinuousClock.now
    let target: NSRunningApplication?
    let originalText: FocusedText?
    let destination: DictationDestination
    /// Selects app-scoped dictionary terms for the whole dictation, including later History reprocessing.
    /// "" matches no app, so dictating from gob.lin itself uses only terms for every app.
    var dictionaryScope: String { target?.bundleIdentifier ?? "" }
    /// The project open where dictation started, once detection finishes; see `ProjectDetector`.
    var dictionaryProject: DetectedProject?
    var projectDetection: Task<DetectedProject?, Never>?
    var dictionaryContext: DictionaryScope { DictionaryScope(application: dictionaryScope, project: dictionaryProject?.name) }

    /// Waits briefly for project detection, which normally finished while the user was speaking.
    func resolveProject(within timeout: Duration = .milliseconds(300)) async {
        guard dictionaryProject == nil, let detection = projectDetection else { return }
        // Unstructured racers: a task group would wait for slow detection even after the timeout won.
        let race = AsyncStream<DetectedProject?> { continuation in
            let result = Task { continuation.yield(await detection.value); continuation.finish() }
            let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(nil); continuation.finish() }
            continuation.onTermination = { _ in result.cancel(); timer.cancel() }
        }
        for await first in race {
            dictionaryProject = first
            break
        }
    }
    var overlayID: UUID?
    var audioOwnedByHistory = false
    var historyOnly = false
    private(set) var cancelled = false

    init(target: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
         destination: DictationDestination = .originalField) {
        self.destination = destination
        self.target = target?.processIdentifier == getpid() ? nil : target
        let focused = self.target == nil || destination == .currentField ? nil : FocusedText.capture(timeout: 0.05)
        originalText = focused?.pid == self.target?.processIdentifier ? focused : nil
    }

    func cancel() {
        cancelled = true
        projectDetection?.cancel()
    }

    func checkCancellation() throws {
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
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
