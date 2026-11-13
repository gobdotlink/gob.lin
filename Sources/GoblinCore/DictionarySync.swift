import Foundation

/// The dictionary as it travels between a person's devices: every entry with when it last changed, and a marker for each
/// deleted one. Merging keeps the newer side of each entry, so copies can meet in any order, any number of times, and
/// every device settles on the same words. iCloud keeps only the last copy written, which is why the copy itself merges.
public struct SyncedDictionary: Codable, Equatable, Sendable {
    /// Where the copy lives in the iCloud key-value store, shared by every device.
    public static let cloudKey = "dictionary"

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

    /// Raise this when `DictionaryEntry` gains a field: an older gob.lin would drop the field from every entry it
    /// writes back, so it must refuse the copy instead, as `DictionaryRepository` does for the file.
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

    /// The entries a dictionary shows: every record that isn't deleted, except that a spelling or alias belongs to one
    /// entry, so where two devices each added the same word the newer entry shows and the other stays hidden. Hidden
    /// entries are kept, not deleted, so what shows depends only on the records, never on the order copies arrived in:
    /// when a third device's entry displaces the one showing, the word hidden behind it shows again.
    // ponytail: hidden entries, like deletion markers, are never pruned.
    private var shown: [String: Record] {
        var owned: Set<String> = []
        var result: [String: Record] = [:]
        for (id, record) in records.sorted(by: { ($0.value.modified, $0.key) > ($1.value.modified, $1.key) }) {
            guard let keys = record.entry?.keys, !keys.contains(where: owned.contains) else { continue }
            owned.formUnion(keys)
            result[id] = record
        }
        return result
    }

    /// Notes what this device added, changed or deleted since the state was saved.
    mutating func adopt(_ entries: [DictionaryEntry], now: Date) {
        // Later than the stamp it replaces, so an edit here still wins when the other device's clock runs ahead.
        func stamp(_ id: String) -> Date { max(now, records[id].map { $0.modified.addingTimeInterval(0.001) } ?? now) }
        let shown = shown
        let local = Dictionary(entries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        // The words this device stopped using: a deleted entry's, and those an edit took off an entry.
        var dropped: Set<String> = []
        for (id, record) in shown {
            dropped.formUnion(Set(record.entry?.keys ?? []).subtracting(local[id]?.keys ?? []))
            // Only an entry this device was showing can have been deleted here; a hidden one was never in its list.
            if local[id] == nil { records[id] = Record(modified: stamp(id), entry: nil) }
        }
        dropped.subtract(entries.flatMap(\.keys))
        for (id, entry) in local where records[id]?.entry != entry { records[id] = Record(modified: stamp(id), entry: entry) }
        // Deleting or renaming a word deletes the copies of it hidden behind that entry, or they would show in its place.
        for (id, record) in records where shown[id] == nil && local[id] == nil && record.entry?.keys.contains(where: dropped.contains) == true {
            records[id] = Record(modified: stamp(id), entry: nil)
        }
    }

    func merging(_ other: Self) -> Self {
        var result = self
        for (id, theirs) in other.records where result.records[id].map(theirs.wins(over:)) ?? true {
            result.records[id] = theirs
        }
        return result
    }

    /// This device's entries after a merge: its own order kept, and entries from other devices added as its newest.
    func applied(to entries: [DictionaryEntry]) -> [DictionaryEntry] {
        let shown = shown
        let known = Set(entries.map(\.id.uuidString))
        let added = shown.filter { !known.contains($0.key) }.sorted { ($0.value.modified, $0.key) < ($1.value.modified, $1.key) }
        return entries.compactMap { shown[$0.id.uuidString]?.entry } + added.compactMap(\.value.entry)
    }
}

extension DictionaryRepository {
    /// One round of syncing this dictionary with `remote`, the copy in iCloud, if any. Reconciles `entries` with the
    /// sync state saved beside the dictionary, saves the merged entries and updates `entries` to them, then saves the
    /// state. Returns the copy to write to iCloud, or nil when iCloud is already up to date. Throws before writing
    /// anything when either saved copy can't be read, such as one from a newer gob.lin.
    public func syncRound(_ entries: inout [DictionaryEntry], remote: Data?) throws -> Data? {
        let stateURL = url.deletingLastPathComponent().appendingPathComponent("dictionary-sync.json")
        let state = FileManager.default.fileExists(atPath: stateURL.path) ? try SyncedDictionary(data: Data(contentsOf: stateURL)) : SyncedDictionary()
        let remote = try remote.map(SyncedDictionary.init(data:))
        let result = try SyncedDictionary.reconcile(entries: entries, state: state, remote: remote)
        // The entries before the state: the other order can delete words everywhere after a crash (see `reconcile`).
        if result.entries != entries { try save(result.entries); entries = result.entries }
        let data = try result.state.data()
        try data.write(to: stateURL, options: .atomic)
        return result.push ? data : nil
    }
}

private extension DictionaryEntry {
    var sortKey: [String] { [spelling] + aliases + ["\n"] + apps + ["\n"] + projects + ["\n"] + context }
    var keys: [String] { ([spelling] + aliases).map(dictionaryKey) }
}
