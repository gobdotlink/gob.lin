import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import GoblinCore

/// Where a verified insertion landed: the target element plus the expected
/// field value split around the inserted span.
struct InsertionAnchor {
    var pid: pid_t
    var element: AXUIElement
    var prefix: String
    var inserted: String
    var suffix: String
}

struct EditObservationResult {
    var entryID: UUID
    var outcome: EditOutcome
    var editDistance: Int?
    var maximumEditDistance: Int?
    /// Present only for the `edited` outcome.
    var editedText: String?
}

/// Watches one pasted span for up to 30 seconds after a verified insertion.
/// Polls the anchored element's value twice a second — value-change
/// notifications are too app-dependent to trust — and reports how far the
/// span drifted. Read-only: never writes accessibility attributes, never
/// touches the pasteboard, and ends the moment focus or security context
/// changes. A new session finalizes the previous one.
@MainActor
final class PostPasteWatcher {
    private struct Session {
        var id = UUID()
        var entryID: UUID
        var anchor: InsertionAnchor
        var completion: (EditObservationResult) -> Void
        var deadline: TimeInterval
        var lastSampleAt: TimeInterval?
        var lastRegion: String?
        var lastDistance: Int?
        var maximumDistance = 0
        var regionDeleted = false
        var finishing = false
    }

    private var session: Session?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?

    /// Start watching the span pasted into `anchor`. Finalizes any running
    /// session first, so there is never more than one watched span.
    func start(entryID: UUID, anchor: InsertionAnchor, completion: @escaping (EditObservationResult) -> Void) {
        finish(report: true)
        let session = Session(entryID: entryID, anchor: anchor, completion: completion,
                              deadline: ProcessInfo.processInfo.systemUptime + 30)
        self.session = session
        installKeyMonitor(sessionID: session.id)
        let id = session.id
        task = Task { @MainActor [weak self] in
            while let self, self.session?.id == id {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.session?.id == id, !Task.isCancelled else { return }
                if ProcessInfo.processInfo.systemUptime >= (self.session?.deadline ?? 0) {
                    self.finish(report: true)
                    return
                }
                if !self.sampleOnce(sessionID: id) { return }
            }
        }
    }

    /// Discard the running session without reporting (shutdown, setting off).
    func cancel() {
        finish(report: false)
    }

    // MARK: - Sampling

    /// Returns false when the session ended inside this sample.
    /// A key-triggered final sample runs after the key reached the target, so
    /// it may already see a submitted-and-cleared field; it only updates the
    /// metrics when it still locates the region, never downgrades them.
    private func sampleOnce(sessionID: UUID, isFinalKeySample: Bool = false) -> Bool {
        guard var current = session, current.id == sessionID else { return false }
        guard !IsSecureEventInputEnabled() else {
            if isFinalKeySample { return true }
            finish(report: true); return false
        }
        let probe = FocusedText.read(pid: current.anchor.pid, element: current.anchor.element)
        guard !probe.secure, let value = probe.value, probe.isStillFocused() else {
            if isFinalKeySample { return true }
            finish(report: true); return false
        }
        switch EditObservation.evaluate(prefix: current.anchor.prefix, inserted: current.anchor.inserted,
                                        suffix: current.anchor.suffix, current: value) {
        case .region(let text, let distance):
            current.lastRegion = text
            current.lastDistance = distance
            current.maximumDistance = max(current.maximumDistance, distance)
            current.lastSampleAt = ProcessInfo.processInfo.systemUptime
            session = current
            return true
        case .deleted:
            if isFinalKeySample { return true }
            current.regionDeleted = true
            current.lastDistance = current.anchor.inserted.count
            current.maximumDistance = max(current.maximumDistance, current.anchor.inserted.count)
            current.lastSampleAt = ProcessInfo.processInfo.systemUptime
            session = current
            finish(report: true)
            return false
        case .anchorLost, .tooLong:
            if isFinalKeySample { return true }
            finish(report: true)
            return false
        }
    }

    // MARK: - Finishing

    private func finish(report: Bool) {
        guard let finished = session else { return }
        session = nil
        task?.cancel()
        task = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard report else { return }
        let fresh = finished.lastSampleAt.map { ProcessInfo.processInfo.systemUptime - $0 <= 1.5 } ?? false
        let outcome = EditObservation.classify(finalDistance: finished.lastDistance,
                                               maximumDistance: finished.lastDistance == nil ? nil : finished.maximumDistance,
                                               insertedCount: finished.anchor.inserted.count,
                                               regionDeleted: finished.regionDeleted, fresh: fresh)
        finished.completion(EditObservationResult(
            entryID: finished.entryID, outcome: outcome,
            editDistance: outcome == .unobservable ? nil : finished.lastDistance,
            maximumEditDistance: outcome == .unobservable ? nil : finished.maximumDistance,
            editedText: outcome == .edited ? finished.lastRegion : nil))
    }

    /// Keys that mean the user has moved on from the pasted span: submitting,
    /// leaving the field, undoing, or pasting over it. Take one last sample
    /// first — a chat field cleared by sending must not read as a deletion.
    private func installKeyMonitor(sessionID: UUID) {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let exits = [36, 76, 48, 53].contains(Int(event.keyCode))
                || (event.modifierFlags.contains(.command)
                    && ["z", "v"].contains(event.charactersIgnoringModifiers?.lowercased() ?? ""))
            guard exits else { return }
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID, !(self.session?.finishing ?? true) else { return }
                self.session?.finishing = true
                _ = self.sampleOnce(sessionID: sessionID, isFinalKeySample: true)
                if self.session?.id == sessionID { self.finish(report: true) }
            }
        }
    }
}
