import Foundation
import Synchronization
import Testing
@testable import GoblinCore
#if canImport(CloudKit)
import CloudKit
#endif

private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// `CKSyncEngine` and iCloud in miniature. Fetches and sends queue up in order and `run` plays them one at a time, as
/// the engine does. A failed save leaves the pending list unless it's one the engine retries itself (`.other` here).
private actor FakeCloud: HistorySyncTransport {
    struct Record { var body: Data, format = HistorySync.formatVersion, fields = Data(UUID().uuidString.utf8), created: Date }
    enum Operation { case fetch, send }

    var records: [String: Record] = [:]
    /// Record names in the order they changed; a name with no record is a deletion.
    var log: [String] = []
    var token = 0
    var pending: [HistorySyncChange] = []
    var operations: [Operation] = []
    var now = start
    var user: HistorySyncAccount? = .signedIn("person")
    var failing: [String: HistorySyncFailure] = [:]
    var listingFails = false
    var fetchFails = false
    var maximumBatchBytes = Int.max
    var beforeAcknowledging: (@Sendable () async throws -> Void)?
    var onStop: (@Sendable () async -> Void)?
    private(set) var fetches = 0, zonesQueued = 0, stops = 0
    private(set) var batches: [Int] = []
    /// Every record name ever saved.
    private(set) var everSaved: Set<String> = []
    /// Recorded as `connect` runs, which can't wait for this actor; the engine's side starts over from each one.
    private nonisolated let connectionLog = Mutex<[Data?]>([])
    private var adopted = 0
    nonisolated var connections: [Data?] { connectionLog.withLock { $0 } }

    nonisolated func connect(_ serialization: Data?) -> FakeCloud {
        connectionLog.withLock { $0.append(serialization) }
        return self
    }

    private func adopt() {
        let connections = connections
        guard connections.count > adopted else { return }
        adopted = connections.count
        token = connections.last!.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        pending = []
        operations = []
    }

    func queue(_ changes: [HistorySyncChange]) {
        adopt()
        let new = changes.filter { !pending.contains($0) }
        pending += new
        if !new.isEmpty { schedule(.send) }
    }

    func unqueue(_ changes: [HistorySyncChange]) { adopt(); pending.removeAll(where: changes.contains) }
    func queueZone() { adopt(); zonesQueued += 1 }
    func fetch() { adopt(); schedule(.fetch) }
    func send() { adopt(); schedule(.send) }
    func account() -> HistorySyncAccount? { adopt(); return user }
    func stop() async {
        stops += 1
        if let hook = onStop { onStop = nil; await hook() }
    }

    func listDictations() throws -> [String: Date] {
        if listingFails { throw CancellationError() }
        return records.filter { $0.key != HistorySync.settingsName }.mapValues(\.created)
    }

    private func schedule(_ operation: Operation) {
        if !operations.contains(operation) { operations.append(operation) }
    }

    /// Plays queued operations; false if they never ran out.
    @discardableResult
    func run(_ engine: HistorySyncEngine, limit: Int = 100) async -> Bool {
        for _ in 0..<limit {
            adopt()
            guard !operations.isEmpty else { return true }
            switch operations.removeFirst() {
            case .fetch: await fetch(into: engine)
            case .send: await send(from: engine)
            }
        }
        return operations.isEmpty
    }

    private func fetch(into engine: HistorySyncEngine) async {
        fetches += 1
        guard !fetchFails else { await engine.handle(.fetchFinished(succeeded: false)); return }
        // From no state, iCloud returns what exists and no deletions.
        var changes: [HistoryRemote] = [], deletions: [String] = []
        for name in Set(log[min(token, log.count)...]) {
            if let record = records[name] { changes.append(remote(name, record)) } else if token > 0 { deletions.append(name) }
        }
        token = log.count
        if !changes.isEmpty || !deletions.isEmpty { await engine.handle(.fetched(changes, deletions: deletions)) }
        await engine.handle(.state(Data(String(token).utf8)))
        await engine.handle(.fetchFinished(succeeded: true))
    }

    private func send(from engine: HistorySyncEngine) async {
        guard !pending.isEmpty else { return }
        while !pending.isEmpty, let batch = await engine.nextBatch(pending) {
            batches.append(batch.count)
            if let hook = beforeAcknowledging { beforeAcknowledging = nil; try? await hook() }
            var sent: [HistorySyncSent] = [], failed: [HistorySyncFailure] = []
            let tooBig = batch.saves.map(\.record.body.count).reduce(0, +) > maximumBatchBytes
            for (name, outgoing) in batch.saves {
                var failure: HistorySyncFailure? = tooBig ? .tooBig(name) : failing[name]
                if failure == nil, let existing = records[name], outgoing.serverFields != existing.fields {
                    failure = .conflict(remote(name, existing))
                }
                if failure == nil, records[name] == nil, outgoing.serverFields != nil { failure = .gone(name) }
                if let failure {
                    failed.append(failure)
                    if case .other = failure { continue }
                } else {
                    let record = Record(body: outgoing.body, created: records[name]?.created ?? now)
                    records[name] = record
                    log.append(name)
                    everSaved.insert(name)
                    sent.append(HistorySyncSent(name: name, serverFields: record.fields, created: record.created))
                }
                pending.removeAll { $0 == .save(name) }
            }
            for name in batch.deletions {
                pending.removeAll { $0 == .delete(name) }
                if records.removeValue(forKey: name) != nil { log.append(name) }
            }
            await engine.handle(.sent(sent, deleted: batch.deletions, failed: failed))
        }
        await engine.handle(.sendFinished)
        now.addTimeInterval(60)
    }

    func remote(_ name: String, _ record: Record) -> HistoryRemote {
        guard let id = UUID(uuidString: name) else {
            return .settings(HistoryRemoteSettings(body: record.body, formatVersion: record.format, serverFields: record.fields))
        }
        return .dictation(HistoryRemoteRecord(id: id, body: record.body, formatVersion: record.format, serverFields: record.fields,
                                              serverCreated: record.created))
    }

    /// Another device's dictation, saved now.
    @discardableResult
    func put(_ text: String = "theirs", device: String = "phone", format: Int = HistorySync.formatVersion) throws -> UUID {
        let entry = HistoryEntry(rawText: text, finalText: text, createdAt: now)
        let body = try HistorySync.body(metadata: String(decoding: try JSONEncoder().encode(entry), as: UTF8.self), device: device)
        records[entry.id.uuidString] = Record(body: body, format: format, created: now)
        log.append(entry.id.uuidString)
        return entry.id
    }

    func putDeleteAll(_ time: Date) throws {
        records[HistorySync.settingsName] = Record(body: try HistorySync.settingsBody(HistorySyncSettings(clearedThrough: time)), created: now)
        log.append(HistorySync.settingsName)
    }

    func edit(_ id: UUID, finalText: String) throws {
        var object = try JSONSerialization.jsonObject(with: records[id.uuidString]!.body) as! [String: Any]
        object["finalText"] = finalText
        records[id.uuidString]!.body = try JSONSerialization.data(withJSONObject: object)
        records[id.uuidString]!.fields = Data(UUID().uuidString.utf8)
        log.append(id.uuidString)
    }

    func remove(_ id: UUID) {
        records[id.uuidString] = nil
        log.append(id.uuidString)
    }

    /// iCloud's copy is gone, as after a reset.
    func wipe() { records = [:]; log = []; token = 0 }

    func set(user: HistorySyncAccount?) { self.user = user }
    func set(fetchFails: Bool) { self.fetchFails = fetchFails }
    func set(beforeAcknowledging: @escaping @Sendable () async throws -> Void) { self.beforeAcknowledging = beforeAcknowledging }
    func set(onStop: @escaping @Sendable () async -> Void) { self.onStop = onStop }
    func set(failing name: UUID, _ failure: HistorySyncFailure?) { failing[name.uuidString] = failure }
    func set(listingFails: Bool) { self.listingFails = listingFails }
    func set(maximumBatchBytes: Int) { self.maximumBatchBytes = maximumBatchBytes }
    func set(format: Int, of id: UUID) { records[id.uuidString]!.format = format }
    var dictations: Set<UUID> { Set(records.keys.compactMap(UUID.init(uuidString:))) }
}

