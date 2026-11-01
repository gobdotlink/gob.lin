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
    /// The project and landing-field context, settled once per take so a draft cleanup and the final one share them.
    var completionContext: Task<DictationContext?, Never>?
    /// How many insertions had happened when that context read the field, or nil before it has.
    var contextInsertions: Int?
    /// The field that context was read from, or nil if none was.
    var contextField: FocusedText?
    var projectDetection: Task<DetectedProject?, Never>?
    var dictionaryContext: DictionaryScope { DictionaryScope(application: dictionaryScope, project: dictionaryProject?.name) }

    /// Waits briefly for project detection, which normally finished while the user was speaking.
    func resolveProject(within timeout: Duration = .milliseconds(300)) async {
        guard dictionaryProject == nil, let detection = projectDetection else { return }
        dictionaryProject = await Self.value(of: detection, within: timeout)
    }

    /// Text near the field, read while the user speaks when it may be sent to cleanup.
    var nearbyReading: Task<NearbyText?, Never>?
    /// What that reading found, once `currentContext()` has waited for it; sizes go to the development log.
    private(set) var nearby: NearbyText?

    /// `task`'s value, or nil if `timeout` passes first.
    private static func value<T: Sendable>(of task: Task<T?, Never>, within timeout: Duration) async -> T? {
        // Unstructured racers: a task group would wait for a slow task even after the timeout won.
        let race = AsyncStream<T?> { continuation in
            let result = Task { continuation.yield(await task.value); continuation.finish() }
            let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(nil); continuation.finish() }
            continuation.onTermination = { _ in result.cancel(); timer.cancel() }
        }
        for await first in race { return first }
        return nil
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

    /// Where the text will land, read just before processing the same way insertion reads it, so an earlier take typed
    /// in since this one started counts. Nearby text joins it only when it was read around that same field.
    /// It stays on this Mac unless cleanup is allowed to send it.
    func currentContext() async -> DictationContext? {
        if let reading = nearbyReading { nearby = await Self.value(of: reading, within: .milliseconds(150)) }
        contextField = landingField()
        guard let field = contextField else { return nil }
        // Typing into the focused field picks it after cleanup, so text that may reach the provider must come from the
        // field dictation started in, which the nearby read recorded.
        if destination == .currentField, nearbyReading != nil, !(nearby.map { CFEqual($0.field, field.element) } ?? false) { return nil }
        let app = NSRunningApplication(processIdentifier: field.pid)
        guard !AppInsertionQuirks.forBundle(app?.bundleIdentifier ?? "", at: app?.bundleURL).credentialManager else { return nil }
        return field.dictationContext(application: app?.localizedName, nearby: nearby)
    }

    private func landingField() -> FocusedText? {
        if destination == .currentField {
            // Insertion types into whichever field is focused once the text is ready, so read that field now.
            guard let now = FocusedText.capture(timeout: 0.05), now.pid != getpid() else { return nil }
            return now
        }
        guard let original = originalText else { return nil }
        if original.applicationFallback {
            // No field was readable at the start, as when an Electron app was still building its tree. Insertion
            // pastes into whatever field that app has focused, so read that one.
            guard let now = FocusedText.capture(timeout: 0.05), now.pid == original.pid, !now.applicationFallback else { return nil }
            return now
        }
        let now = FocusedText.read(pid: original.pid, element: original.element)
        guard original.hasSameContext(as: now) else { return nil }
        // Insertion puts the original cursor back while the text is unchanged, so fit the dictation to that spot.
        return original.selection != nil && now.value == original.value ? original : now
    }

    func cancel() {
        cancelled = true
        projectDetection?.cancel()
        nearbyReading?.cancel()
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
