import Foundation
import Testing
@testable import GoblinCore

/// A device and the copy of the dictionary it last synced. `cloud` stands in for iCloud, which keeps one copy.
private struct Device {
    var entries: [DictionaryEntry] = []
    var state = SyncedDictionary()

    @discardableResult
    mutating func sync(_ cloud: inout Data?, at seconds: TimeInterval) throws -> Bool {
        let result = try SyncedDictionary.reconcile(entries: entries, state: state, remote: cloud.map(SyncedDictionary.init(data:)),
                                                    now: Date(timeIntervalSinceReferenceDate: seconds))
        entries = result.entries
        state = result.state
        if result.push { cloud = try result.state.data() }
        return result.push
    }

    var spellings: Set<String> { Set(entries.map(\.spelling)) }
    var sorted: [DictionaryEntry] { entries.sorted { $0.id.uuidString < $1.id.uuidString } }
}

@Test func devicesSettleOnTheSameWordsWhenICloudDropsACopy() throws {
    var cloud: Data?
    var mac = Device(entries: [DictionaryEntry(spelling: "Paseo"), DictionaryEntry(spelling: "Kalikin")])
    var phone = Device()
    try mac.sync(&cloud, at: 1)
    try phone.sync(&cloud, at: 2)
    #expect(phone.sorted == mac.sorted)

    // Both change the dictionary while apart, and iCloud keeps only the phone's copy, which never saw the Mac's.
    var stale = cloud
    mac.entries.append(DictionaryEntry(spelling: "Cerebras"))
    try mac.sync(&cloud, at: 3)
    phone.entries.removeAll { $0.spelling == "Kalikin" }
    phone.entries[0].aliases = ["passe oh"]
    try phone.sync(&stale, at: 4)
    cloud = stale

    try mac.sync(&cloud, at: 5)
    try phone.sync(&cloud, at: 6)
    // The Mac's new word survives the dropped copy, the phone's deletion isn't undone and its edit arrives.
    #expect(mac.spellings == ["Paseo", "Cerebras"] && phone.spellings == mac.spellings)
    #expect(mac.entries.first?.aliases == ["passe oh"])
    // Once they agree, neither writes again: two devices must not answer each other forever.
    let settled = cloud
    #expect(try !mac.sync(&cloud, at: 7) && !phone.sync(&cloud, at: 8) && cloud == settled)
}

@Test func theSameWordAddedOnTwoDevicesBecomesOneEntry() throws {
    var cloud: Data?
    var mac = Device(entries: [DictionaryEntry(spelling: "Paseo", aliases: ["passeo"]), DictionaryEntry(spelling: "Kalikin")])
    var phone = Device(entries: [DictionaryEntry(spelling: "paseo")])
    try mac.sync(&cloud, at: 1)
    try phone.sync(&cloud, at: 2)
    try mac.sync(&cloud, at: 3)
    // A spelling belongs to one entry, so the newer one keeps it; both devices hold the same valid dictionary.
    #expect(mac.spellings == ["paseo", "Kalikin"] && mac.sorted == phone.sorted)
}

@Test func anEditHereWinsWhenTheOtherClockRunsAhead() throws {
    var cloud: Data?
    var phone = Device(entries: [DictionaryEntry(spelling: "Paseo")])
    var mac = Device()
    try phone.sync(&cloud, at: 1_000)
    try mac.sync(&cloud, at: 5)
    mac.entries[0].aliases = ["passeo"]
    try mac.sync(&cloud, at: 6)
    try phone.sync(&cloud, at: 1_001)
    #expect(phone.entries.first?.aliases == ["passeo"] && mac.entries == phone.entries)
}

@Test func aCopyFromANewerVersionIsLeftAlone() throws {
    #expect(throws: DictionaryError.self) { try SyncedDictionary(data: Data(#"{"version":2,"records":{}}"#.utf8)) }
}