private func ids(_ store: HistoryStore) async throws -> Set<UUID> { Set(try await store.entries(limit: 10_000).map(\.id)) }

/// This device's Keep, which the person can change while sync runs.
private actor Keep {
    var retention: HistoryRetention
    init(_ retention: HistoryRetention) { self.retention = retention }
    func set(_ retention: HistoryRetention) { self.retention = retention }
}

@discardableResult
private func add(_ store: HistoryStore, _ text: String = "mine", at date: Date = start) async throws -> UUID {
    try await store.insert(HistoryEntry(rawText: text, finalText: text, createdAt: date)).id
}

final class HistorySyncEngineTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-engine-test-" + UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore(syncing: Bool = true) async throws -> HistoryStore {
        let store = try HistoryStore(directory: root.appendingPathComponent(UUID().uuidString))
        try await store.setSyncEnabled(syncing)
        return store
    }

    private func makeEngine(_ store: HistoryStore, _ cloud: FakeCloud, keep: HistoryRetention = HistoryRetention()) async throws -> HistorySyncEngine {
        let engine = HistorySyncEngine(store: store, retention: { keep })
        try await engine.begin { cloud.connect($0) }
        return engine
    }

    /// A Mac and iCloud with one dictation each way, after its first full fetch.
    private func synced() async throws -> (HistoryStore, FakeCloud, HistorySyncEngine, mine: UUID, theirs: UUID) {
        let store = try await makeStore(), cloud = FakeCloud()
        let theirs = try await cloud.put(), mine = try await add(store)
        let engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == [mine, theirs])
        #expect(await cloud.dictations == [mine, theirs])
        return (store, cloud, engine, mine, theirs)
    }

    #if canImport(CloudKit)
    @Test func recordsAndSaveFailuresTranslate() throws {
        let id = UUID()
        let created = HistorySync.record(named: id.uuidString, HistoryOutgoingRecord(body: Data("one".utf8), serverFields: nil, revision: 0))
        #expect(created.recordType == "Dictation" && created.recordID.zoneID.zoneName == "History")
        guard case .dictation(let remote)? = HistorySync.remote(created, created: start) else { Issue.record("not a dictation"); return }
        #expect(remote.id == id && remote.body == Data("one".utf8) && remote.formatVersion == 1 && remote.serverCreated == start)
        // Later saves go against iCloud's copy, read back from its system fields.
        let again = HistorySync.record(named: id.uuidString, HistoryOutgoingRecord(body: Data("two".utf8), serverFields: remote.serverFields, revision: 1))
        #expect(again.recordID == created.recordID && again["body"] as? Data == Data("two".utf8))

        let settings = HistorySync.record(named: HistorySync.settingsName, HistoryOutgoingRecord(body: Data(), serverFields: nil, revision: 0))
        if case .settings? = HistorySync.remote(settings) {} else { Issue.record("not settings") }
        #expect(HistorySync.remote(CKRecord(recordType: "Other", recordID: created.recordID)) == nil)

        let name = id.uuidString
        let conflict = HistorySync.failure(created, CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: created]))
        if case .conflict(.dictation(let server)) = conflict { #expect(server.id == id) } else { Issue.record("not a conflict") }
        #expect(HistorySync.failure(created, CKError(.serverRecordChanged)) == .other(name))
        #expect(HistorySync.failure(created, CKError(.zoneNotFound)) == .missingZone(name))
        #expect(HistorySync.failure(created, CKError(.unknownItem)) == .gone(name))
        #expect(HistorySync.failure(created, CKError(.userDeletedZone)) == .zoneDeletedByPerson)
        #expect(HistorySync.failure(created, CKError(.quotaExceeded)) == .full(name))
        #expect(HistorySync.failure(created, CKError(.limitExceeded)) == .tooBig(name))
        #expect(HistorySync.failure(created, CKError(.networkFailure)) == .other(name))
    }

    @Test func nothingTouchesCloudKitWithoutTheEntitlementOrWithTheSwitchOff() async throws {
        #if os(macOS)
        #expect(!HistorySyncEngine.isAvailable())
        #endif
        let off = try await makeStore(syncing: false), on = try await makeStore()
        #expect(await HistorySyncEngine.start(store: off, retention: { HistoryRetention() }) == nil)
        #expect(await HistorySyncEngine.status(of: off) == .off)
        #if os(macOS)
        #expect(await HistorySyncEngine.start(store: on, retention: { HistoryRetention() }) == nil)
        #endif
        #expect(try await on.engineState() == nil)
    }
    #endif

    @Test func changesWaitForAFetchSoADeleteAllMadeElsewhereIsNeverUndone() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        try await store.markJoined()
        let before = try await add(store, at: start.addingTimeInterval(-3600))
        try await cloud.putDeleteAll(start)

        let engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(try await ids(store).isEmpty)
        #expect(await cloud.dictations.isEmpty)

        let after = try await add(store, at: start.addingTimeInterval(60))
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        #expect(await cloud.dictations == [after])
        #expect(await !cloud.everSaved.contains(before.uuidString))
    }

    @Test func aSaveThatKeepsFailingIsPacedByTheEngineNotRetriedHere() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        let id = try await add(store)
        await cloud.set(failing: id, .other(id.uuidString))
        let engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(await cloud.fetches == 1)

        // Each retry the engine schedules costs one fetch, and nothing here schedules more.
        for _ in 1...5 {
            await cloud.send()
            #expect(await cloud.run(engine))
        }
        #expect(await cloud.fetches == 6)
        #expect(try await store.pendingChanges().saves == [id])
    }

    @Test func aFullICloudPausesSendingUntilSyncNow() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        let first = try await add(store)
        await cloud.set(failing: first, .full(first.uuidString))
        let engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(await engine.status == .iCloudFull)

        let fetches = await cloud.fetches
        let second = try await add(store)
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        #expect(await cloud.fetches == fetches)
        #expect(await cloud.dictations.isEmpty)

        await cloud.set(failing: first, nil)
        await engine.syncNow()
        #expect(await cloud.run(engine))
        #expect(await cloud.dictations == [first, second])
        #expect(await engine.status == .syncing)
    }

    @Test func aDeleteAllHereListsTheZoneAndFinishesAfterARelaunch() async throws {
        let (store, cloud, first, _, theirs) = try await synced()
        var engine = first
        await cloud.set(listingFails: true)
        let through = await cloud.now
        try await store.deleteAll(now: through)
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        // The Mac no longer holds the phone's dictation, so only listing the zone finds it.
        #expect(await cloud.dictations.contains(theirs))
        #expect(try await store.pendingChanges().purgeThrough == through)

        await engine.stop()
        await cloud.set(listingFails: false)
        engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(await cloud.dictations.isEmpty)
        await engine.syncNow()
        #expect(await cloud.run(engine))
        #expect(try await store.pendingChanges().purgeThrough == nil)
    }

    @Test func iCloudLosingHistoryKeepsItHereAndAResetUploadsItAgain() async throws {
        #expect(HistorySyncEngine.outcome(of: .purged) == .keepAndTurnOff)
        #expect(HistorySyncEngine.outcome(of: .deleted) == .keepAndTurnOff)
        #expect(HistorySyncEngine.outcome(of: .encryptedDataReset) == .uploadAgain)

        let (store, cloud, engine, mine, theirs) = try await synced()
        await engine.handle(.zoneDeleted(.purged))
        #expect(try await ids(store) == [mine, theirs])
        #expect(try await !store.isSyncEnabled())
        #expect(await cloud.stops == 1)
        await engine.stop()
        var updates: [HistorySyncUpdate] = []
        for await update in engine.updates { updates.append(update) }
        #expect(updates.last == .status(.purged))
        #expect(await HistorySyncEngine.status(of: store) == .purged)

        // A star on another device's dictation was queued before the reset; only what History says is pending goes up.
        let (other, otherCloud, otherEngine, otherMine, otherTheirs) = try await synced()
        try await other.setStarred(true, id: otherTheirs)
        await otherEngine.historyChanged()
        await otherCloud.wipe()
        await otherEngine.handle(.zoneDeleted(.encryptedDataReset))
        #expect(await otherCloud.run(otherEngine))
        #expect(try await ids(other) == [otherMine, otherTheirs])
        #expect(await otherCloud.dictations == [otherMine])
        #expect(await otherEngine.status == .syncing)
    }

    @Test func onlyARealSignOutRemovesOtherDevicesDictations() async throws {
        let (store, cloud, first, mine, theirs) = try await synced()
        var engine = first
        let deleted = try await add(store, "deleted")
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        try await store.delete(id: deleted)

        // iCloud can't say, or the account is restricted: wait, removing nothing.
        await engine.stop()
        await cloud.set(user: nil)
        engine = try await makeEngine(store, cloud)
        #expect(await engine.status == .waitingForAccount)
        #expect(try await ids(store) == [mine, theirs])

        await engine.handle(.account(.signedOut))
        #expect(await engine.status == .waitingForAccount)
        #expect(try await ids(store) == [mine])
        #expect(try await store.pendingChanges().deletions == [deleted])

        // The same person signs back in, after another device deleted this one's dictation.
        await cloud.remove(mine)
        let connections = cloud.connections.count
        await engine.handle(.account(.signedIn("person")))
        #expect(cloud.connections.count == connections + 1)
        #expect(cloud.connections.last! == nil)
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == [theirs])
        #expect(await cloud.dictations == [theirs])
        #expect(await engine.status == .syncing)

        // Someone else signs in: this device's History doesn't join their account.
        let kept = try await add(store, "kept")
        await engine.handle(.account(.switched("someone else")))
        #expect(try await ids(store) == [kept])
        #expect(try await store.pendingChanges().saves == [kept])
        #expect(try await !store.isSyncEnabled())
        #expect(await engine.status == .differentAccount)
        #expect(await HistorySyncEngine.status(of: store) == .differentAccount)
    }

    @Test func failedSavesMergeLoseToADeletionOrWait() async throws {
        let (store, cloud, engine, mine, _) = try await synced()

        // iCloud has a newer copy: merge it and send again from it.
        try await store.setStarred(true, id: mine)
        try await cloud.edit(mine, finalText: "edited elsewhere")
        let server = await cloud.remote(mine.uuidString, cloud.records[mine.uuidString]!)
        await engine.handle(.sent([], deleted: [], failed: [.conflict(server)]))
        #expect(await cloud.run(engine))
        let merged = try JSONSerialization.jsonObject(with: await cloud.records[mine.uuidString]!.body) as! [String: Any]
        #expect(merged["starred"] as? Bool == true && merged["finalText"] as? String == "edited elsewhere")
        #expect(try await store.pendingChanges() == HistoryPendingChanges())

        // iCloud no longer has it: deleted elsewhere, so it goes here too.
        await engine.handle(.sent([], deleted: [], failed: [.gone(mine.uuidString)]))
        #expect(try await !ids(store).contains(mine))

        // No zone: made only after a fetch that doesn't say it was deleted.
        let zones = await cloud.zonesQueued
        await engine.handle(.sent([], deleted: [], failed: [.missingZone(mine.uuidString)]))
        #expect(await cloud.zonesQueued == zones)
        await engine.syncNow()
        #expect(await cloud.run(engine))
        #expect(await cloud.zonesQueued == zones + 1)

        // The person deleted gob.lin's data in Settings.
        await engine.handle(.sent([], deleted: [], failed: [.zoneDeletedByPerson]))
        #expect(await engine.status == .purged)
        #expect(try await !ids(store).isEmpty)
    }

    @Test func batchesStayWithinLimitsAndADictationTooBigForICloudStaysHere() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        for _ in 0..<300 { try await add(store) }
        let engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(await cloud.batches == [250, 50])

        let big = try await add(store, String(repeating: "a", count: HistorySyncEngine.maximumBody), at: start.addingTimeInterval(-60))
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        #expect(await !cloud.dictations.contains(big))
        #expect(try await store.pendingChanges().saves.isEmpty)
        #expect(try await store.applyRetention(HistoryRetention(maximumUnstarredCount: 300)) == 1)
        #expect(try await !ids(store).contains(big))

        // iCloud says a request is too big: smaller batches until it fits, halving once per request.
        await cloud.set(maximumBatchBytes: 40_000)
        for _ in 0..<100 { try await add(store, String(repeating: "b", count: 1000)) }
        let batches = await cloud.batches.count
        await engine.historyChanged()
        #expect(await cloud.run(engine))
        #expect(await cloud.dictations.count == 400)
        let smaller = Array(await cloud.batches.dropFirst(batches))
        #expect(smaller.count < 20, "\(smaller)")
    }

    @Test func dictationsFromANewerBuildWaitForAnUpdateThenArriveWithAFullFetch() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        let newer = try await cloud.put(format: HistorySync.formatVersion + 1)
        var engine = try await makeEngine(store, cloud)
        #expect(await cloud.run(engine))
        #expect(await engine.status == .needsUpdate)
        #expect(try await ids(store).isEmpty)
        await engine.stop()
        #expect(await HistorySyncEngine.status(of: store) == .needsUpdate)

        // This build now reads that format.
        var saved = try JSONDecoder().decode(HistorySyncEngine.Saved.self, from: try #require(try await store.engineState()))
        saved.newerFormat = HistorySync.formatVersion
        try await store.setEngineState(JSONEncoder().encode(saved))
        await cloud.set(format: HistorySync.formatVersion, of: newer)
        engine = try await makeEngine(store, cloud)
        #expect(cloud.connections.last! == nil)
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == [newer])
        #expect(await engine.status == .syncing)
    }

    @Test func stoppingWhileSyncTurnsItselfOffStillReportsTheCleanup() async throws {
        let (store, cloud, engine, mine, _) = try await synced()
        // The app stops the engine as soon as it hears the status, while the engine is still removing their dictations.
        await cloud.set(onStop: { await engine.stop() })
        await engine.handle(.account(.switched("someone else")))
        var updates: [HistorySyncUpdate] = []
        for await update in engine.updates { updates.append(update) }
        #expect(updates.suffix(2) == [.status(.differentAccount), .historyChanged])
        #expect(try await ids(store) == [mine])
    }

    @Test func raisingKeepFetchesEverythingAgainAndBringsBackWhatItLeftOut() async throws {
        #expect(HistoryRetention(maximumUnstarredCount: 2).keepsMore(than: HistoryRetention(maximumUnstarredCount: 1)))
        #expect(HistoryRetention(maximumAgeDays: 7).keepsMore(than: HistoryRetention(maximumAgeDays: 7)) == false)
        #expect(HistoryRetention().keepsMore(than: HistoryRetention(maximumAgeDays: 30)))
        #expect(HistoryRetention(maximumAgeDays: 7).keepsMore(than: HistoryRetention()) == false)

        let store = try await makeStore(), cloud = FakeCloud(), keep = Keep(HistoryRetention(maximumUnstarredCount: 1))
        try await cloud.put("older")
        try await cloud.put("newer")
        let engine = HistorySyncEngine(store: store, retention: { await keep.retention })
        try await engine.begin { cloud.connect($0) }
        #expect(await cloud.run(engine))
        #expect(try await ids(store).count == 1)

        // Fetching changes alone can't bring it back: iCloud has nothing new.
        await keep.set(HistoryRetention())
        await engine.syncNow()
        #expect(await cloud.run(engine))
        #expect(try await ids(store).count == 1)

        await engine.fetchAll()
        #expect(cloud.connections.last! == nil)
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == (await cloud.dictations))
        #expect(await engine.status == .syncing)
    }

    @Test func theAccountIsKnownFromTheStartAndADifferentOneTurnsSyncOff() async throws {
        let (store, cloud, engine, mine, _) = try await synced()
        let saved = try JSONDecoder().decode(HistorySyncEngine.Saved.self, from: try #require(try await store.engineState()))
        #expect(saved.account == "person")
        await engine.stop()

        // Someone else is signed in at the next launch, and the engine never says so.
        await cloud.set(user: .signedIn("someone else"))
        let batches = await cloud.batches.count
        let next = try await makeEngine(store, cloud)
        #expect(await next.status == .differentAccount)
        #expect(try await ids(store) == [mine])
        #expect(try await !store.isSyncEnabled())
        #expect(await cloud.run(next))
        #expect(await cloud.batches.count == batches)
    }

    @Test func nothingIsSentUntilICloudSaysWhoIsSignedIn() async throws {
        for (next, sends) in [("someone else", false), ("person", true)] {
            let (store, cloud, engine, _, _) = try await synced()
            await engine.stop()
            let new = try await add(store, "new")

            // iCloud has an account but can't say whose: fetched changes may arrive, nothing goes up.
            await cloud.set(user: nil)
            let fetches = await cloud.fetches, batches = await cloud.batches.count
            let relaunched = try await makeEngine(store, cloud)
            #expect(await cloud.run(relaunched))
            #expect(await cloud.fetches > fetches)
            #expect(await cloud.batches.count == batches)
            #expect(await relaunched.status == .waitingForAccount)

            await cloud.set(user: .signedIn(next))
            await relaunched.syncNow()
            #expect(await cloud.run(relaunched))
            #expect(await cloud.dictations.contains(new) == sends)
            #expect(try await store.isSyncEnabled() == sends)
            #expect(await relaunched.status == (sends ? .syncing : .differentAccount))
        }
    }

    @Test func aFetchThatFailsRemovesNothingAndSendsNothing() async throws {
        let (store, cloud, engine, mine, theirs) = try await synced()
        let new = try await add(store, "new")
        await cloud.set(fetchFails: true)
        // The same person signing back in starts a full fetch, which fails without naming a zone.
        await engine.handle(.account(.signedIn("person")))
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == [mine, theirs, new])
        #expect(await !cloud.dictations.contains(new))

        await cloud.set(fetchFails: false)
        await engine.syncNow()
        #expect(await cloud.run(engine))
        #expect(try await ids(store) == [mine, theirs, new])
        #expect(await cloud.dictations == [mine, theirs, new])
    }

    @Test func aChangeMadeWhileItsRecordIsOnItsWayStillGoesOut() async throws {
        let (store, cloud, engine, mine, _) = try await synced()
        try await store.setStarred(true, id: mine)
        await engine.historyChanged()
        await cloud.set(beforeAcknowledging: { try await store.setStarred(false, id: mine) })
        #expect(await cloud.run(engine))
        let body = try JSONSerialization.jsonObject(with: await cloud.records[mine.uuidString]!.body) as! [String: Any]
        #expect(body["starred"] as? Bool == false)
        #expect(try await store.pendingChanges() == HistoryPendingChanges())
    }

    @Test func aFullFetchCutShortStartsOverAtTheNextLaunch() async throws {
        let store = try await makeStore(), cloud = FakeCloud()
        var engine = try await makeEngine(store, cloud)
        await engine.handle(.state(Data("5".utf8)))
        await engine.stop()

        engine = try await makeEngine(store, cloud)
        #expect(cloud.connections == [nil, nil])
        #expect(await cloud.run(engine))
        await engine.stop()

        engine = try await makeEngine(store, cloud)
        #expect(cloud.connections.last! != nil)
        await engine.stop()
    }
}
