import CSQLite
import Foundation

public enum HistoryFilter: Sendable, Hashable {
    case all, starred, withWarnings, application(String)
}

public struct HistoryCounts: Sendable, Equatable {
    public struct Application: Sendable, Equatable, Identifiable {
        public var name: String
        public var bundleIdentifier: String?
        public var count: Int
        public var id: String { name }
        public init(name: String, bundleIdentifier: String?, count: Int) {
            self.name = name; self.bundleIdentifier = bundleIdentifier; self.count = count
        }
    }
    public var total = 0
    public var starred = 0
    public var withWarnings = 0
    /// Seconds of recorded audio across every entry.
    public var totalSeconds: Double = 0
    public var applications: [Application] = []
    public init(total: Int = 0, starred: Int = 0, withWarnings: Int = 0, totalSeconds: Double = 0, applications: [Application] = []) {
        self.total = total; self.starred = starred; self.withWarnings = withWarnings; self.totalSeconds = totalSeconds; self.applications = applications
    }
}

public actor HistoryStore {
    public nonisolated let directory: URL
    private let database: HistoryDatabase

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("gob.lin", isDirectory: true)
    }

    public init(directory: URL? = nil) throws {
        let selectedDirectory = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        self.directory = selectedDirectory.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory.appendingPathComponent("audio", isDirectory: true),
                                               withIntermediateDirectories: true)
        let databaseURL = self.directory.appendingPathComponent("history.sqlite").resolvingSymlinksInPath()
        guard databaseURL.path.hasPrefix(self.directory.path + "/") else {
            throw HistoryError.database("History database must stay inside its data folder")
        }
        self.database = try HistoryDatabase(url: databaseURL)
    }

    /// Copy the original capture before trimming; the caller keeps it until this succeeds.
    @discardableResult
    public func insert(_ entry: HistoryEntry, untrimmedAudioURL: URL? = nil) throws -> HistoryEntry {
        var saved = entry
        saved.audioFilename = nil
        var copiedAudio: URL?
        if let source = untrimmedAudioURL {
            let sourceURL = source.resolvingSymlinksInPath()
            guard sourceURL.isFileURL, try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw HistoryError.invalidAudioFile
            }
            let suffix = source.pathExtension.lowercased()
            let safeExtension = !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? suffix : "audio"
            saved.audioFilename = "\(UUID().uuidString).\(safeExtension)"
            let destination = try audioURL(filename: saved.audioFilename!)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            copiedAudio = destination
        }
        do {
            let metadata = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            try database.run("INSERT INTO entries (id, created_at, raw_text, final_text, app_name, starred, audio_filename, metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                             [.text(saved.id.uuidString), .number(saved.createdAt.timeIntervalSince1970),
                              .text(saved.rawText), .text(saved.finalText), .text(saved.targetApplicationName ?? ""),
                              .number(saved.starred ? 1 : 0), saved.audioFilename.map(SQLValue.text) ?? .null, .text(metadata)])
            return saved
        } catch {
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
            throw error
        }
    }

    public func entries(matching query: String = "", filter: HistoryFilter = .all, limit: Int = 200, offset: Int = 0) throws -> [HistoryEntry] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        var values: [SQLValue] = [.text(pattern), .text(pattern), .text(pattern)]
        let scope: String
        switch filter {
        case .all: scope = ""
        case .starred: scope = " AND starred = 1"
        case .withWarnings: scope = " AND json_extract(metadata, '$.processingWarning') IS NOT NULL"
        case .application(let name): scope = " AND app_name = ?"; values.append(.text(name))
        }
        values += [.number(Double(max(1, min(limit, 2000)))), .number(Double(max(0, offset)))]
        return try database.query("SELECT metadata FROM entries WHERE (raw_text LIKE ? ESCAPE '\\' OR final_text LIKE ? ESCAPE '\\' OR app_name LIKE ? ESCAPE '\\')\(scope) ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?", values)
            .map { try decode($0[0]) }
    }

    /// Sizes of History's smart lists and per-app lists, busiest app first.
    public func counts() throws -> HistoryCounts {
        let totals = try database.query("SELECT COUNT(*), COALESCE(SUM(starred), 0), COALESCE(SUM(json_extract(metadata, '$.processingWarning') IS NOT NULL), 0), COALESCE(SUM(json_extract(metadata, '$.audioDuration')), 0) FROM entries").first ?? []
        let number = { (index: Int) in totals.indices.contains(index) ? Int(totals[index] ?? "") ?? 0 : 0 }
        let applications = try database.query("SELECT app_name, MAX(json_extract(metadata, '$.targetBundleIdentifier')), COUNT(*) FROM entries WHERE app_name != '' GROUP BY app_name ORDER BY COUNT(*) DESC, app_name")
            .compactMap { row in row[0].map { HistoryCounts.Application(name: $0, bundleIdentifier: row[1], count: Int(row[2] ?? "") ?? 0) } }
        let seconds = totals.indices.contains(3) ? Double(totals[3] ?? "") ?? 0 : 0
        return HistoryCounts(total: number(0), starred: number(1), withWarnings: number(2), totalSeconds: seconds, applications: applications)
    }

    public func entry(id: UUID) throws -> HistoryEntry {
        guard let row = try database.query("SELECT metadata FROM entries WHERE id = ?", [.text(id.uuidString)]).first else {
            throw HistoryError.entryNotFound
        }
        return try decode(row[0])
    }

    /// A single read snapshot of retained entries, independent of History search and pagination.
    /// `week` is any date in the calendar week the Activity charts show.
    /// Supply a lower date bound for summaries that do not need all-time metrics.
    public func insights(now: Date = Date(), week: Date = Date(), calendar: Calendar = .current, since: Date? = nil) throws -> HistoryInsights {
        var accumulator = HistoryInsightsAccumulator(now: now, week: week, calendar: calendar)
        let lowerBound = since == nil ? "" : " AND created_at >= ?"
        var values: [SQLValue] = [.number(now.timeIntervalSince1970)]
        if let since { values.append(.number(since.timeIntervalSince1970)) }
        // Project only metrics; stream rows so transcripts and the full store never collect in memory.
        try database.forEachRow("""
            SELECT created_at, json_extract(metadata, '$.wordCount'), json_extract(metadata, '$.audioDuration'),
                   json_extract(metadata, '$.targetBundleIdentifier'), app_name
            FROM entries WHERE created_at <= ?\(lowerBound) ORDER BY created_at DESC, id DESC
            """, values) { row in
            try Task.checkCancellation()
            guard let timestamp = Double(row[0] ?? ""), timestamp.isFinite else { return }
            accumulator.add(date: Date(timeIntervalSince1970: timestamp), words: max(0, Int(row[1] ?? "") ?? 0),
                            duration: row[2].flatMap(Double.init), bundle: row[3], name: row[4])
        }
        return accumulator.finish()
    }

    /// The nouns said most today and this calendar week. Reads saved final text from this week's rows only
    /// and keeps nothing but a word count.
    public func spokenWords(now: Date = Date(), calendar: Calendar = .current, limit: Int = 40) throws -> InsightWordCloud {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start.timeIntervalSince1970
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let counter = SpokenWordCounter()
        var week: [String: Int] = [:], day: [String: Int] = [:], cloud = InsightWordCloud()
        try database.forEachRow("SELECT created_at, final_text FROM entries WHERE created_at >= ? AND created_at <= ?",
                                [.number(weekStart), .number(now.timeIntervalSince1970)]) { row in
            try Task.checkCancellation()
            guard let timestamp = Double(row[0] ?? ""), let text = row[1], !text.isEmpty else { return }
            let isToday = timestamp >= today
            cloud.weekEntries += 1
            if isToday { cloud.todayEntries += 1 }
            for word in counter.nouns(in: text) {
                week[word, default: 0] += 1
                if isToday { day[word, default: 0] += 1 }
            }
        }
        cloud.week = SpokenWordCounter.top(week, limit: limit)
        cloud.today = SpokenWordCounter.top(day, limit: limit)
        return cloud
    }

    /// Record what became of the pasted text. `editedText` is stored only for
    /// the `edited` outcome; anything else clears it so a rewrite can never
    /// persist field contents that may no longer be the dictation.
    public func updateEditObservation(id: UUID, outcome: EditOutcome, editDistance: Int?,
                                      maximumEditDistance: Int?, editedText: String?) throws {
        var saved = try entry(id: id)
        saved.editOutcome = outcome
        saved.editDistance = editDistance
        saved.maximumEditDistance = maximumEditDistance
        saved.editedText = outcome == .edited ? editedText : nil
        let metadata = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        try database.run("UPDATE entries SET metadata = ? WHERE id = ?",
                         [.text(metadata), .text(id.uuidString)])
    }

    public func setStarred(_ starred: Bool, id: UUID) throws {
        var saved = try entry(id: id)
        saved.starred = starred
        let metadata = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        try database.run("UPDATE entries SET starred = ?, metadata = ? WHERE id = ?",
                         [.number(starred ? 1 : 0), .text(metadata), .text(id.uuidString)])
    }

    public func audioFileURL(for id: UUID) throws -> URL? {
        guard let filename = try entry(id: id).audioFilename else { return nil }
        return try audioURL(filename: filename)
    }

    public func delete(id: UUID) throws {
        try database.transaction {
            let saved = try entry(id: id)
            let audio = try saved.audioFilename.map { try audioURL(filename: $0) }
            if let audio { try removeAudioIfPresent(audio) }
            try database.run("DELETE FROM entries WHERE id = ?", [.text(id.uuidString)])
        }
    }

    /// Count limits apply to unstarred entries; stars are never retention candidates.
    @discardableResult
    public func applyRetention(_ policy: HistoryRetention, now: Date = Date()) throws -> Int {
        if let count = policy.maximumUnstarredCount, count < 0 { throw HistoryError.invalidRetention }
        if let days = policy.maximumAgeDays, days < 1 { throw HistoryError.invalidRetention }
        guard policy.maximumUnstarredCount != nil || policy.maximumAgeDays != nil else { return 0 }
        let cutoff = policy.maximumAgeDays.map { now.addingTimeInterval(-Double($0) * 86400) }
        var removed = 0
        try database.transaction {
            let rows = try database.query("SELECT id, created_at, audio_filename FROM entries WHERE starred = 0 ORDER BY created_at DESC, id DESC")
            for (index, row) in rows.enumerated() {
                let tooMany = policy.maximumUnstarredCount.map { index >= $0 } ?? false
                let tooOld = cutoff.map { (Double(row[1] ?? "") ?? .infinity) < $0.timeIntervalSince1970 } ?? false
                guard tooMany || tooOld else { continue }
                let audio = try row[2].map { try audioURL(filename: $0) }
                if let audio { try removeAudioIfPresent(audio) }
                try database.run("DELETE FROM entries WHERE id = ? AND starred = 0", [.text(row[0]!)])
                removed += 1
            }
        }
        return removed
    }

    private func removeAudioIfPresent(_ audio: URL) throws {
        do { try FileManager.default.removeItem(at: audio) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
    }

    private func audioURL(filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else {
            throw HistoryError.unsafeAudioPath
        }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let result = audioRoot.appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(directory.path + "/audio/"), result.path.hasPrefix(audioRoot.path + "/") else {
            throw HistoryError.unsafeAudioPath
        }
        return result
    }

    private func decode(_ value: String?) throws -> HistoryEntry {
        guard let value else { throw HistoryError.database("Missing entry metadata") }
        return try JSONDecoder().decode(HistoryEntry.self, from: Data(value.utf8))
    }
}

