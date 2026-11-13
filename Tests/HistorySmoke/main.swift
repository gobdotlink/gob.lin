import CSQLite
import Foundation
import GoblinCore

@main
struct HistorySmoke {
    static func check(_ condition: Bool, _ message: String = "History smoke assertion failed") {
        precondition(condition, message)
    }

    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-history-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("untrimmed.wav")
        let bytes = Data([0, 1, 2, 3, 0, 0, 4])
        try bytes.write(to: source)
        let directory = temporary.appendingPathComponent("history", isDirectory: true)
        let store = try HistoryStore(directory: directory)
        let old = Date(timeIntervalSinceNow: -86400 * 60)
        let raw = "Raw, unchanged transcript.\n100% gob.lin"
        let first = try await store.insert(HistoryEntry(rawText: raw, finalText: "Clean transcript.",
                                                       targetBundleIdentifier: "test.synthetic", targetApplicationName: "Synthetic fixture",
                                                       createdAt: old, audioDuration: 2, model: "fixture", starred: true), untrimmedAudioURL: source)
        let second = try await store.insert(HistoryEntry(rawText: "Ordinary 1000 words", finalText: "Ordinary words", createdAt: old), untrimmedAudioURL: source)
        let third = try await store.insert(HistoryEntry(rawText: "Newest", finalText: "Newest"))
        check(first.audioFilename != second.audioFilename, "Capture filenames must never collide")
        let firstAudio = try await store.audioFileURL(for: first.id)!
        check(try Data(contentsOf: firstAudio) == bytes, "History must keep the untrimmed bytes")
        check(try Data(contentsOf: source) == bytes, "History must not move or trim the caller's capture")
        let reopened = try HistoryStore(directory: directory)
        check(try await reopened.entry(id: first.id) == first, "Every field must survive a reopen")
        let literalSearch = try await store.entries(matching: "100%")
        check(literalSearch.map(\.id) == [first.id], "Search metacharacters must be treated literally")
        let warned = try await store.insert(HistoryEntry(rawText: "Warned", finalText: "Warned", targetApplicationName: "Synthetic fixture",
                                                        processingWarning: "Not inserted"))
        check(try await store.entries(filter: .starred).map(\.id) == [first.id], "Starred must filter in the query")
        check(try await store.entries(filter: .withWarnings).map(\.id) == [warned.id], "Warnings must filter in the query")
        check(try await store.entries(filter: .application("Synthetic fixture")).map(\.id) == [warned.id, first.id], "Apps must filter in the query")
        let counts = try await store.counts()
        check(counts.total == 4 && counts.starred == 1 && counts.withWarnings == 1, "Counts must cover every entry")
        check(counts.applications == [HistoryCounts.Application(name: "Synthetic fixture", bundleIdentifier: "test.synthetic", count: 2)])
        try await store.delete(id: warned.id)
        let removed = try await store.applyRetention(HistoryRetention(maximumUnstarredCount: 1, maximumAgeDays: 30))
        check(removed == 1)
        let retained = try await store.entries()
        check(Set(retained.map(\.id)) == Set([first.id, third.id]), "Count and age limits must preserve stars")
        check(FileManager.default.fileExists(atPath: firstAudio.path), "Retention must keep starred audio")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio").appendingPathComponent(second.audioFilename!).path))

