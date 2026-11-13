import Foundation
import Testing
@testable import GoblinCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { start.addingTimeInterval(-days * 86400) }

/// iCloud in miniature. Each record keeps the time it was first saved, as `CKRecord.creationDate` does; the engine's
/// part (fetch before send, purge after a Delete All) is played by `fetch` and `send`.
private struct Cloud {
    var records: [UUID: HistoryRemoteRecord] = [:]
    var settings: HistoryRemoteSettings?
    var now = start

    mutating func send(_ store: HistoryStore) async throws {
        let pending = try await store.pendingChanges()
        for id in pending.saves {
            guard let outgoing = try await store.outgoingRecord(id: id) else { continue }
            let created = records[id]?.serverCreated ?? now, fields = Data(UUID().uuidString.utf8)
            records[id] = HistoryRemoteRecord(id: id, body: outgoing.body, formatVersion: 1, serverFields: fields, serverCreated: created)
            try await store.markSent(id: id, serverFields: fields, serverCreated: created, revision: outgoing.revision)
        }
        for id in pending.deletions { records[id] = nil }
        try await store.markDeleted(ids: pending.deletions)
        if pending.settings {
            let outgoing = try await store.outgoingSettings(), fields = Data(UUID().uuidString.utf8)
            settings = HistoryRemoteSettings(body: outgoing.body, formatVersion: 1, serverFields: fields)
            try await store.markSettingsSent(serverFields: fields, revision: outgoing.revision)
        }
        if let through = pending.purgeThrough {
            records = records.filter { $0.value.serverCreated > through }
            try await store.markPurged(through: through)
        }
        now.addTimeInterval(60)
    }

    @discardableResult
    func fetch(_ store: HistoryStore, keep retention: HistoryRetention = HistoryRetention()) async throws -> HistoryRemoteResult {
        try await store.applyRemote(saves: Array(records.values), settings: settings, retention: retention, now: start)
    }

    mutating func edit(_ id: UUID, _ change: (inout [String: Any]) -> Void) throws {
        let record = records[id]!
        var object = try JSONSerialization.jsonObject(with: record.body) as! [String: Any]
        change(&object)
        records[id]!.body = try JSONSerialization.data(withJSONObject: object)
    }
}

private func ids(_ store: HistoryStore) async throws -> Set<UUID> { Set(try await store.entries(limit: 10_000).map(\.id)) }

@discardableResult
private func add(_ store: HistoryStore, _ text: String = "words", at date: Date = start, starred: Bool = false) async throws -> UUID {
    try await store.insert(HistoryEntry(rawText: text, finalText: text, createdAt: date, starred: starred)).id
}

