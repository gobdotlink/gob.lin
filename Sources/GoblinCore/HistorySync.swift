import Foundation

/// History's iCloud format and the pure rules around it, kept apart from CloudKit so each can be tested offline.
///
/// A dictation travels as one record named by the entry's UUID. Its body is the entry's JSON exactly as History
/// stores it, without the audio filename, which names a file on the device that recorded it. The body is one plain
/// field for now; encrypting it later changes only how the engine writes that field, never this format.
public enum HistorySync {
    /// The body format this build writes and understands. A record with a higher one is left out of History.
    public static let formatVersion = 1

    /// The name of the one record holding the shared settings; every other record is named by its entry's UUID.
    static let settingsName = "Settings"

    /// Stands for the device of an incoming dictation that names none, so it is never read as this device's.
    static let unknownDevice = "unknown"

    /// The keys a device may change after an entry is made, by the change that sets them. Text never changes.
    static let starredKeys = ["starred"]
    static let editKeys = ["editOutcome", "editDistance", "maximumEditDistance", "editedText"]

    /// The record body for an entry stored as `metadata`, naming `device` when the entry predates devices.
    static func body(metadata: String, device: String) throws -> Data {
        var object = try self.object(metadata)
        object["audioFilename"] = nil
        object["device"] = object["device"] ?? device
        return Data(try string(object).utf8)
    }

    /// An incoming body as History stores it, and the entry it holds.
    static func metadata(body: Data) throws -> (metadata: String, entry: HistoryEntry) {
        var object = try self.object(String(decoding: body, as: UTF8.self))
        object["audioFilename"] = nil
        object["device"] = object["device"] ?? unknownDevice
        let metadata = try string(object)
        return (metadata, try JSONDecoder().decode(HistoryEntry.self, from: Data(metadata.utf8)))
    }

    /// `target` with `keys` copied from `source`; a key `source` lacks is removed. Every other key, including any a
    /// newer gob.lin wrote, stays as `target` has it.
    static func patch(_ target: String, keys: [String], from source: String) throws -> String {
        var target = try object(target)
        let source = try object(source)
        for key in keys { target[key] = source[key] }
        return try string(target)
    }

    static func settingsBody(_ settings: HistorySyncSettings) throws -> Data {
        try JSONEncoder().encode(settings)
    }

    static func settings(body: Data) throws -> HistorySyncSettings {
        try JSONDecoder().decode(HistorySyncSettings.self, from: body)
    }

    private static func object(_ json: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw HistoryError.database("A History record isn't a JSON object")
        }
        return object
    }

    private static func string(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

/// The History settings every device shares. Retention isn't one: each device's Keep trims only its own copy.
struct HistorySyncSettings: Codable, Sendable, Equatable {
    /// The last Delete All: every dictation saved in iCloud at or before it is deleted on every device.
    var clearedThrough: Date?

    /// The later Delete All wins.
    func merged(with other: HistorySyncSettings) -> HistorySyncSettings {
        HistorySyncSettings(clearedThrough: [clearedThrough, other.clearedThrough].compactMap { $0 }.max())
    }
}

/// A dictation record fetched from iCloud, or returned by it when a save conflicts.
public struct HistoryRemoteRecord: Sendable, Equatable {
    public var id: UUID
    public var body: Data
    public var formatVersion: Int
    /// The record's archived system fields, which later edits are sent against.
    public var serverFields: Data
    /// When iCloud first saved the record: `CKRecord.creationDate`.
    public var serverCreated: Date

    public init(id: UUID, body: Data, formatVersion: Int, serverFields: Data, serverCreated: Date) {
        self.id = id; self.body = body; self.formatVersion = formatVersion
        self.serverFields = serverFields; self.serverCreated = serverCreated
    }
}

/// The shared settings record fetched from iCloud.
public struct HistoryRemoteSettings: Sendable, Equatable {
    public var body: Data
    public var formatVersion: Int
    public var serverFields: Data

    public init(body: Data, formatVersion: Int, serverFields: Data) {
        self.body = body; self.formatVersion = formatVersion; self.serverFields = serverFields
    }
}

/// A record to send, built from what History holds now.
public struct HistoryOutgoingRecord: Sendable {
    public var body: Data
    /// Nil until iCloud has confirmed the record once: the save creates it.
    public var serverFields: Data?
    /// Hand back to `markSent` so changes made while this was on its way are sent too.
    public var revision: Int
}

/// What this device still has to send.
public struct HistoryPendingChanges: Sendable, Equatable {
    /// This device's dictations iCloud doesn't have yet, and dictations with changes iCloud hasn't confirmed.
    public var saves: [UUID] = []
    public var deletions: [UUID] = []
    public var settings = false
    /// After a Delete All: iCloud must lose every dictation saved at or before this time, see `HistoryStore.deleteAll`.
    public var purgeThrough: Date?
}

/// What applying fetched changes did.
public struct HistoryRemoteResult: Sendable, Equatable {
    public var saved = 0
    public var deleted = 0
    /// Records in a newer format, left out of History. Say "Update gob.lin to see all of History".
    public var skippedNewer = 0
    /// Records whose body couldn't be read. They are left out rather than stopping the rest.
    public var unreadable = 0
}