private enum SQLValue { case text(String), number(Double), null }

// This connection belongs exclusively to HistoryStore's actor after initialization.
private final class HistoryDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite"
            sqlite3_close(handle)
            handle = nil
            throw HistoryError.database(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        do {
            try transaction {
                let rows = try query("PRAGMA user_version")
                guard let value = rows.first?[0], let version = Int(value) else { throw HistoryError.database("Invalid schema version") }
                guard version <= 1 else { throw HistoryError.unsupportedSchema(version) }
                if version == 0 {
                    try run("CREATE TABLE entries (id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, raw_text TEXT NOT NULL, final_text TEXT NOT NULL, app_name TEXT NOT NULL, starred INTEGER NOT NULL DEFAULT 0, audio_filename TEXT, metadata TEXT NOT NULL)")
                    try run("CREATE INDEX entries_date ON entries(created_at DESC, id DESC)")
                    try run("PRAGMA user_version = 1")
                }
            }
            try run("PRAGMA journal_mode = WAL")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try query(sql, values)
    }

    func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String?]] {
        var rows: [[String?]] = []
        try forEachRow(sql, values) { rows.append($0) }
        return rows
    }

    func forEachRow(_ sql: String, _ values: [SQLValue] = [], _ body: ([String?]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let text):
                status = text.utf8CString.withUnsafeBufferPointer { buffer in
                    sqlite3_bind_text(statement, position, buffer.baseAddress, Int32(buffer.count - 1), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .number(let number): status = sqlite3_bind_double(statement, position, number)
            case .null: status = sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure() }
            try body((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
    }

    private func failure() -> HistoryError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection closed")
    }
}