final class HistorySyncTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-sync-test-" + UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore(_ directory: URL? = nil, syncing: Bool = true) async throws -> HistoryStore {
        let store = try HistoryStore(directory: directory ?? root.appendingPathComponent(UUID().uuidString))
        try await store.setSyncEnabled(syncing)
        return store
    }

    @Test func theBodyLeavesOutTheRecordingAndKeepsKeysItDoesNotKnow() throws {
        var entry = HistoryEntry(rawText: "a", finalText: "a")
        entry.audioFilename = "recording.wav"
        let stored = try HistorySync.patch(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self), keys: ["future"], from: #"{"future":"kept"}"#)
        let body = try JSONSerialization.jsonObject(with: try HistorySync.body(metadata: stored, device: "mac-1")) as! [String: Any]
        #expect(body["audioFilename"] == nil && body["device"] as? String == "mac-1" && body["future"] as? String == "kept")

        var object = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as! [String: Any]
        object["audioFilename"] = "../../escape"
        let incoming = try HistorySync.metadata(body: try JSONSerialization.data(withJSONObject: object))
        #expect(incoming.entry.audioFilename == nil && incoming.entry.device == HistorySync.unknownDevice)
        #expect(incoming.metadata.contains(#""future":"kept""#))
    }

    @Test func aSaveFromAnotherDeviceKeepsThisDevicesUnsentChangeAndKeysFromANewerBuild() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        let id = try await add(phone)
        try await cloud.send(phone)
        try cloud.edit(id) { $0["future"] = "kept" }
        try await cloud.fetch(mac)
        try await cloud.fetch(phone)

        try await mac.setStarred(true, id: id)
        try await phone.updateEditObservation(id: id, outcome: .edited, editDistance: 3, maximumEditDistance: 10, editedText: "edited")
        try await cloud.send(phone)
        try await cloud.fetch(mac)
        let merged = try await mac.entry(id: id)
        #expect(merged.starred && merged.editOutcome == .edited && merged.editedText == "edited")
        #expect(try await mac.pendingChanges().saves == [id])

        try await cloud.send(mac)
        try await cloud.fetch(phone)
        let settled = try await phone.entry(id: id)
        #expect(settled.starred && settled.editOutcome == .edited)
        #expect(String(decoding: cloud.records[id]!.body, as: UTF8.self).contains(#""future":"kept""#))
    }

    @Test func deletionWinsOverEditsAndSaves() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        let edited = try await add(phone, "edited"), deleted = try await add(phone, "deleted")
        try await cloud.send(phone)
        try await cloud.fetch(mac)

        // Deleted on the phone while the Mac has an unsent star: the deletion wins.
        try await mac.setStarred(true, id: edited)
        try await phone.delete(id: edited)
        try await cloud.send(phone)
        try await mac.applyRemote(deletions: [edited])
        #expect(try await ids(mac) == [deleted])
        #expect(try await mac.pendingChanges() == HistoryPendingChanges())

        // Deleted on the Mac, then a save arrives before the deletion is sent: it stays deleted and still goes out.
        try await mac.delete(id: deleted)
        try await cloud.fetch(mac)
        #expect(try await ids(mac).isEmpty)
        #expect(try await mac.pendingChanges().deletions == [deleted])
        // iCloud has no such record any more ("unknown item"): that counts as done.
        try await mac.markDeleted(ids: [deleted])
        #expect(try await mac.pendingChanges() == HistoryPendingChanges())
    }

    @Test func aDeletionWhileSyncIsOffIsSentButNothingIsRecordedBeforeSyncWasOn() async throws {
        var cloud = Cloud()
        let mac = try await makeStore()
        let sent = try await add(mac)
        try await cloud.send(mac)
        try await mac.setSyncEnabled(false)
        let local = try await add(mac)
        try await mac.setStarred(true, id: local)
        try await mac.delete(id: local)
        try await mac.delete(id: sent)
        #expect(try await mac.pendingChanges().deletions == [sent])

        let never = try await makeStore(syncing: false)
        let id = try await add(never)
        try await never.setStarred(true, id: id)
        try await never.updateEditObservation(id: id, outcome: .kept, editDistance: 0, maximumEditDistance: 1, editedText: nil)
        try await never.delete(id: id)
        #expect(try await never.pendingChanges() == HistoryPendingChanges())
    }

    @Test func changesMadeWhileAnUploadIsOnItsWayAreNotLost() async throws {
        let mac = try await makeStore()
        let starred = try await add(mac), deleted = try await add(mac)
        let first = try await mac.outgoingRecord(id: starred)!, second = try await mac.outgoingRecord(id: deleted)!
        try await mac.setStarred(true, id: starred)
        try await mac.delete(id: deleted)
        try await mac.markSent(id: starred, serverFields: Data("a".utf8), serverCreated: start, revision: first.revision)
        try await mac.markSent(id: deleted, serverFields: Data("b".utf8), serverCreated: start, revision: second.revision)
        #expect(try await mac.pendingChanges().saves == [starred])
        #expect(try await mac.pendingChanges().deletions == [deleted])
        #expect(try await mac.outgoingRecord(id: starred)!.serverFields == Data("a".utf8))

        // The same when sync is turned off before iCloud answers.
        let late = try await add(mac)
        let third = try await mac.outgoingRecord(id: late)!
        try await mac.setSyncEnabled(false)
        try await mac.setStarred(true, id: late)
        try await mac.markSent(id: late, serverFields: Data("c".utf8), serverCreated: start, revision: third.revision)
        #expect(Set(try await mac.pendingChanges().saves) == [starred, late])
    }

    @Test func aFullFetchAfterLostStateDeletesWhatWasDeletedElsewhereButNotWhatWasTrimmed() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        let deleted = try await add(phone, at: daysAgo(1)), old = try await add(phone, at: daysAgo(40)), kept = try await add(phone, at: daysAgo(2))
        try await cloud.send(phone)
        let keep = HistoryRetention(maximumAgeDays: 30)
        try await cloud.fetch(mac, keep: keep)
        #expect(try await ids(mac) == [deleted, kept])
        let unsent = try await add(mac)

        try await phone.delete(id: deleted)
        try await cloud.send(phone)
        // The Mac lost its change token: a full fetch, then whatever it held that iCloud didn't return goes.
        try await cloud.fetch(mac, keep: keep)
        #expect(try await mac.deleteMissing(fetched: Set(cloud.records.keys)) == 1)
        #expect(try await ids(mac) == [kept, unsent])
        #expect(!(try await ids(mac)).contains(old))
    }

    @Test func keepTrimsOnlyThisDeviceAndWaitsForUnsentDictations() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        let theirs = try await add(phone, at: daysAgo(10))
        try await cloud.send(phone)
        try await cloud.fetch(mac)
        let mine = try await add(mac, at: daysAgo(10))
        let keep = HistoryRetention(maximumAgeDays: 7)

        #expect(try await mac.applyRetention(keep, now: start) == 1)
        #expect(try await ids(mac) == [mine])
        #expect(try await mac.pendingChanges().deletions.isEmpty)
        #expect(cloud.records[theirs] != nil)

        try await cloud.send(mac)
        #expect(try await mac.applyRetention(keep, now: start) == 1)
        try await cloud.fetch(mac, keep: keep)
        #expect(try await ids(mac).isEmpty)
        #expect(cloud.records.count == 2)
        try await cloud.fetch(phone)
        #expect(try await ids(phone) == [theirs, mine])

        let off = try await makeStore(syncing: false)
        try await add(off, at: daysAgo(10))
        #expect(try await off.applyRetention(keep, now: start) == 1)
    }

    @Test func deleteAllReachesEveryDeviceAndThePurgeSurvivesARelaunch() async throws {
        var cloud = Cloud()
        let macDirectory = root.appendingPathComponent("mac")
        var mac = try await makeStore(macDirectory)
        let phone = try await makeStore()
        try await add(phone, starred: true)
        try await add(mac)
        try await cloud.send(phone)
        try await cloud.send(mac)
        try await cloud.fetch(mac)
        try await cloud.fetch(phone)
        try await mac.markJoined()
        try await phone.markJoined()
        let cleared = cloud.now
        let before = try await add(phone, at: cleared.addingTimeInterval(-1)), after = try await add(phone, at: cleared.addingTimeInterval(1))

        try await mac.deleteAll(now: cleared)
        #expect(try await ids(mac).isEmpty)
        mac = try await makeStore(macDirectory)
        #expect(try await mac.pendingChanges().purgeThrough == cleared)
        #expect(try await mac.pendingChanges().settings)
        try await cloud.send(mac)
        #expect(cloud.records.isEmpty)
        #expect(try await mac.pendingChanges() == HistoryPendingChanges())

        // The phone was away: its starred dictation goes, and so does an unsent one from before the Delete All.
        try await cloud.fetch(phone)
        #expect(try await ids(phone) == [after])
        #expect(!(try await ids(phone)).contains(before))
    }

    @Test func aJoiningDeviceKeepsItsDictationsAndRecordsFromBeforeADeleteAllAreDropped() async throws {
        var cloud = Cloud()
        let mac = try await makeStore()
        let stale = try await add(mac)
        try await cloud.send(mac)
        try await cloud.fetch(mac)
        try await mac.markJoined()
        try await mac.deleteAll(now: start)
        try await cloud.send(mac)

        // A record iCloud saved before the Delete All that the purge missed is dropped and deleted again.
        let missedEntry = String(decoding: try JSONEncoder().encode(HistoryEntry(id: stale, rawText: "stale", finalText: "stale")), as: UTF8.self)
        let missed = HistoryRemoteRecord(id: stale, body: try HistorySync.body(metadata: missedEntry, device: "phone"),
                                         formatVersion: 1, serverFields: Data(), serverCreated: start)
        try await mac.applyRemote(saves: [missed])
        #expect(try await ids(mac).isEmpty)
        #expect(try await mac.pendingChanges().deletions == [stale])

        // An iPad joining later keeps its own older dictations and sends them; the Mac keeps them too, because iCloud
        // saved them after the Delete All, whenever they were spoken.
        cloud.now = start.addingTimeInterval(3600)
        let iPad = try await makeStore()
        let older = try await add(iPad, at: daysAgo(3))
        // Its first fetch delivers that record on an earlier page than the Delete All; it goes all the same.
        try await iPad.applyRemote(saves: [missed])
        try await cloud.fetch(iPad)
        try await iPad.markJoined()
        try await cloud.send(iPad)
        try await cloud.fetch(mac)
        #expect(try await ids(iPad) == [older])
        #expect(try await ids(mac) == [older])
    }

    @Test func signingOutKeepsThisDevicesDictationsAndMergesThemBack() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        let mine = try await add(mac), theirs = try await add(phone)
        try await cloud.send(mac)
        try await cloud.send(phone)
        try await cloud.fetch(mac)

        try await mac.forgetServerState(keepingOthers: true)
        #expect(try await ids(mac) == [mine, theirs])
        try await mac.forgetServerState(keepingOthers: false)
        #expect(try await ids(mac) == [mine])
        #expect(try await mac.pendingChanges().saves == [mine])

        try await cloud.fetch(mac)
        #expect(try await ids(mac) == [mine, theirs])
        #expect(try await mac.pendingChanges() == HistoryPendingChanges())
    }

    @Test func eachDictationNamesItsDeviceSoInsightsCanShowIt() async throws {
        var cloud = Cloud()
        let mac = try await makeStore(), phone = try await makeStore()
        try await mac.saveDevice(id: mac.deviceID, kind: HistoryDevice.mac, name: "Studio")
        try await phone.saveDevice(id: phone.deviceID, kind: HistoryDevice.iPhone, name: "Pocket")
        let id = try await add(phone)
        try await cloud.send(phone)
        try await cloud.fetch(mac)
        // Insights tells devices apart by kind and name.
        let devices = { (store: HistoryStore) async throws in
            Set(try await store.insights(now: start.addingTimeInterval(3600)).devices.map(\.id))
        }
        #expect(try await devices(mac) == ["iphone:Pocket"])

        // A record names the device that made it, whichever device sends it; the name isn't kept in the dictation.
        try await mac.setStarred(true, id: id)
        try await cloud.send(mac)
        let body = try JSONSerialization.jsonObject(with: cloud.records[id]!.body) as! [String: Any]
        #expect(body["device"] as? String == phone.deviceID && body["deviceName"] as? String == "Pocket")
        #expect(try await mac.entry(id: id).starred)

        // A renamed device's next dictation carries the new name, and nobody can rename this device.
        try await phone.saveDevice(id: phone.deviceID, kind: HistoryDevice.iPhone, name: "Pocket 2")
        try await add(phone)
        try await add(mac)
        try await cloud.send(phone)
        try cloud.edit(id) { $0["device"] = mac.deviceID; $0["deviceName"] = "Impostor" }
        try await cloud.fetch(mac)
        #expect(try await devices(mac) == ["iphone:Pocket 2", "mac:Studio"])
    }

    @Test func recordsFromANewerBuildOrThatCantBeReadAreLeftOut() async throws {
        let mac = try await makeStore()
        let body = try HistorySync.body(metadata: String(decoding: try JSONEncoder().encode(HistoryEntry(rawText: "a", finalText: "a")), as: UTF8.self), device: "x")
        let result = try await mac.applyRemote(saves: [
            HistoryRemoteRecord(id: UUID(), body: body, formatVersion: HistorySync.formatVersion + 1, serverFields: Data(), serverCreated: start),
            HistoryRemoteRecord(id: UUID(), body: Data("not json".utf8), formatVersion: 1, serverFields: Data(), serverCreated: start),
        ], settings: HistoryRemoteSettings(body: Data(), formatVersion: HistorySync.formatVersion + 1, serverFields: Data()))
        #expect(result == HistoryRemoteResult(skippedNewer: 2, unreadable: 1))
        #expect(try await ids(mac).isEmpty)
    }
}
