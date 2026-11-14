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

/// Device kinds as History records them, and this device's own kind and name.
public enum HistoryDevice {
    public static let mac = "mac"
    public static let iPhone = "iphone"

    /// Read each time History opens, so a renamed Mac shows its new name.
    static func current() -> (kind: String, name: String) {
        #if os(macOS)
        (mac, Host.current().localizedName ?? "Mac")
        #else
        // ponytail: iOS names every iPhone "iPhone" without the user-assigned-device-name entitlement, so two iPhones
        // share one Insights row. Once it's granted, let the app pass UIDevice.current.name in.
        (iPhone, "iPhone")
        #endif
    }
}

public actor HistoryStore {
    public nonisolated let directory: URL
    /// This install's device, made once and kept in History's database. Entries saved here carry it.
    public nonisolated let deviceID: String
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
        self.deviceID = database.deviceID
    }

    /// Records a device's kind and name, so Insights can name the entries it made.
    public func saveDevice(id: String, kind: String, name: String) throws {
        try database.saveDevice(id: id, kind: kind, name: name)
    }

    /// Every recorded device's name, by its ID, so a dictation can say where it was made.
    public func deviceNames() throws -> [String: String] {
        try database.query("SELECT id, name FROM devices").reduce(into: [:]) { names, row in
            if let id = row[0], let name = row[1] { names[id] = name }
        }
    }

    /// Copy the original capture before trimming; the caller keeps it until this succeeds.
    @discardableResult
    public func insert(_ entry: HistoryEntry, untrimmedAudioURL: URL? = nil) throws -> HistoryEntry {
        var saved = entry
        saved.audioFilename = nil
        saved.device = saved.device ?? deviceID
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

    /// The latest dictations the user edited after pasting, newest first, for learning the terms they fix.
    public func editedDictations(limit: Int = 500) throws -> [HistoryEntry] {
        try database.query("SELECT metadata FROM entries WHERE json_extract(metadata, '$.editOutcome') = 'edited' AND json_extract(metadata, '$.editedText') IS NOT NULL ORDER BY created_at DESC, id DESC LIMIT ?",
                           [.number(Double(max(1, min(limit, 2000))))])
            .map { try decode($0[0]) }
    }

    /// Each app and project dictated into, for listing project words under their apps.
    public func dictionaryProjectUses() throws -> [DictionaryProjectUse] {
        let application = "json_extract(metadata, '$.dictionaryBundleIdentifier')", project = "json_extract(metadata, '$.dictionaryProject')"
        return try database.query("SELECT DISTINCT \(application), \(project) FROM entries WHERE \(application) IS NOT NULL AND \(project) IS NOT NULL")
            .compactMap { row in row[0].flatMap { app in row[1].map { DictionaryProjectUse(application: app, project: $0) } } }
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
    /// Supply a lower date bound for summaries that do not need all-time metrics, and a device ID for one device's entries.
    public func insights(now: Date = Date(), week: Date = Date(), calendar: Calendar = .current, since: Date? = nil,
                         device: String? = nil) throws -> HistoryInsights {
        var accumulator = HistoryInsightsAccumulator(now: now, week: week, calendar: calendar)
        let scope = insightScope(now: now, since: since, device: device)
        // Project only metrics; stream rows so transcripts and the full store never collect in memory.
        try database.forEachRow("""
            SELECT created_at, json_extract(metadata, '$.wordCount'), json_extract(metadata, '$.audioDuration'),
                   json_extract(metadata, '$.targetBundleIdentifier'), app_name, devices.kind, devices.name
            FROM entries LEFT JOIN devices ON devices.id = \(Self.entryDevice)
            WHERE \(scope.sql) ORDER BY created_at DESC, entries.id DESC
            """, [.text(deviceID)] + scope.values) { row in
            try Task.checkCancellation()
            guard let timestamp = Double(row[0] ?? ""), timestamp.isFinite else { return }
            accumulator.add(date: Date(timeIntervalSince1970: timestamp), words: max(0, Int(row[1] ?? "") ?? 0),
                            duration: row[2].flatMap(Double.init), bundle: row[3], name: row[4], deviceKind: row[5], deviceName: row[6])
        }
        return accumulator.finish()
    }

    /// Reads saved final text in the requested period, retaining only word counts.
    public func spokenWords(now: Date = Date(), calendar: Calendar = .current, period: InsightPeriod = .week, limit: Int = 40,
                            device: String? = nil) throws -> InsightWordCloud {
        let scope = insightScope(now: now, since: period.start(now: now, calendar: calendar), device: device)
        let counter = SpokenWordCounter()
        var counts: [String: Int] = [:], cloud = InsightWordCloud()
        try database.forEachRow("SELECT final_text FROM entries WHERE \(scope.sql)", scope.values) { row in
            try Task.checkCancellation()
            guard let text = row[0], !text.isEmpty else { return }
            cloud.entryCount += 1
            for word in counter.nouns(in: text) {
                counts[word, default: 0] += 1
            }
        }
        cloud.words = SpokenWordCounter.top(counts, limit: limit)
        return cloud
    }

    /// The device that made an entry, binding this device's ID for entries saved before devices were recorded.
    private static let entryDevice = "COALESCE(json_extract(metadata, '$.device'), ?)"

    /// Insights' WHERE clause: started by `now`, from `since`, and made on `device`.
    private func insightScope(now: Date, since: Date?, device: String?) -> (sql: String, values: [SQLValue]) {
        var sql = "created_at <= ?", values: [SQLValue] = [.number(now.timeIntervalSince1970)]
        if let since { sql += " AND created_at >= ?"; values.append(.number(since.timeIntervalSince1970)) }
        if let device { sql += " AND \(Self.entryDevice) = ?"; values += [.text(deviceID), .text(device)] }
        return (sql, values)
    }

    /// Record what became of the pasted text. `editedText` is stored only for
    /// the `edited` outcome; anything else clears it so a rewrite can never
    /// persist field contents that may no longer be the dictation.
    public func updateEditObservation(id: UUID, outcome: EditOutcome, editDistance: Int?,
                                      maximumEditDistance: Int?, editedText: String?) throws {
        try database.transaction {
            var saved = try entry(id: id)
            saved.editOutcome = outcome
            saved.editDistance = editDistance
            saved.maximumEditDistance = maximumEditDistance
            saved.editedText = outcome == .edited ? editedText : nil
            try update(saved, keys: HistorySync.editKeys, change: SyncPending.edit)
        }
    }

    public func setStarred(_ starred: Bool, id: UUID) throws {
        try database.transaction {
            var saved = try entry(id: id)
            saved.starred = starred
            try update(saved, keys: HistorySync.starredKeys, change: SyncPending.starred)
        }
    }

    /// Writes only `keys` into the stored JSON, so keys a newer gob.lin added on another device survive.
    private func update(_ entry: HistoryEntry, keys: [String], change: Int) throws {
        let id = entry.id.uuidString
        guard let stored = try database.query("SELECT metadata FROM entries WHERE id = ?", [.text(id)]).first?[0] else {
            throw HistoryError.entryNotFound
        }
        let metadata = try HistorySync.patch(stored, keys: keys, from: String(decoding: try JSONEncoder().encode(entry), as: UTF8.self))
        try database.run("UPDATE entries SET starred = ?, metadata = ? WHERE id = ?", [.number(entry.starred ? 1 : 0), .text(metadata), .text(id)])
        try recordChange(id, change)
    }

    public func audioFileURL(for id: UUID) throws -> URL? {
        guard let filename = try entry(id: id).audioFilename else { return nil }
        return try audioURL(filename: filename)
    }

    /// Deleting a dictation deletes it on every device: once iCloud has it, the deletion waits to be sent whether sync
    /// is on or off. While syncing, so does the deletion of this device's own dictation, whose upload may be on its way.
    /// A dictation that never left this device just disappears.
    public func delete(id: UUID) throws {
        try database.transaction {
            let saved = try entry(id: id)
            let audio = try saved.audioFilename.map { try audioURL(filename: $0) }
            if let audio { try removeAudioIfPresent(audio) }
            let send = try syncEnabled() && isOwn(id.uuidString)
            try database.run("DELETE FROM entries WHERE id = ?", [.text(id.uuidString)])
            if send {
                try database.run("INSERT INTO sync (id, pending) VALUES (?, \(SyncPending.delete)) ON CONFLICT(id) DO UPDATE SET pending = \(SyncPending.delete)",
                                 [.text(id.uuidString)])
            } else {
                try database.run("DELETE FROM sync WHERE id = ? AND server IS NULL", [.text(id.uuidString)])
                try database.run("UPDATE sync SET pending = \(SyncPending.delete) WHERE id = ?", [.text(id.uuidString)])
            }
        }
    }

    /// Count limits apply to unstarred entries; stars are never retention candidates.
    /// Retention trims only this device's copy: it sends no deletion, and iCloud and other devices keep the dictation.
    @discardableResult
    public func applyRetention(_ policy: HistoryRetention, now: Date = Date()) throws -> Int {
        try validate(policy)
        var removed = 0
        try database.transaction { removed = try trim(policy, now: now) }
        return removed
    }

    private func validate(_ policy: HistoryRetention) throws {
        if let count = policy.maximumUnstarredCount, count < 0 { throw HistoryError.invalidRetention }
        if let days = policy.maximumAgeDays, days < 1 { throw HistoryError.invalidRetention }
    }

    private func trim(_ policy: HistoryRetention, now: Date) throws -> Int {
        guard policy.maximumUnstarredCount != nil || policy.maximumAgeDays != nil else { return 0 }
        let cutoff = policy.maximumAgeDays.map { now.addingTimeInterval(-Double($0) * 86400) }
        let syncing = try syncEnabled()
        var removed = 0
        let rows = try database.query("""
            SELECT entries.id, entries.created_at, entries.audio_filename,
                   ((sync.server IS NULL AND \(Self.entryDevice) = ?) OR (COALESCE(sync.pending, 0) & \(SyncPending.edits)) != 0)
                   AND (COALESCE(sync.pending, 0) & \(SyncPending.localOnly)) = 0
            FROM entries LEFT JOIN sync ON sync.id = entries.id
            WHERE entries.starred = 0 ORDER BY entries.created_at DESC, entries.id DESC
            """, [.text(deviceID), .text(deviceID)])
        for (index, row) in rows.enumerated() {
            let tooMany = policy.maximumUnstarredCount.map { index >= $0 } ?? false
            let tooOld = cutoff.map { (Double(row[1] ?? "") ?? .infinity) < $0.timeIntervalSince1970 } ?? false
            guard tooMany || tooOld else { continue }
            // While syncing, a dictation iCloud hasn't confirmed may be the only copy of it, so it waits until it's sent,
            // unless it's too big to ever be sent. ponytail: Keep isn't enforced while uploads can't happen (signed
            // out, iCloud full).
            if syncing && row[3] == "1" { continue }
            let audio = try row[2].map { try audioURL(filename: $0) }
            if let audio { try removeAudioIfPresent(audio) }
            try database.run("DELETE FROM entries WHERE id = ? AND starred = 0", [.text(row[0]!)])
            try database.run("DELETE FROM sync WHERE id = ?", [.text(row[0]!)])
            removed += 1
        }
        return removed
    }

    // MARK: - Sync

    /// Whether this device syncs History. While it does, dictations iCloud hasn't confirmed are never trimmed.
    public func setSyncEnabled(_ enabled: Bool) throws {
        try database.setMeta(MetaKey.enabled, enabled ? "1" : nil)
    }

    public func isSyncEnabled() throws -> Bool { try syncEnabled() }

    /// The sync engine's own saved state, which History keeps without reading.
    func engineState() throws -> Data? { try database.meta(MetaKey.engine).flatMap { Data(base64Encoded: $0) } }

    func setEngineState(_ state: Data?) throws { try database.setMeta(MetaKey.engine, state?.base64EncodedString()) }

    /// A dictation too big for one iCloud record stays on this device: it's never sent, and Keep stops waiting for it.
    func markLocalOnly(id: UUID) throws {
        try database.run("INSERT INTO sync (id, pending) VALUES (?, \(SyncPending.localOnly)) ON CONFLICT(id) DO UPDATE SET pending = sync.pending | \(SyncPending.localOnly)",
                         [.text(id.uuidString)])
    }

    /// After signing out of iCloud: other devices' dictations belong to the account that left, so they go. This
    /// device's own stay with what iCloud knows of them, and so do unsent deletions and a Delete All's purge, in case
    /// the same account signs back in.
    @discardableResult
    func removeOtherDevices() throws -> Int {
        var removed = 0
        try database.transaction {
            for row in try database.query("SELECT id FROM entries WHERE \(Self.entryDevice) != ?", [.text(deviceID), .text(deviceID)]) {
                guard let id = row[0].flatMap(UUID.init(uuidString:)), try removeEntry(id) else { continue }
                try database.run("DELETE FROM sync WHERE id = ? AND (pending & \(SyncPending.delete)) = 0", [.text(id.uuidString)])
                removed += 1
            }
        }
        return removed
    }

    /// Call once the first complete fetch has been applied. Until then, a Delete All already in iCloud isn't applied to
    /// this device's own unsent dictations, which weren't part of what was cleared.
    public func markJoined() throws {
        try database.setMeta(MetaKey.joined, "1")
    }

    /// What this device still has to send.
    ///
    /// The engine must fetch before it sends. A device that was away during a Delete All learns of it from the fetch
    /// and drops its own unsent dictations from before it; sending first would put them back on every device.
    public func pendingChanges() throws -> HistoryPendingChanges {
        var changes = HistoryPendingChanges()
        changes.saves = try database.query("""
            SELECT entries.id FROM entries LEFT JOIN sync ON sync.id = entries.id
            WHERE ((sync.server IS NULL AND \(Self.entryDevice) = ?)
               OR (sync.server IS NOT NULL AND (sync.pending & \(SyncPending.edits)) != 0))
              AND (COALESCE(sync.pending, 0) & \(SyncPending.localOnly)) = 0
            ORDER BY entries.created_at DESC, entries.id DESC
            """, [.text(deviceID), .text(deviceID)]).compactMap { $0[0].flatMap(UUID.init(uuidString:)) }
        changes.deletions = try database.query("SELECT id FROM sync WHERE (pending & \(SyncPending.delete)) != 0")
            .compactMap { $0[0].flatMap(UUID.init(uuidString:)) }
        changes.settings = try database.meta(MetaKey.settingsPending) != nil
        changes.purgeThrough = try date(database.meta(MetaKey.purgeThrough))
        return changes
    }

    /// The record to send for a dictation, or nil when it's gone. It notes that the upload has started, so a change
    /// made before iCloud answers is sent afterwards even if sync is turned off meanwhile.
    public func outgoingRecord(id: UUID) throws -> HistoryOutgoingRecord? {
        try database.run("INSERT OR IGNORE INTO sync (id) SELECT id FROM entries WHERE id = ?", [.text(id.uuidString)])
        guard let row = try database.query("""
            SELECT entries.metadata, sync.server, COALESCE(sync.revision, 0), devices.kind, devices.name FROM entries
            LEFT JOIN sync ON sync.id = entries.id LEFT JOIN devices ON devices.id = \(Self.entryDevice) WHERE entries.id = ?
            """, [.text(deviceID), .text(id.uuidString)]).first, let metadata = row[0] else { return nil }
        let named = row[3].flatMap { kind in row[4].map { (kind: kind, name: $0) } }
        return HistoryOutgoingRecord(body: try HistorySync.body(metadata: metadata, device: deviceID, named: named),
                                     serverFields: row[1].flatMap { Data(base64Encoded: $0) }, revision: Int(row[2] ?? "") ?? 0)
    }

    public func outgoingSettings() throws -> HistoryOutgoingRecord {
        HistoryOutgoingRecord(body: try HistorySync.settingsBody(localSettings()),
                              serverFields: try database.meta(MetaKey.settingsServer).flatMap { Data(base64Encoded: $0) },
                              revision: Int(try database.meta(MetaKey.settingsRevision) ?? "") ?? 0)
    }

    /// iCloud saved the record `outgoingRecord` built at `revision`. Changes made since stay pending. A dictation
    /// deleted while its record was on its way becomes a deletion to send.
    public func markSent(id: UUID, serverFields: Data, serverCreated: Date, revision: Int) throws {
        try database.transaction {
            let exists = try !database.query("SELECT 1 FROM entries WHERE id = ?", [.text(id.uuidString)]).isEmpty
            try database.run("""
                INSERT INTO sync (id, server, created) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                    server = excluded.server, created = excluded.created,
                    pending = CASE WHEN sync.revision = ? THEN 0 ELSE sync.pending END
                """, [.text(id.uuidString), .text(serverFields.base64EncodedString()), .number(serverCreated.timeIntervalSince1970), .number(Double(revision))])
            if !exists { try database.run("UPDATE sync SET pending = \(SyncPending.delete) WHERE id = ?", [.text(id.uuidString)]) }
        }
    }

    /// iCloud deleted these records, or had no such record, which counts the same.
    public func markDeleted(ids: [UUID]) throws {
        try database.transaction {
            for id in ids { try database.run("DELETE FROM sync WHERE id = ? AND (pending & \(SyncPending.delete)) != 0", [.text(id.uuidString)]) }
        }
    }

    public func markSettingsSent(serverFields: Data, revision: Int) throws {
        try database.transaction {
            try database.setMeta(MetaKey.settingsServer, serverFields.base64EncodedString())
            if Int(try database.meta(MetaKey.settingsRevision) ?? "") ?? 0 == revision { try database.setMeta(MetaKey.settingsPending, nil) }
        }
    }

    /// The engine has removed every dictation iCloud saved at or before `through`.
    public func markPurged(through: Date) throws {
        try database.transaction {
            if let pending = try date(database.meta(MetaKey.purgeThrough)), pending <= through { try database.setMeta(MetaKey.purgeThrough, nil) }
        }
    }

    /// Deletes every dictation here, starred ones included, and, once this device has synced, on every device.
    ///
    /// It records a Delete All in the shared settings (`clearedThrough`), which every device applies, and a purge
    /// request in `pendingChanges().purgeThrough`. The engine must delete every dictation iCloud saved at or before
    /// that time, not only the ones this device holds: another device may hold dictations this one trimmed, and some
    /// may be held by none. It does that by listing the zone or by replacing it, then calls `markPurged`. The request
    /// survives relaunches until then.
    // ponytail: `now` is this device's clock and iCloud's dates are compared with it, so a clock that's far off moves
    // the line by as much; taking the time from iCloud is the upgrade if that ever shows up.
    public func deleteAll(now: Date = Date()) throws {
        try database.transaction {
            let synced = try syncEnabled() || database.meta(MetaKey.joined) != nil
                || !database.query("SELECT 1 FROM sync WHERE server IS NOT NULL LIMIT 1").isEmpty
            for row in try database.query("SELECT audio_filename FROM entries WHERE audio_filename IS NOT NULL") {
                if let filename = row[0] { try removeAudioIfPresent(try audioURL(filename: filename)) }
            }
            try database.run("DELETE FROM entries")
            try database.run("DELETE FROM sync")
            guard synced else { return }
            try database.setMeta(MetaKey.clearedThrough, String(now.timeIntervalSince1970))
            try database.setMeta(MetaKey.settingsPending, "1")
            try database.setMeta(MetaKey.settingsRevision, String((Int(try database.meta(MetaKey.settingsRevision) ?? "") ?? 0) + 1))
            try database.setMeta(MetaKey.purgeThrough, String(now.timeIntervalSince1970))
        }
    }

    /// Applies one page of fetched changes in one transaction: the settings, then deletions, then saves, then this
    /// device's Keep. A page can add deletions to send, so check `pendingChanges` after it.
    ///
    /// - Deletion wins. A fetched deletion removes the dictation even with unsent edits; a fetched save of a dictation
    ///   this device deleted stays deleted, and the deletion goes out again.
    /// - A save of a dictation with unsent edits keeps the server's record with this device's changed keys on top,
    ///   still to be sent. A save conflict goes through here too, with the server's record.
    /// - A record iCloud saved at or before the last Delete All is dropped here and its deletion queued.
    /// - `retention` is this device's Keep. A fetched dictation it would trim isn't kept, so a later fetch under the
    ///   same Keep, even a full one, never brings back what was trimmed. After Keep is raised,
    ///   `HistorySyncEngine.fetchAll()` does.
    @discardableResult
    public func applyRemote(saves: [HistoryRemoteRecord] = [], deletions: [UUID] = [], settings: HistoryRemoteSettings? = nil,
                            retention: HistoryRetention = HistoryRetention(), now: Date = Date()) throws -> HistoryRemoteResult {
        try validate(retention)
        var result = HistoryRemoteResult()
        try database.transaction {
            if let settings { try apply(settings, to: &result) }
            for id in deletions {
                if try removeEntry(id) { result.deleted += 1 }
                try database.run("DELETE FROM sync WHERE id = ?", [.text(id.uuidString)])
            }
            let cleared = try localSettings().clearedThrough
            for record in saves { try apply(record, clearedThrough: cleared, to: &result) }
            _ = try trim(retention, now: now)
        }
        return result
    }

    /// After a full fetch that started without saved sync state: a dictation kept here that iCloud had confirmed, but
    /// that the fetch didn't return, was deleted on another device, so it goes here too. Trimming leaves nothing
    /// behind, so a trimmed dictation can't be mistaken for a deleted one; this device's unsent dictations stay.
    @discardableResult
    public func deleteMissing(fetched: Set<UUID>) throws -> Int {
        var removed = 0
        try database.transaction {
            for row in try database.query("SELECT sync.id FROM sync JOIN entries ON entries.id = sync.id WHERE sync.server IS NOT NULL") {
                guard let id = row[0].flatMap(UUID.init(uuidString:)), !fetched.contains(id) else { continue }
                _ = try removeEntry(id)
                try database.run("DELETE FROM sync WHERE id = ?", [.text(id.uuidString)])
                removed += 1
            }
        }
        return removed
    }

    /// Forgets everything this device knew about iCloud, after a sign-out, an account switch or iCloud's copy being
    /// deleted. This device's own dictations stay, to upload again; one already in iCloud merges rather than
    /// duplicating. Other devices' dictations belong to the iCloud account and go, unless `keepingOthers`, when
    /// iCloud's copy was deleted and this one is all that's left. Unsent deletions and a Delete All's purge go too, as
    /// they belong to the old account, so the engine shouldn't call this when the same account signs back in.
    public func forgetServerState(keepingOthers: Bool) throws {
        try database.transaction {
            if !keepingOthers {
                for row in try database.query("SELECT id FROM entries WHERE \(Self.entryDevice) != ?", [.text(deviceID), .text(deviceID)]) {
                    if let id = row[0].flatMap(UUID.init(uuidString:)) { _ = try removeEntry(id) }
                }
            }
            try database.run("DELETE FROM sync")
            for key in [MetaKey.joined, MetaKey.engine, MetaKey.clearedThrough, MetaKey.settingsServer, MetaKey.settingsPending,
                        MetaKey.settingsRevision, MetaKey.purgeThrough] { try database.setMeta(key, nil) }
        }
    }

    private func apply(_ remote: HistoryRemoteSettings, to result: inout HistoryRemoteResult) throws {
        guard remote.formatVersion <= HistorySync.formatVersion else { result.skippedNewer += 1; return }
        guard let incoming = try? HistorySync.settings(body: remote.body) else { result.unreadable += 1; return }
        let local = try localSettings(), merged = local.merged(with: incoming)
        try database.setMeta(MetaKey.settingsServer, remote.serverFields.base64EncodedString())
        // Ours needs sending only while it's a Delete All iCloud hasn't seen.
        if merged == incoming { try database.setMeta(MetaKey.settingsPending, nil) }
        guard merged != local, let through = merged.clearedThrough else { return }
        try database.setMeta(MetaKey.clearedThrough, String(through.timeIntervalSince1970))
        result.deleted += try clear(through: through, ownUnsent: database.meta(MetaKey.joined) != nil)
    }

    /// Another device's Delete All: dictations iCloud saved at or before `through`, and, with `ownUnsent`, this device's
    /// own unsent ones started before it, starred or not. The device that deleted them purges iCloud, so nothing is sent.
    private func clear(through: Date, ownUnsent: Bool) throws -> Int {
        let time = SQLValue.number(through.timeIntervalSince1970)
        let rows = try database.query("""
            SELECT entries.id FROM entries LEFT JOIN sync ON sync.id = entries.id
            WHERE sync.created <= ? OR (? AND sync.server IS NULL AND entries.created_at <= ? AND \(Self.entryDevice) = ?)
            """, [time, .number(ownUnsent ? 1 : 0), time, .text(deviceID), .text(deviceID)])
        for row in rows {
            guard let id = row[0].flatMap(UUID.init(uuidString:)) else { continue }
            _ = try removeEntry(id)
            try database.run("DELETE FROM sync WHERE id = ?", [.text(id.uuidString)])
        }
        return rows.count
    }

    private func apply(_ record: HistoryRemoteRecord, clearedThrough: Date?, to result: inout HistoryRemoteResult) throws {
        guard record.formatVersion <= HistorySync.formatVersion else { result.skippedNewer += 1; return }
        let id = record.id.uuidString
        let pending = Int(try database.query("SELECT pending FROM sync WHERE id = ?", [.text(id)]).first?[0] ?? "") ?? 0
        if pending & SyncPending.delete != 0 { return }
        let server: [SQLValue] = [.text(record.serverFields.base64EncodedString()), .number(record.serverCreated.timeIntervalSince1970)]
        if let clearedThrough, record.serverCreated <= clearedThrough {
            if try removeEntry(record.id) { result.deleted += 1 }
            try database.run("INSERT INTO sync (id, server, created, pending) VALUES (?, ?, ?, \(SyncPending.delete)) ON CONFLICT(id) DO UPDATE SET server = excluded.server, created = excluded.created, pending = excluded.pending",
                             [.text(id)] + server)
            return
        }
        guard let incoming = try? HistorySync.metadata(body: record.body), incoming.entry.id == record.id else { result.unreadable += 1; return }
        // ponytail: the last record applied names its device, so after a rename a full fetch may show the old name
        // until that device sends again. Keep the date each device was named if that matters.
        if let device = incoming.entry.device, device != deviceID, let named = incoming.named {
            try database.saveDevice(id: device, kind: named.kind, name: named.name)
        }
        var metadata = incoming.metadata
        if let local = try database.query("SELECT metadata FROM entries WHERE id = ?", [.text(id)]).first?[0] {
            // The recording stays where it is; keys this device changed and iCloud hasn't confirmed go back on top.
            let keys = ["audioFilename"] + (pending & SyncPending.starred != 0 ? HistorySync.starredKeys : [])
                + (pending & SyncPending.edit != 0 ? HistorySync.editKeys : [])
            metadata = try HistorySync.patch(metadata, keys: keys, from: local)
            let entry = try decode(metadata)
            try database.run("UPDATE entries SET created_at = ?, raw_text = ?, final_text = ?, app_name = ?, starred = ?, metadata = ? WHERE id = ?",
                             [.number(entry.createdAt.timeIntervalSince1970), .text(entry.rawText), .text(entry.finalText),
                              .text(entry.targetApplicationName ?? ""), .number(entry.starred ? 1 : 0), .text(metadata), .text(id)])
        } else {
            let entry = incoming.entry
            try database.run("INSERT INTO entries (id, created_at, raw_text, final_text, app_name, starred, audio_filename, metadata) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
                             [.text(id), .number(entry.createdAt.timeIntervalSince1970), .text(entry.rawText), .text(entry.finalText),
                              .text(entry.targetApplicationName ?? ""), .number(entry.starred ? 1 : 0), .text(metadata)])
        }
        try database.run("INSERT INTO sync (id, server, created) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET server = excluded.server, created = excluded.created",
                         [.text(id)] + server)
        result.saved += 1
    }

    /// Notes a change iCloud must hear about: always for a dictation it has or whose upload has started, and while
    /// syncing for this device's own, which is about to be sent. With sync never turned on, nothing is written.
    private func recordChange(_ id: String, _ bit: Int) throws {
        let tracked = try !database.query("SELECT 1 FROM sync WHERE id = ?", [.text(id)]).isEmpty
        guard try tracked || (syncEnabled() && isOwn(id)) else { return }
        try database.run("INSERT INTO sync (id, pending, revision) VALUES (?, ?, 1) ON CONFLICT(id) DO UPDATE SET pending = sync.pending | excluded.pending, revision = sync.revision + 1",
                         [.text(id), .number(Double(bit))])
    }

    /// Removes a dictation and its recording; its `sync` row is the caller's to decide.
    private func removeEntry(_ id: UUID) throws -> Bool {
        guard let row = try database.query("SELECT audio_filename FROM entries WHERE id = ?", [.text(id.uuidString)]).first else { return false }
        if let filename = row[0] { try removeAudioIfPresent(try audioURL(filename: filename)) }
        try database.run("DELETE FROM entries WHERE id = ?", [.text(id.uuidString)])
        return true
    }

    private func isOwn(_ id: String) throws -> Bool {
        try database.query("SELECT \(Self.entryDevice) = ? FROM entries WHERE id = ?", [.text(deviceID), .text(deviceID), .text(id)]).first?[0] == "1"
    }

    private func syncEnabled() throws -> Bool { try database.meta(MetaKey.enabled) != nil }

    private func localSettings() throws -> HistorySyncSettings {
        HistorySyncSettings(clearedThrough: try date(database.meta(MetaKey.clearedThrough)))
    }

    private func date(_ value: String?) -> Date? { value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }

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

/// Bits in `sync.pending`: what iCloud hasn't confirmed yet.
private enum SyncPending {
    static let starred = 1, edit = 2, delete = 4, localOnly = 8
    static let edits = starred | edit
}

private enum MetaKey {
    static let enabled = "sync.enabled"
    static let joined = "sync.joined"
    static let engine = "sync.engine"
    static let purgeThrough = "sync.purgeThrough"
    static let clearedThrough = "settings.clearedThrough"
    static let settingsServer = "settings.server"
    static let settingsPending = "settings.pending"
    static let settingsRevision = "settings.revision"
}

// This connection belongs exclusively to HistoryStore's actor after initialization.
private final class HistoryDatabase {
    private var handle: OpaquePointer?
    private(set) var deviceID = ""

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
                // Added tables leave user_version at 1, so older builds still open History and ignore them.
                try run("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
                try run("CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL)")
                // What iCloud holds of each dictation: its record's system fields (base64), when iCloud first saved it,
                // the changes it hasn't confirmed, and a count of local changes so one made mid-upload isn't lost.
                try run("CREATE TABLE IF NOT EXISTS sync (id TEXT PRIMARY KEY NOT NULL, server TEXT, created REAL, pending INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0)")
                // An older build that trims or deletes leaves a row without its dictation. Trimming must never delete
                // everywhere, and the two can't be told apart, so such rows are forgotten rather than sent.
                try run("DELETE FROM sync WHERE (pending & 4) = 0 AND id NOT IN (SELECT id FROM entries)")
                try run("INSERT OR IGNORE INTO meta (key, value) VALUES ('device', ?)", [.text(UUID().uuidString)])
                guard let device = try query("SELECT value FROM meta WHERE key = 'device'").first?[0] else {
                    throw HistoryError.database("Missing device ID")
                }
                let current = HistoryDevice.current()
                try saveDevice(id: device, kind: current.kind, name: current.name)
                deviceID = device
            }
            try run("PRAGMA journal_mode = WAL")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func meta(_ key: String) throws -> String? {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first.flatMap { $0[0] }
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        } else {
            try run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func saveDevice(id: String, kind: String, name: String) throws {
        try run("INSERT INTO devices (id, kind, name) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name",
                [.text(id), .text(kind), .text(name)])
    }

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
