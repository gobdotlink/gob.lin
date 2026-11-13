#if canImport(CloudKit)
import CloudKit
#if os(macOS)
import Security
#endif

extension HistorySyncEngine {
    /// Starts History sync, or returns nil without creating anything CloudKit when the switch is off or this app isn't
    /// entitled to gob.lin's iCloud container. Call `stop()` before letting it go.
    public static func start(store: HistoryStore,
                             retention: @escaping @Sendable () async -> HistoryRetention) async -> HistorySyncEngine? {
        guard (try? await store.isSyncEnabled()) == true, isAvailable() else { return nil }
        let engine = HistorySyncEngine(store: store, retention: retention)
        do {
            try await engine.begin { HistoryCloudKit(serialization: $0, owner: engine) }
        } catch {
            return nil
        }
        return engine
    }

    /// Whether this process may use gob.lin's iCloud container. Creating the container without the entitlement isn't
    /// safe, so local and unsigned builds, the CLI and the tests never get that far.
    public static func isAvailable() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerIdentifier) == true
        #else
        // iOS has no way to read a process's own entitlements. The iPhone app always carries them; its keyboard
        // extension must never call `start`.
        return true
        #endif
    }

    func isCurrent(_ engine: CKSyncEngine) -> Bool { (transport as? HistoryCloudKit)?.engine === engine }
}

