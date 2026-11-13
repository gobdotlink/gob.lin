import Foundation

/// What History sync is doing, for each app to word in its own voice.
public enum HistorySyncStatus: Sendable, Equatable {
    /// The switch is off.
    case off
    /// On, and sending and fetching as it can.
    case syncing
    /// There's no iCloud account to sync with, or iCloud can't say who's signed in right now. Nothing here is removed
    /// and nothing is sent while waiting.
    case waitingForAccount
    /// iCloud refused a dictation for lack of space. Sending waits for the next launch or `syncNow()`.
    case iCloudFull
    /// Some dictations or settings come from a newer gob.lin and are left out until this one is updated.
    case needsUpdate
    /// gob.lin's data was deleted from iCloud. History here stays as it was, and sync has turned itself off.
    case purged
    /// A different iCloud account signed in. Other devices' dictations went with the old account, and sync has turned
    /// itself off, so this device's History never joins someone else's account silently.
    case differentAccount
}

public enum HistorySyncUpdate: Sendable, Equatable {
    case status(HistorySyncStatus)
    /// Dictations arrived or went because of iCloud: reload whatever shows History.
    case historyChanged
}

/// Syncs History with the person's private iCloud database through `CKSyncEngine`.
///
/// Create it with `start(store:retention:)`, which touches CloudKit only when this app is entitled to and the switch is
/// on. Tell it about every local write with `historyChanged()`. The engine sends nothing until a fetch has finished
/// since its last send, so a Delete All made elsewhere is applied here before any of this device's dictations go up.
public actor HistorySyncEngine {
    public static let containerIdentifier = "iCloud.app.goblin.dictation"
    /// iCloud refuses a record over 1 MB; this leaves room for the record's own fields.
    static let maximumBody = 900_000
    /// The smaller of the per-request limits Apple documents.
    static let maximumItems = 250

    /// Status changes and remote History changes. An `AsyncStream` has one consumer: an app that needs several fans
    /// it out. It ends after `stop()`, or by itself when sync turns itself off (`purged`, `differentAccount`), after
    /// the History changes that makes, so keep listening until it ends.
    public nonisolated let updates: AsyncStream<HistorySyncUpdate>
    private let continuation: AsyncStream<HistorySyncUpdate>.Continuation
    private let store: HistoryStore
    private let retention: @Sendable () async -> HistoryRetention
    private var connect: (@Sendable (Data?) -> any HistorySyncTransport)?
    private(set) var transport: (any HistorySyncTransport)?
    private var saved = Saved()
    private var lastStatus: HistorySyncStatus?
    private var account: Bool? = true
    /// iCloud has said who's signed in on this connection, and it's the person History syncs with.
    private var identified = false
    private var full = false
    /// The transport started from no saved state and its first fetch hasn't finished: when it does, whatever iCloud
    /// didn't return was deleted elsewhere.
    private var fullFetch = false
    private var fetched: Set<UUID> = []
    /// Opens when a fetch finishes, closes when a send that sent something finishes.
    private var fetchedSinceSend = false
    private var fetchFailed = false
    private var sending = false
    private var zoneMissing = false
    private var attempted: Set<HistorySyncChange> = []
    private var revisions: [String: Int] = [:]
    private var lastBatchCount = 0
    /// Bytes of bodies per request; halved when iCloud says a request is too big.
    var byteBudget = 1_000_000

    /// What the engine keeps between launches, in History's database.
    struct Saved: Codable {
        var serialization: Data?
        /// The iCloud user record name last signed in, to tell a returning account from a different one.
        var account: String?
        /// The highest record format left out for being newer than this build.
        var newerFormat: Int?
        var purged = false
        var differentAccount = false
        /// Fetched changes were lost (a full fetch quit early, or a page couldn't be applied): start over from no state.
        var refetch = false
    }

    init(store: HistoryStore, retention: @escaping @Sendable () async -> HistoryRetention) {
        self.store = store
        self.retention = retention
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// The status of an engine that isn't running, read from History without CloudKit.
    public static func status(of store: HistoryStore) async -> HistorySyncStatus {
        let saved = (try? await store.engineState()).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        guard (try? await store.isSyncEnabled()) == true else {
            return saved.purged ? .purged : saved.differentAccount ? .differentAccount : .off
        }
        return (saved.newerFormat ?? 0) > HistorySync.formatVersion ? .needsUpdate : .syncing
    }

    /// Loads the saved state and connects. `connect` makes the transport, resuming from the state it's given; nil means
    /// start over with a full fetch. It runs on this actor without suspending, so the transport is current before its
    /// engine can deliver anything.
    func begin(connect: @escaping @Sendable (Data?) -> any HistorySyncTransport) async throws {
        self.connect = connect
        if let data = try await store.engineState() { saved = (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved() }
        // The switch is on, so the person turned sync back on after it turned itself off.
        saved.purged = false
        saved.differentAccount = false
        // This build reads the format it once left out: fetch everything again to pick those records up.
        if let newer = saved.newerFormat, newer <= HistorySync.formatVersion { saved.newerFormat = nil; saved.refetch = true }
        if saved.refetch || saved.serialization == nil { saved.serialization = nil; saved.refetch = true }
        try await persist()
        try await reconnect(from: saved.serialization)
    }

    private func reconnect(from serialization: Data?) async throws {
        guard let connect else { return }
        await transport?.stop()
        fetchedSinceSend = false
        sending = false
        attempted = []
        fullFetch = serialization == nil
        fetched = []
        let transport = connect(serialization)
        self.transport = transport
        identified = false
        if fullFetch { await transport.queueZone() }
        _ = try await identify()
        // A different person is signed in, and sync has turned itself off.
        guard self.transport != nil else { return }
        await queuePending()
        publish()
        await transport.fetch()
    }

    /// Call after every local History write: insert, delete, star, edit observation, Keep, Delete All.
    public func historyChanged() async {
        await queuePending()
    }

    /// Fetches, then sends. For launch, coming to the foreground, or the person asking; it also retries after iCloud
    /// was full.
    public func syncNow() async {
        full = false
        publish()
        await queuePending()
        await transport?.fetch()
    }

    /// Fetches everything in iCloud again, from no saved state. Call when this device's Keep was raised: what the
    /// earlier Keep left out comes back.
    public func fetchAll() async {
        guard transport != nil else { return }
        saved.refetch = true
        try? await persist()
        try? await reconnect(from: nil)
        publish()
    }

    /// Stops syncing. The saved state stays, so starting again resumes. Safe at any time: once sync has turned itself
    /// off, `updates` ends only after the cleanup that follows has been reported.
    public func stop() async {
        await shutDown()
        if saved.purged || saved.differentAccount { return }
        continuation.finish()
    }

    private func shutDown() async {
        await transport?.stop()
        transport = nil
        connect = nil
        publish()
    }

    var status: HistorySyncStatus {
        if saved.purged { return .purged }
        if saved.differentAccount { return .differentAccount }
        if transport == nil { return .off }
        if account != true { return .waitingForAccount }
        if full { return .iCloudFull }
        if (saved.newerFormat ?? 0) > HistorySync.formatVersion { return .needsUpdate }
        return .syncing
    }

    private func publish() {
        let status = status
        guard status != lastStatus else { return }
        lastStatus = status
        continuation.yield(.status(status))
    }

    // MARK: - Events

    func handle(_ event: HistorySyncEvent) async {
        guard transport != nil else { return }
        do {
            switch event {
            case .state(let serialization):
                saved.serialization = serialization
                try await persist()
            case .account(let change): try await accountChanged(change)
            case .zoneDeleted(let reason): try await zoneDeleted(reason)
            case .fetched(let changes, let deletions):
                do { try await apply(changes, deletions: deletions) } catch {
                    // The engine counts the page as delivered. Send nothing on this fetch, and start over from no state.
                    fetchFailed = true
                    fullFetch = false
                    saved.refetch = true
                    try await persist()
                }
            case .fetchFailed: fetchFailed = true
            case .fetchFinished(let succeeded): try await fetchFinished(succeeded)
            case .sent(let sent, let deleted, let failed): try await self.sent(sent, deleted: deleted, failed: failed)
            case .sendFinished:
                if sending { fetchedSinceSend = false }
                sending = false
                attempted = []
            }
        } catch {
            // ponytail: a store error leaves the change pending in History, and the next fetch or send tries again.
        }
        publish()
    }

    private func apply(_ changes: [HistoryRemote], deletions: [String]) async throws {
        var saves: [HistoryRemoteRecord] = [], settings: HistoryRemoteSettings?
        for change in changes {
            switch change {
            case .dictation(let record): saves.append(record); fetched.insert(record.id)
            case .settings(let remote): settings = remote
            }
        }
        if let newest = changes.map(\.formatVersion).max(), newest > HistorySync.formatVersion {
            saved.newerFormat = max(saved.newerFormat ?? 0, newest)
            try await persist()
        }
        let result = try await store.applyRemote(saves: saves, deletions: deletions.compactMap(UUID.init(uuidString:)),
                                                 settings: settings, retention: await retention())
        if result.saved + result.deleted > 0 { continuation.yield(.historyChanged) }
        // A page can drop records from before a Delete All, whose deletions go out.
        await queuePending()
    }

    /// A fetch this engine asked for has returned. Unless it succeeded, with every zone and page applied, this device
    /// may not know about a Delete All or a deletion, so nothing is reconciled here and nothing goes up.
    private func fetchFinished(_ succeeded: Bool) async throws {
        let complete = succeeded && !fetchFailed
        fetchFailed = false
        guard complete else { return }
        // Against someone else's iCloud, reconciling would remove this device's dictations, the purge would delete
        // theirs, and sending would hand them this device's. So all of it waits until iCloud says who's signed in.
        guard try await identify() else { return }
        if saved.refetch && !fullFetch { try await reconnect(from: nil); return }
        if fullFetch {
            if try await store.deleteMissing(fetched: fetched) > 0 { continuation.yield(.historyChanged) }
            fullFetch = false
            saved.refetch = false
            try await persist()
        }
        fetched = []
        try await store.markJoined()
        try? await purgeIfNeeded()
        // A save found no zone. Had the zone been deleted, this fetch would have said so; it didn't, so make it.
        if zoneMissing { zoneMissing = false; await transport?.queueZone() }
        fetchedSinceSend = true
        await queuePending()
        await transport?.send()
    }

    /// A Delete All made here: every dictation iCloud saved at or before it goes, whoever holds it. The zone is listed
    /// from the start of its history with no fields, which needs no index; once a listing finds none left, it's done.
    private func purgeIfNeeded() async throws {
        guard let transport, let through = try await store.pendingChanges().purgeThrough else { return }
        let stale = try await transport.listDictations().filter { $0.value <= through }.keys
        if stale.isEmpty {
            try await store.markPurged(through: through)
        } else {
            await transport.queue(stale.map(HistorySyncChange.delete))
        }
    }

    private func sent(_ sent: [HistorySyncSent], deleted: [String], failed: [HistorySyncFailure]) async throws {
        for record in sent {
            let revision = revisions.removeValue(forKey: record.name) ?? -1
            if record.name == HistorySync.settingsName {
                try await store.markSettingsSent(serverFields: record.serverFields, revision: revision)
            } else if let id = UUID(uuidString: record.name) {
                try await store.markSent(id: id, serverFields: record.serverFields, serverCreated: record.created, revision: revision)
            }
        }
        if !sent.isEmpty { full = false }
        try await store.markDeleted(ids: deleted.compactMap(UUID.init(uuidString:)))
        // A change made while its record was on its way is still pending here, but the engine has just let go of the
        // record, so it goes back in the queue.
        let names = Set(sent.map(\.name))
        if !names.isEmpty {
            let pending = try await store.pendingChanges()
            var again = pending.saves.map(\.uuidString).filter(names.contains).map(HistorySyncChange.save)
            if pending.settings, names.contains(HistorySync.settingsName) { again.append(.save(HistorySync.settingsName)) }
            if !again.isEmpty { await transport?.queue(again) }
        }
        // Failures this device can resolve go out again with the engine's next send. Others wait for a later fetch,
        // `syncNow()` or the next launch, so a send that keeps failing never becomes a loop.
        var resolved = false, halved = false
        for failure in failed {
            switch failure {
            case .conflict(.dictation(let server)):
                try await store.applyRemote(saves: [server], retention: await retention())
                continuation.yield(.historyChanged)
                resolved = true
            case .conflict(.settings(let server)):
                try await store.applyRemote(settings: server)
                resolved = true
            case .missingZone:
                zoneMissing = true
            case .gone(let name):
                // Deleted on another device while this one changed it: the deletion wins.
                if let id = UUID(uuidString: name), try await store.applyRemote(deletions: [id]).deleted > 0 {
                    continuation.yield(.historyChanged)
                }
            case .zoneDeletedByPerson:
                try await zoneDeleted(.purged)
                return
            case .full:
                full = true
            case .tooBig(let name):
                if lastBatchCount > 1 {
                    // Once for the request, however many of its records it names.
                    if !halved { byteBudget = max(byteBudget / 2, 1); halved = true }
                    resolved = true
                } else if let id = UUID(uuidString: name) {
                    try await store.markLocalOnly(id: id)
                    await transport?.unqueue([.save(name)])
                }
            case .other: break
            }
        }
        if resolved { await queuePending() }
    }

    private func accountChanged(_ change: HistorySyncAccount) async throws {
        switch change {
        case .signedOut:
            account = false
            identified = false
            if try await store.removeOtherDevices() > 0 { continuation.yield(.historyChanged) }
        case .signedIn(let user) where saved.account == nil || saved.account == user:
            saved.account = user
            try await persist()
            // The engine dropped its pending changes when the account changed. Unless this transport is already on its
            // first full fetch, start a fresh one, so deletions made while signed out are applied here too.
            if fullFetch { await queuePending() } else { saved.refetch = true; try await persist(); try await reconnect(from: nil) }
            // The engine has said who's signed in, so this connection needn't ask.
            account = true
            identified = true
        case .signedIn(let user), .switched(let user):
            // Stop first, so nothing more goes to the new account even if the cleanup below fails.
            saved = Saved(account: user, differentAccount: true)
            await shutDown()
            defer { continuation.finish() }
            try await store.setSyncEnabled(false)
            try await store.forgetServerState(keepingOthers: false)
            continuation.yield(.historyChanged)
            try await persist()
        }
    }

    /// Asks iCloud who's signed in, without waiting for the engine to say, until this connection knows. The first
    /// person is remembered; a different one turns sync off before anything moves. False while iCloud can't say.
    private func identify() async throws -> Bool {
        guard !identified else { return true }
        guard let transport else { return false }
        let current = await transport.account()
        account = current.map { $0 != .signedOut }
        guard case .signedIn(let user)? = current else { return false }
        if let known = saved.account, known != user {
            try await accountChanged(.switched(user))
            return false
        }
        if saved.account == nil { saved.account = user; try await persist() }
        identified = true
        return true
    }

    enum ZoneOutcome: Equatable { case keepAndTurnOff, uploadAgain }

    /// What this device does when iCloud's copy of History is deleted, decided in one place.
    static func outcome(of deletion: HistorySyncZoneDeletion) -> ZoneOutcome {
        switch deletion {
        // The person deleted gob.lin's data in Settings, or a gob.lin deleted the zone. History is local-first, so
        // it stays here; sync turns off rather than upload it again.
        case .purged, .deleted: .keepAndTurnOff
        // Keys were reset during account recovery, and the dictations are still theirs.
        case .encryptedDataReset: .uploadAgain
        }
    }

    private func zoneDeleted(_ deletion: HistorySyncZoneDeletion) async throws {
        switch Self.outcome(of: deletion) {
        case .keepAndTurnOff:
            // Stop first, so nothing more goes up even if the cleanup below fails.
            saved = Saved(account: saved.account, purged: true)
            await shutDown()
            defer { continuation.finish() }
            try await store.setSyncEnabled(false)
            try await store.forgetServerState(keepingOthers: true)
            try await persist()
        case .uploadAgain:
            // Start over from no engine state, so only what History says is pending goes up, not what was queued.
            try await store.forgetServerState(keepingOthers: true)
            saved.serialization = nil
            saved.refetch = true
            try await persist()
            try await reconnect(from: nil)
        }
    }

    // MARK: - Sending

    /// The next records to send from the engine's pending list, or nil to send nothing now.
    func nextBatch(_ pending: [HistorySyncChange]) async -> HistorySyncBatch? {
        guard let transport, !full else { return nil }
        guard fetchedSinceSend else {
            // One fetch for each send the engine attempts, so the engine's own backoff still paces one that keeps failing.
            await transport.fetch()
            return nil
        }
        var batch = HistorySyncBatch(), bytes = 0
        scan: for change in pending where !attempted.contains(change) {
            if batch.count == Self.maximumItems { break }
            switch change {
            case .save(let name):
                guard let record = try? await outgoing(name) else { await transport.unqueue([change]); continue }
                if record.body.count > Self.maximumBody, let id = UUID(uuidString: name) {
                    try? await store.markLocalOnly(id: id)
                    await transport.unqueue([change])
                    continue
                }
                if batch.count > 0, bytes + record.body.count > byteBudget { break scan }
                bytes += record.body.count
                batch.saves.append((name, record))
                revisions[name] = record.revision
            case .delete(let name):
                batch.deletions.append(name)
            }
            attempted.insert(change)
        }
        lastBatchCount = batch.count
        guard batch.count > 0 else { return nil }
        sending = true
        return batch
    }

    private func outgoing(_ name: String) async throws -> HistoryOutgoingRecord? {
        if name == HistorySync.settingsName { return try await store.outgoingSettings() }
        guard let id = UUID(uuidString: name) else { return nil }
        return try await store.outgoingRecord(id: id)
    }

    private func queuePending() async {
        guard let transport, let pending = try? await store.pendingChanges() else { return }
        var changes = pending.saves.map { HistorySyncChange.save($0.uuidString) } + pending.deletions.map { .delete($0.uuidString) }
        if pending.settings { changes.append(.save(HistorySync.settingsName)) }
        await transport.queue(changes)
    }

    private func persist() async throws {
        try await store.setEngineState(JSONEncoder().encode(saved))
    }
}

/// One change waiting to go to iCloud, by record name: an entry's UUID, or `HistorySync.settingsName`.
enum HistorySyncChange: Hashable, Sendable { case save(String), delete(String) }

enum HistorySyncAccount: Sendable, Equatable { case signedIn(String), signedOut, switched(String) }

enum HistorySyncZoneDeletion: Sendable { case deleted, purged, encryptedDataReset }

/// A record fetched from iCloud, or returned by it in a conflict.
enum HistoryRemote: Sendable, Equatable {
    case dictation(HistoryRemoteRecord), settings(HistoryRemoteSettings)

    var formatVersion: Int {
        switch self {
        case .dictation(let record): record.formatVersion
        case .settings(let settings): settings.formatVersion
        }
    }
}

struct HistorySyncSent: Sendable, Equatable {
    var name: String
    var serverFields: Data
    var created: Date
}

enum HistorySyncFailure: Sendable, Equatable {
    /// iCloud has a newer copy than the one this save was based on.
    case conflict(HistoryRemote)
    case missingZone(String)
    /// iCloud no longer has the record this save changes.
    case gone(String)
    /// The person deleted gob.lin's data in Settings.
    case zoneDeletedByPerson
    case full(String)
    case tooBig(String)
    case other(String)
}

/// What `CKSyncEngine` reports, as plain values.
enum HistorySyncEvent: Sendable {
    case state(Data)
    case account(HistorySyncAccount)
    case zoneDeleted(HistorySyncZoneDeletion)
    case fetched([HistoryRemote], deletions: [String])
    case fetchFailed
    /// A fetch this engine asked for returned. The engine's own end-of-fetch event carries no error, so only this says
    /// whether it succeeded.
    case fetchFinished(succeeded: Bool)
    case sent([HistorySyncSent], deleted: [String], failed: [HistorySyncFailure])
    case sendFinished
}

struct HistorySyncBatch: Sendable {
    var saves: [(name: String, record: HistoryOutgoingRecord)] = []
    var deletions: [String] = []
    var count: Int { saves.count + deletions.count }
}

/// What the engine asks of CloudKit. `HistoryCloudKit` is the real one; the tests use a fake.
protocol HistorySyncTransport: Sendable {
    /// Adds changes the engine doesn't already have pending. The real engine schedules a send.
    func queue(_ changes: [HistorySyncChange]) async
    func unqueue(_ changes: [HistorySyncChange]) async
    func queueZone() async
    /// Starts a fetch. Its changes arrive as events, then `.fetchFinished` once the fetch has returned.
    func fetch() async
    /// Starts a send; batches come from `nextBatch`, results arrive as events, ending with `.sendFinished`.
    func send() async
    /// Every dictation record in the zone, by name, with when iCloud first saved it.
    func listDictations() async throws -> [String: Date]
    /// Who's signed in: their user record name, `.signedOut` with no account, nil when iCloud can't say right now.
    func account() async -> HistorySyncAccount?
    func stop() async
}
