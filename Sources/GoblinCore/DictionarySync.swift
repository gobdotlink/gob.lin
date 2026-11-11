import Foundation

/// The dictionary as it travels between a person's devices: every entry with when it last changed, and a marker for each
/// deleted one. Merging keeps the newer side of each entry, so copies can meet in any order, any number of times, and
/// every device settles on the same words. iCloud keeps only the last copy written, which is why the copy itself merges.
public struct SyncedDictionary: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var modified: Date
        /// Nil once deleted. The marker stays, so a device that still has the entry learns it is gone.
        var entry: DictionaryEntry?

        // ponytail: device clocks decide which edit is newer; a clock set wrong wins or loses edits to the same entry.
        func wins(over other: Record) -> Bool {
            if modified != other.modified { return modified > other.modified }
            guard let entry, let theirs = other.entry else { return entry == nil && other.entry != nil }
            // Same instant, different words: any rule works as long as every device applies the same one.
            return theirs.sortKey.lexicographicallyPrecedes(entry.sortKey)
        }
    }

    var version = 1
    /// Keyed by the entry's UUID string.
    // ponytail: deletion markers are never pruned (about 60 bytes each); prune by age if a copy nears iCloud's 1 MB.
    var records: [String: Record] = [:]

    public init() {}

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        // A newer gob.lin on another device may record things this one would drop.
        guard version == 1 else { throw DictionaryError.unsupportedVersion }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// One round of syncing. `entries` is this device's dictionary now, `state` what it last synced, and `remote` the
    /// copy in iCloud, if any. Returns the entries to keep, the state to save and whether iCloud needs it written.
    /// Save the entries before the state: saved the other way round, a crash in between would make entries from other
    /// devices look deleted here, and delete them everywhere.
    public static func reconcile(entries: [DictionaryEntry], state: Self, remote: Self?, now: Date = Date())
        throws -> (entries: [DictionaryEntry], state: Self, push: Bool) {
        var state = state
        state.adopt(entries, now: now)
        if let remote { state = state.merging(remote) }
        return (try DictionaryRepository.validated(state.applied(to: entries)), state, state != remote)
    }

    /// Notes what this device added, changed or deleted since the state was saved.
    mutating func adopt(_ entries: [DictionaryEntry], now: Date) {
        // Later than the stamp it replaces, so an edit here still wins when the other device's clock runs ahead.
        func stamp(_ id: String) -> Date { max(now, records[id].map { $0.modified.addingTimeInterval(0.001) } ?? now) }
        var local: Set<String> = []
        for entry in entries {
            let id = entry.id.uuidString
            local.insert(id)
            if records[id]?.entry != entry { records[id] = Record(modified: stamp(id), entry: entry) }
        }
        for (id, record) in records where record.entry != nil && !local.contains(id) {
            records[id] = Record(modified: stamp(id), entry: nil)
        }
    }

    func merging(_ other: Self) -> Self {
        var result = self
        for (id, theirs) in other.records where result.records[id].map(theirs.wins(over:)) ?? true {
            result.records[id] = theirs
        }
        // Two devices can each add the same word before they first meet. A spelling or alias belongs to one entry, so
        // the newer entry keeps it and the other is deleted, at its own stamp so the outcome is the same everywhere.
        // ponytail: the deleted entry's other aliases and scopes go with it; fold them into the winner if people miss them.
        var owned: Set<String> = []
        let live = result.records.compactMap { id, record in record.entry.map { (id: id, modified: record.modified, entry: $0) } }
            .sorted { ($0.modified, $0.id) > ($1.modified, $1.id) }
        for (id, modified, entry) in live {
            let keys = ([entry.spelling] + entry.aliases).map(dictionaryKey)
            if keys.contains(where: owned.contains) { result.records[id] = Record(modified: modified, entry: nil) }
            else { owned.formUnion(keys) }
        }
        return result
    }

    /// This device's entries after a merge: its own order kept, and entries from other devices added as its newest.
    func applied(to entries: [DictionaryEntry]) -> [DictionaryEntry] {
        let known = Set(entries.map(\.id.uuidString))
        let added = records.filter { !known.contains($0.key) }
            .compactMap { id, record in record.entry.map { (id: id, modified: record.modified, entry: $0) } }
            .sorted { ($0.modified, $0.id) < ($1.modified, $1.id) }
        return entries.compactMap { records[$0.id.uuidString]?.entry } + added.map(\.entry)
    }
}

private extension DictionaryEntry {
    var sortKey: [String] { [spelling] + aliases + ["\n"] + apps + ["\n"] + projects }
}