extension HistorySync {
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: "History") }
    static let dictationType = "Dictation"
    static let settingsType = "Settings"

    /// The record to save: iCloud's last copy of it with the body written over it, or a new one.
    static func record(named name: String, _ outgoing: HistoryOutgoingRecord) -> CKRecord {
        let record = outgoing.serverFields.flatMap(Self.record(systemFields:))
            ?? CKRecord(recordType: name == settingsName ? settingsType : dictationType,
                        recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        record["body"] = outgoing.body
        record["format"] = formatVersion
        return record
    }

    static func record(systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A fetched record as History takes it, or nil for one that isn't History's. `created` stands in for the date
    /// iCloud sets, which a record made offline doesn't have.
    static func remote(_ record: CKRecord, created: Date? = nil) -> HistoryRemote? {
        let body = record["body"] as? Data ?? Data()
        let format = record["format"] as? Int ?? formatVersion
        switch record.recordType {
        case settingsType where record.recordID.recordName == settingsName:
            return .settings(HistoryRemoteSettings(body: body, formatVersion: format, serverFields: systemFields(record)))
        case dictationType:
            guard let id = UUID(uuidString: record.recordID.recordName) else { return nil }
            return .dictation(HistoryRemoteRecord(id: id, body: body, formatVersion: format, serverFields: systemFields(record),
                                                  serverCreated: created ?? record.creationDate ?? Date()))
        default:
            return nil
        }
    }

    /// What a failed save means for History. The engine retries network, account and rate-limit errors itself.
    static func failure(_ record: CKRecord, _ error: CKError) -> HistorySyncFailure {
        let name = record.recordID.recordName
        switch error.code {
        case .serverRecordChanged: return error.serverRecord.flatMap { remote($0) }.map(HistorySyncFailure.conflict) ?? .other(name)
        case .zoneNotFound: return .missingZone(name)
        case .unknownItem: return .gone(name)
        case .userDeletedZone: return .zoneDeletedByPerson
        case .quotaExceeded: return .full(name)
        case .limitExceeded: return .tooBig(name)
        default: return .other(name)
        }
    }
}

/// `CKSyncEngine` and the private database, for `HistorySyncEngine`.
struct HistoryCloudKit: HistorySyncTransport {
    let engine: CKSyncEngine
    private let container: CKContainer
    /// The engine holds its delegate weakly.
    private let delegate: Delegate

    init(serialization: Data?, owner: HistorySyncEngine) {
        container = CKContainer(identifier: HistorySyncEngine.containerIdentifier)
        delegate = Delegate(owner: owner)
        let state = serialization.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        engine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: delegate))
    }

    func queue(_ changes: [HistorySyncChange]) async {
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let new = changes.map(Self.pending).filter { !pending.contains($0) }
        if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
    }

    func unqueue(_ changes: [HistorySyncChange]) async {
        engine.state.remove(pendingRecordZoneChanges: changes.map(Self.pending))
    }

    func queueZone() async {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: HistorySync.zoneID))])
    }

    // Started, not awaited: the engine delivers their events to the delegate, which may be waiting on this call.
    func fetch() async { Task { [engine] in try? await engine.fetchChanges() } }

    func send() async { Task { [engine] in try? await engine.sendChanges() } }

    func stop() async { Task { [engine] in await engine.cancelOperations() } }

    func hasAccount() async -> Bool? {
        switch try? await container.accountStatus() {
        case .available: true
        case .noAccount: false
        default: nil
        }
    }

    func listDictations() async throws -> [String: Date] {
        var result: [String: Date] = [:], token: CKServerChangeToken?, more = true
        do {
            while more {
                let page = try await container.privateCloudDatabase.recordZoneChanges(inZoneWith: HistorySync.zoneID, since: token, desiredKeys: [])
                for (id, change) in page.modificationResultsByID {
                    guard case .success(let change) = change, change.record.recordType == HistorySync.dictationType,
                          let created = change.record.creationDate else { continue }
                    result[id.recordName] = created
                }
                token = page.changeToken
                more = page.moreComing
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }
        return result
    }

    private static func pending(_ change: HistorySyncChange) -> CKSyncEngine.PendingRecordZoneChange {
        switch change {
        case .save(let name): .saveRecord(CKRecord.ID(recordName: name, zoneID: HistorySync.zoneID))
        case .delete(let name): .deleteRecord(CKRecord.ID(recordName: name, zoneID: HistorySync.zoneID))
        }
    }

    /// Turns the engine's events into `HistorySyncEvent`s, ignoring an engine that has been replaced.
    final class Delegate: CKSyncEngineDelegate {
        let owner: HistorySyncEngine

        init(owner: HistorySyncEngine) { self.owner = owner }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            guard await owner.isCurrent(syncEngine) else { return }
            switch event {
            case .stateUpdate(let update):
                if let data = try? JSONEncoder().encode(update.stateSerialization) { await owner.handle(.state(data)) }
            case .accountChange(let change):
                switch change.changeType {
                case .signIn(let user): await owner.handle(.account(.signedIn(user.recordName)))
                case .signOut: await owner.handle(.account(.signedOut))
                case .switchAccounts(_, let user): await owner.handle(.account(.switched(user.recordName)))
                @unknown default: break
                }
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions where deletion.zoneID == HistorySync.zoneID {
                    let reason: HistorySyncZoneDeletion = switch deletion.reason {
                    case .purged: .purged
                    case .encryptedDataReset: .encryptedDataReset
                    default: .deleted
                    }
                    await owner.handle(.zoneDeleted(reason))
                }
            case .fetchedRecordZoneChanges(let changes):
                await owner.handle(.fetched(changes.modifications.compactMap { HistorySync.remote($0.record) },
                                            deletions: changes.deletions.filter { $0.recordType == HistorySync.dictationType }
                                                .map(\.recordID.recordName)))
            case .didFetchRecordZoneChanges(let result):
                if result.zoneID == HistorySync.zoneID, result.error != nil { await owner.handle(.fetchFailed) }
            case .didFetchChanges:
                await owner.handle(.fetchFinished)
            case .sentRecordZoneChanges(let sent):
                await owner.handle(.sent(sent.savedRecords.map {
                                             HistorySyncSent(name: $0.recordID.recordName, serverFields: HistorySync.systemFields($0),
                                                             created: $0.creationDate ?? Date())
                                         },
                                         // iCloud having no such record, or no zone, counts as deleted.
                                         deleted: sent.deletedRecordIDs.map(\.recordName)
                                             + sent.failedRecordDeletes.filter { [.unknownItem, .zoneNotFound].contains($0.value.code) }
                                                 .map(\.key.recordName),
                                         failed: sent.failedRecordSaves.map { HistorySync.failure($0.record, $0.error) }))
            case .didSendChanges:
                await owner.handle(.sendFinished)
            default:
                break
            }
        }

        func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                       syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
            guard await owner.isCurrent(syncEngine) else { return nil }
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
                .compactMap { change -> HistorySyncChange? in
                    switch change {
                    case .saveRecord(let id): .save(id.recordName)
                    case .deleteRecord(let id): .delete(id.recordName)
                    @unknown default: nil
                    }
                }
            guard let batch = await owner.nextBatch(pending) else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(
                recordsToSave: batch.saves.map { HistorySync.record(named: $0.name, $0.record) },
                recordIDsToDelete: batch.deletions.map { CKRecord.ID(recordName: $0, zoneID: HistorySync.zoneID) })
        }
    }
}
#endif
