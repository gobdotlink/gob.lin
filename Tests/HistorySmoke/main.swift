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

        for index in 0..<1000 {
            try await store.insert(HistoryEntry(rawText: "Synthetic transcript \(index)", finalText: "Synthetic transcript \(index)"))
        }
        let pageOne = try await store.entries(limit: 200)
        let pageTwo = try await store.entries(limit: 200, offset: 200)
        check(pageOne.count == 200 && pageTwo.count == 200)
        check(Set(pageOne.map(\.id)).isDisjoint(with: pageTwo.map(\.id)), "History pagination must not duplicate entries")
        print("History safety smoke passed: persistence, original audio, stars, retention, deletion bounds, migration refusal, 1,000-entry pagination.")
    }
}
