import Foundation
import Testing
@testable import GoblinCore

private let laptop = MicrophoneFacts(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", model: "Digital Mic", kind: .builtIn)
private let webcam = MicrophoneFacts(uid: "AppleUSBAudioEngine:Logitech:Webcam:1100:3", name: "Webcam", model: "Webcam:046D:0892", kind: .usb)
private let phone = MicrophoneFacts(uid: "phone", name: "iPhone Microphone", model: "iPhone Mic", kind: .iPhone)
private let loopback = MicrophoneFacts(uid: "loopback", name: "Loopback", kind: .virtual)
private let lavalier = MicrophoneFacts(uid: "AppleUSBAudioEngine:Maker:Lav Receiver:SERIAL:3", name: "Lav Receiver", model: "Lav Receiver:2CA3:4011", kind: .usb)

private func closedLid(_ device: MicrophoneFacts) -> MicrophoneFacts {
    var device = device; device.silencedByLid = true; return device
}

private func defaults(legacy: String?) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "microphone-ranking-\(UUID().uuidString)")!
    if let legacy { defaults.set(legacy, forKey: MicrophoneRanking.legacyPreferenceKey) }
    return defaults
}

@Test func anEarlierChoiceStaysFirstAndTheLaptopMicBeatsWhateverMacOSPicks() {
    var ranking = MicrophoneRanking.migrating(defaults: defaults(legacy: lavalier.uid))
    #expect(ranking.entries.map(\.name) == ["Lav Receiver", "System Default"])
    ranking.seed([webcam, laptop, phone, loopback])
    #expect(ranking.entries.map(\.uid) == [lavalier.uid, laptop.uid, "", webcam.uid, phone.uid, loopback.uid])

    // Lid open, receiver away: the laptop mic wins over the webcam macOS selected.
    #expect(ranking.resolve(connected: [webcam, laptop, phone], systemDefault: webcam.uid)
            == MicrophoneChoice(uid: laptop.uid, position: 1, viaSystemDefault: false))
    // Lid closed: the laptop mic hears nothing, so macOS's choice is used.
    #expect(ranking.resolve(connected: [webcam, closedLid(laptop), phone], systemDefault: webcam.uid)
            == MicrophoneChoice(uid: webcam.uid, position: 2, viaSystemDefault: true))
    // The receiver returns and wins again; nothing below the line is ever chosen on its own.
    #expect(ranking.resolve(connected: [webcam, laptop, lavalier], systemDefault: webcam.uid)?.uid == lavalier.uid)
    #expect(ranking.resolve(connected: [phone], systemDefault: nil) == nil)
}

@Test func someoneWhoChoseToFollowMacOSKeepsFollowingIt() {
    let store = defaults(legacy: "")
    var ranking = MicrophoneRanking.migrating(defaults: store)
    ranking.seed([webcam, laptop], laptopFirst: MicrophoneRanking.laptopFirst(defaults: store))
    #expect(ranking.entries.map(\.uid) == ["", webcam.uid, laptop.uid])
    #expect(MicrophoneRanking.laptopFirst(defaults: defaults(legacy: nil)))
    #expect(MicrophoneRanking.laptopFirst(defaults: defaults(legacy: lavalier.uid)))
}

@Test func withNothingUsableAboveTheLineMacOSsChoiceStillOpens() {
    var ranking = MicrophoneRanking()
    ranking.seed([laptop])
    #expect(ranking.resolve(connected: [closedLid(laptop)], systemDefault: laptop.uid)
            == MicrophoneChoice(uid: laptop.uid, position: 1, viaSystemDefault: true))
}

@Test func pickingKeepsAbsentFavouritesAhead() {
    var ranking = MicrophoneRanking(entries: [MicrophoneRanking.Entry(uid: lavalier.uid, name: lavalier.name), .init(laptop), .systemDefault, .init(webcam)])
    ranking.pick(webcam.uid, connected: [laptop, webcam])
    #expect(ranking.entries.map(\.uid) == [lavalier.uid, webcam.uid, laptop.uid, ""])
    // A microphone the list hasn't met yet joins it the same way.
    ranking.pick(phone.uid, connected: [laptop, webcam, phone])
    #expect(ranking.entries.map(\.uid) == [lavalier.uid, phone.uid, webcam.uid, laptop.uid, ""])
    // A laptop mic silenced by the lid isn't "usable now", so a pick lands above the line instead and
    // the laptop mic, ranked higher, wins again when the lid opens.
    var desk = MicrophoneRanking(entries: [.init(laptop), .systemDefault])
    desk.pick(webcam.uid, connected: [closedLid(laptop), webcam])
    #expect(desk.entries.map(\.uid) == [laptop.uid, webcam.uid, ""])
    // Picking the line follows macOS until something above it connects.
    ranking.pick("", connected: [laptop, webcam])
    #expect(ranking.entries.map(\.uid) == [lavalier.uid, phone.uid, "", webcam.uid, laptop.uid])
}

@Test func aMicMovedToAnotherPortKeepsItsPlace() {
    var ranking = MicrophoneRanking(entries: [.init(lavalier), .systemDefault])
    var moved = lavalier; moved.uid = "AppleUSBAudioEngine:Maker:Lav Receiver:SERIAL:7"
    #expect(ranking.reconcile([moved, laptop, loopback]) == [laptop])
    #expect(ranking.entries.map(\.uid) == [moved.uid, "", loopback.uid])

    // Two identical receivers can't be told apart, so neither inherits the entry.
    var twin = moved; twin.uid = "twin"
    var other = MicrophoneRanking(entries: [.init(lavalier), .systemDefault])
    #expect(other.reconcile([moved, twin]).map(\.uid) == [moved.uid, "twin"])
    #expect(other.entries.map(\.uid) == [lavalier.uid, ""])
}

@Test func reorderingAndForgettingNeverLoseTheLine() throws {
    var ranking = MicrophoneRanking(entries: [.init(laptop), .init(webcam), .systemDefault, .init(phone)])
    ranking.move(fromOffsets: [0], toOffset: 3)
    #expect(ranking.entries.map(\.uid) == [webcam.uid, "", laptop.uid, phone.uid])
    ranking.move(fromOffsets: [3], toOffset: 0)
    #expect(ranking.entries.map(\.uid) == [phone.uid, webcam.uid, "", laptop.uid])
    ranking.forget("")
    ranking.forget(phone.uid)
    #expect(ranking.entries.map(\.uid) == [webcam.uid, "", laptop.uid])

    let store = defaults(legacy: nil)
    #expect(MicrophoneRanking.load(defaults: store) == nil)
    ranking.save(defaults: store)
    #expect(MicrophoneRanking.load(defaults: store) == ranking)
    // A saved list that somehow lost its line gets it back at the end.
    store.set(try JSONEncoder().encode(["entries": [MicrophoneRanking.Entry(webcam)]]), forKey: MicrophoneRanking.preferenceKey)
    #expect(MicrophoneRanking.load(defaults: store)?.entries.map(\.uid) == [webcam.uid, ""])
}