        // A malicious symlink must never let delete remove a file outside History.
        let outside = temporary.appendingPathComponent("outside.wav")
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: firstAudio)
        try FileManager.default.createSymbolicLink(at: firstAudio, withDestinationURL: outside)
        do { try await store.delete(id: first.id); preconditionFailure("Unsafe audio deletion was accepted") }
        catch HistoryError.unsafeAudioPath { }
        check(FileManager.default.fileExists(atPath: outside.path))
        check(try await store.entry(id: first.id) == first, "Unsafe deletion must leave the entry untouched")
        try FileManager.default.removeItem(at: firstAudio)
        try bytes.write(to: firstAudio)
        try await store.delete(id: first.id)
        check(!FileManager.default.fileExists(atPath: firstAudio.path))

        // Unknown migrations are rejected instead of silently resetting users' history.
        let newer = temporary.appendingPathComponent("newer", isDirectory: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        var database: OpaquePointer?
        check(sqlite3_open(newer.appendingPathComponent("history.sqlite").path, &database) == SQLITE_OK)
        check(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        do { _ = try HistoryStore(directory: newer); preconditionFailure("A future schema was accepted") }
        catch HistoryError.unsupportedSchema(99) { }

        // History from a build before devices: version 1, no device tables, an entry with no device.
        let older = temporary.appendingPathComponent("older", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let before = HistoryEntry(rawText: "Said before the update", finalText: "Said before the update", createdAt: Date(timeIntervalSinceNow: -60), audioDuration: 2)
        let metadata = String(decoding: try JSONEncoder().encode(before), as: UTF8.self)
        check(!metadata.contains("\"device\""), "An entry without a device must be written as older builds wrote it")
        check(sqlite3_open(older.appendingPathComponent("history.sqlite").path, &database) == SQLITE_OK)
        check(sqlite3_exec(database, """
            CREATE TABLE entries (id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, raw_text TEXT NOT NULL, final_text TEXT NOT NULL, app_name TEXT NOT NULL, starred INTEGER NOT NULL DEFAULT 0, audio_filename TEXT, metadata TEXT NOT NULL);
            CREATE INDEX entries_date ON entries(created_at DESC, id DESC);
            PRAGMA user_version = 1;
            INSERT INTO entries VALUES ('\(before.id.uuidString)', \(before.createdAt.timeIntervalSince1970), '\(before.rawText)', '\(before.finalText)', '', 0, NULL, '\(metadata)');
            """, nil, nil, nil) == SQLITE_OK)
        let upgraded = try HistoryStore(directory: older)
        check(integer(database, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('meta', 'devices', 'sync')") == 3, "Opening must add the device and sync tables")
        check(try HistoryStore(directory: older).deviceID == upgraded.deviceID, "This device's ID must be made once")
        check(try await upgraded.entry(id: before.id).device == nil, "An entry from before devices keeps no device")
        let olderInsights = try await upgraded.insights()
        check(olderInsights.devices.count == 1 && olderInsights.devices[0].kind == HistoryDevice.mac && olderInsights.devices[0].words == 4,
              "An entry without a device counts as this Mac's")
        check(try await upgraded.insights(device: upgraded.deviceID).totalWords == 4, "Filtering by this device must include entries without one")
        check(try await upgraded.spokenWords(period: .allTime, device: upgraded.deviceID).entryCount == 1)
        check(try await upgraded.insights(device: UUID().uuidString).totalWords == 0)
        // An older build checks only that the version is at most 1, then writes rows as it always has.
        check(integer(database, "PRAGMA user_version") == 1, "The device tables must leave the schema version for older builds")
        check(sqlite3_exec(database, "INSERT INTO entries (id, created_at, raw_text, final_text, app_name, starred, audio_filename, metadata) SELECT '\(UUID().uuidString)', created_at, raw_text, final_text, app_name, starred, audio_filename, metadata FROM entries", nil, nil, nil) == SQLITE_OK,
              "An older build must still save into upgraded History")
        sqlite3_close(database)
        check(try await upgraded.insights(device: upgraded.deviceID).totalWords == 8, "An older build's entries read as made here")
        // An older build trims a dictation iCloud has, leaving its sync row behind. Trimming must not delete it everywhere.
        try await upgraded.markSent(id: before.id, serverFields: Data([1]), serverCreated: Date(), revision: 0)
        check(sqlite3_open(older.appendingPathComponent("history.sqlite").path, &database) == SQLITE_OK)
        check(sqlite3_exec(database, "DELETE FROM entries WHERE id = '\(before.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
        check(try await HistoryStore(directory: older).pendingChanges().deletions.isEmpty, "A row an older build left behind must not become a deletion")
        check(integer(database, "SELECT COUNT(*) FROM sync") == 0 && integer(database, "PRAGMA user_version") == 1)
        sqlite3_close(database)

        // A first fetch of a long History, in pages of 250 as the engine hands them over.
        let synced = try HistoryStore(directory: temporary.appendingPathComponent("synced", isDirectory: true))
        try await synced.setSyncEnabled(true)
        let records = try (0..<20_000).map { index in
            var entry = HistoryEntry(rawText: "Fetched \(index)", finalText: "Fetched \(index)", createdAt: Date(timeIntervalSinceNow: -Double(index)))
            entry.device = "phone"
            return HistoryRemoteRecord(id: entry.id, body: try JSONEncoder().encode(entry), formatVersion: 1, serverFields: Data([1]), serverCreated: Date())
        }
        let clock = ContinuousClock(), started = clock.now
        for page in stride(from: 0, to: records.count, by: 250) {
            try await synced.applyRemote(saves: Array(records[page..<min(page + 250, records.count)]))
        }
        let fetchTime = clock.now - started
        check(fetchTime < .seconds(30), "Applying 20,000 fetched records took \(fetchTime)")
        check(try await synced.counts().total == 20_000, "Every fetched record must be kept")
        check(try await synced.pendingChanges().saves.isEmpty, "Fetched dictations must not be sent back")

        for index in 0..<1000 {
            try await store.insert(HistoryEntry(rawText: "Synthetic transcript \(index)", finalText: "Synthetic transcript \(index)"))
        }
        let pageOne = try await store.entries(limit: 200)
        let pageTwo = try await store.entries(limit: 200, offset: 200)
        check(pageOne.count == 200 && pageTwo.count == 200)
        check(Set(pageOne.map(\.id)).isDisjoint(with: pageTwo.map(\.id)), "History pagination must not duplicate entries")
        print("History safety smoke passed: persistence, original audio, stars, retention, deletion bounds, migration refusal, device and sync tables on older History, 1,000-entry pagination, 20,000 fetched records in \(fetchTime.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))).")
    }

    static func integer(_ database: OpaquePointer?, _ sql: String) -> Int {
        var statement: OpaquePointer?
        check(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        check(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
}
