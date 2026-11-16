import Foundation

/// Dictation first on a shared speech engine.
///
/// A dictation take holds the foreground from key-down until its text is inserted. Background work, such as a
/// meeting's live transcript, runs one job at a time and only while no take holds the foreground. A take that starts
/// while a job is decoding waits for that job alone, since no further job starts until every take has ended. The
/// gate never makes a take wait: takes call the engine directly, and the engine's own queue puts them right behind
/// the job that is running.
public final class SpeechPriorityGate: @unchecked Sendable {
    /// Counts since the gate was made; subtract two snapshots for one meeting.
    public struct Report: Sendable, Equatable {
        public var takes = 0
        /// Takes that began while a background job was decoding.
        public var takesBehindBackground = 0
        /// The longest a take was behind a background job: from the take's start to the job's end.
        public var maximumWaitMilliseconds = 0.0
        public var totalWaitMilliseconds = 0.0
        public var backgroundJobs = 0
        /// Background jobs that had to wait for a take, or for an earlier job, before they could start.
        public var deferredJobs = 0
        public init() {}
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var foreground: Set<UUID> = []
    private var running = false
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []
    private var behind: [UUID: ContinuousClock.Instant] = [:]
    private var report = Report()
    private var observer: (@Sendable (Double) -> Void)?

    public init() {}

    public var snapshot: Report { lock.withLock { report } }
    public var isForegroundActive: Bool { lock.withLock { !foreground.isEmpty } }

    /// Called once for each take that began behind a background job, with how long it was behind it, in milliseconds.
    public func observeWaits(_ observer: (@Sendable (Double) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    /// Marks a take as started. No background job starts until `endForeground` is called with the same ID.
    @discardableResult
    public func beginForeground(_ id: UUID = UUID()) -> UUID {
        lock.withLock {
            guard foreground.insert(id).inserted else { return }
            report.takes += 1
            if running {
                behind[id] = .now
                report.takesBehindBackground += 1
            }
        }
        return id
    }

    public func endForeground(_ id: UUID) {
        let next = lock.withLock { () -> Waiter? in
            guard foreground.remove(id) != nil else { return nil }
            return claimNext()
        }
        next?.continuation.resume()
    }

    /// Ends every take at once, for shutdown, so background work can drain.
    public func endAllForeground() {
        let next = lock.withLock { () -> Waiter? in
            foreground.removeAll()
            return claimNext()
        }
        next?.continuation.resume()
    }

    /// Waits until no take holds the foreground and no other job runs, then owns the background until `endBackground`.
    public func beginBackground() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let start = lock.withLock { () -> Bool? in
                    if cancelled.remove(id) != nil { return nil }
                    if foreground.isEmpty, !running, waiters.isEmpty {
                        running = true
                        report.backgroundJobs += 1
                        return true
                    }
                    waiters.append(Waiter(id: id, continuation: continuation))
                    report.deferredJobs += 1
                    return false
                }
                switch start {
                case nil: continuation.resume(throwing: CancellationError())
                case true?: continuation.resume()
                case false?: break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
        // A job that started without waiting leaves nothing to clean up; one cancelled before it queued does.
        lock.withLock { _ = cancelled.remove(id) }
    }

    public func endBackground() {
        let now = ContinuousClock.now
        let (waits, next, observer) = lock.withLock { () -> ([Double], Waiter?, (@Sendable (Double) -> Void)?) in
            running = false
            let waits = behind.values.map { Self.milliseconds($0.duration(to: now)) }
            behind.removeAll()
            for wait in waits {
                report.totalWaitMilliseconds += wait
                report.maximumWaitMilliseconds = max(report.maximumWaitMilliseconds, wait)
            }
            return (waits, claimNext(), self.observer)
        }
        for wait in waits { observer?(wait) }
        next?.continuation.resume()
    }

    /// Runs `body` as one background job.
    public func runBackground<T>(isolation: isolated (any Actor)? = #isolation,
                                 _ body: () async throws -> T) async throws -> T {
        try await beginBackground()
        defer { endBackground() }
        return try await body()
    }

    /// Waits until no take holds the foreground, without running anything.
    public func waitForQuiet() async throws {
        try await beginBackground()
        endBackground()
    }

    /// Hands the background to the first waiting job, when nothing holds it. Call with the lock held.
    private func claimNext() -> Waiter? {
        guard foreground.isEmpty, !running, !waiters.isEmpty else { return nil }
        running = true
        report.backgroundJobs += 1
        return waiters.removeFirst()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
