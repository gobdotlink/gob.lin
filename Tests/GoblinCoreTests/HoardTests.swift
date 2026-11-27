import Foundation
import Testing
@testable import GoblinCore

struct HoardTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func add(_ tally: inout HoardTally, _ when: String, words: Int = 3, app: String? = nil, device: String? = nil,
                     tone: String? = "formal", text: String? = nil, seconds: Double? = nil) {
        tally.add(date: date(when), words: words, duration: seconds, application: app, deviceKind: device, tone: tone, text: text, calendar: utc)
    }

    // MARK: Catalogue

    @Test func catalogueIsStableAndLadderClimbs() {
        let ids = Hoard.treasures.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Hoard.treasures.count == 107)
        for shelf in HoardShelf.allCases where shelf != .secrets {
            let rungs = Hoard.shelf(shelf)
            #expect(!rungs.isEmpty)
            #expect(rungs.compactMap(\.threshold) == rungs.compactMap(\.threshold).sorted())
            #expect(rungs.first?.material == .wood && rungs.last?.material == .goblinite)
        }
        #expect(Set(Hoard.shelf(.secrets).compactMap(\.secret)) == Set(HoardSecret.allCases))
        #expect(Hoard.shelf(.secrets).allSatisfy { $0.material == .amethyst })
        #expect(Hoard.treasure("words-100000")?.name == "Doorstop")
    }

    @Test func requirementsReadInTheirShelfsUnits() {
        #expect(HoardShelf.words.phrase(100_000) == "\(100_000.formatted()) words")
        #expect(HoardShelf.talk.phrase(10) == "10 minutes")
        #expect(HoardShelf.talk.phrase(60) == "1 hour")
        #expect(HoardShelf.talk.phrase(600) == "10 hours")
        #expect(HoardShelf.dictations.phrase(1) == "1 dictation")
        #expect(HoardShelf.streak.phrase(3) == "3 days in a row")
    }

    // MARK: Reaching thresholds

    @Test func treasuresArriveAtTheirThresholds() {
        var stats = HoardStats()
        stats.dictations.words = 1_000
        stats.dictations.dictations = 10
        stats.meetings.add(id: "a", seconds: 3_600, voices: 2, marks: 1)
        stats.people = 4
        let earned = Hoard.earned(stats, now: date("2026-11-27T12:00:00Z"), calendar: utc)
        #expect(earned.isSuperset(of: ["words-100", "words-1000", "dictations-1", "dictations-10", "meetings-1", "meetingTime-1",
                                       "people-1", "marks-1"]))
        #expect(!earned.contains("words-5000") && !earned.contains("dictations-50") && !earned.contains("people-5"))
    }

    @Test func typingSavedAndTalkUseRecordedAudio() {
        var tally = HoardTally()
        // 4,800 words at 40 wpm is two hours of typing; an hour of talking leaves one saved.
        add(&tally, "2026-11-27T10:00:00Z", words: 4_800, seconds: 3_600)
        add(&tally, "2026-11-27T11:00:00Z", words: 50)
        let stats = HoardStats(dictations: tally)
        #expect(stats.value(.saved, calendar: utc) == 1)
        #expect(stats.value(.talk, calendar: utc) == 60)
        #expect(stats.value(.words, calendar: utc) == 4_850)
    }

    @Test func emptyDictationsCountForNothing() {
        var tally = HoardTally()
        add(&tally, "2026-11-27T03:00:00Z", words: 0)
        #expect(tally.dictations == 0 && tally.found.isEmpty && tally.days.isEmpty)
    }

    @Test func streaksAndBiggestDayComeFromDays() {
        var tally = HoardTally()
        for day in ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-05", "2026-11-05"] { add(&tally, day + "T12:00:00Z", words: 400) }
        #expect(tally.longestStreak(calendar: utc) == 3)
        #expect(tally.biggestDay == 800)
        // Across a month boundary.
        var turn = HoardTally()
        for day in ["2026-10-30", "2026-10-31", "2026-11-01"] { add(&turn, day + "T12:00:00Z") }
        #expect(turn.longestStreak(calendar: utc) == 3)
    }

    // MARK: Secrets

    @Test func secretsFromOneDictation() {
        var tally = HoardTally()
        add(&tally, "2026-11-27T02:30:00Z")
        add(&tally, "2026-11-27T05:59:00Z")
        add(&tally, "2026-11-27T12:00:00Z", words: 500)
        add(&tally, "2026-11-27T13:00:00Z", device: HistoryDevice.iPhone)
        add(&tally, "2027-01-01T13:00:00Z")
        add(&tally, "2026-10-31T13:00:00Z", text: "Ha-ha-ha, very funny")
        #expect(tally.found == [.night, .early, .monologue, .pocket, .newYear, .halloween, .cackle])
    }

    @Test func laughterNeedsThreeHas() {
        #expect(HoardTally.laughs("ha ha ha"))
        #expect(HoardTally.laughs("HAHAHAHA that was good"))
        #expect(HoardTally.laughs("well, ha, ha, ha."))
        #expect(!HoardTally.laughs("haha"))
        #expect(!HoardTally.laughs("the hat had a handle"))
        #expect(!HoardTally.laughs("hahahaha2"))
    }

    @Test func secretsFromADay() {
        var tally = HoardTally()
        for app in 0..<9 { add(&tally, "2026-11-27T12:00:00Z", app: "app.\(app)") }
        #expect(!tally.found.contains(.juggler) && !tally.found.contains(.split))
        add(&tally, "2026-11-27T12:00:00Z", app: "app.9", tone: "casual")
        #expect(tally.found.isSuperset(of: [.juggler, .split]))
        // Ten apps over two days isn't juggling.
        var spread = HoardTally()
        for app in 0..<10 { add(&spread, app < 5 ? "2026-11-26T12:00:00Z" : "2026-11-27T12:00:00Z", app: "app.\(app)") }
        #expect(!spread.found.contains(.juggler) && spread.applications.count == 10)
    }

    @Test func swarmNeedsTenInsideTenMinutes() {
        var tally = HoardTally()
        for minute in 0..<9 { add(&tally, String(format: "2026-11-27T12:%02d:00Z", minute)) }
        add(&tally, "2026-11-27T12:10:01Z")
        #expect(!tally.found.contains(.swarm))
        // One arriving late, out of order, fills the window.
        add(&tally, "2026-11-27T12:09:30Z")
        #expect(tally.found.contains(.swarm))
    }

    @Test func weekendWeekAndAnniversary() {
        var tally = HoardTally()
        add(&tally, "2026-11-21T12:00:00Z") // Saturday
        #expect(!HoardStats(dictations: tally).secrets(now: date("2026-11-27T12:00:00Z"), calendar: utc).contains(.weekend))
        add(&tally, "2026-11-22T12:00:00Z") // Sunday
        for day in 23...26 { add(&tally, "2026-11-\(day)T12:00:00Z") } // Monday to Thursday
        var stats = HoardStats(dictations: tally)
        #expect(stats.secrets(now: date("2026-11-27T12:00:00Z"), calendar: utc).contains(.weekend))
        #expect(!stats.secrets(now: date("2026-11-27T12:00:00Z"), calendar: utc).contains(.fullWeek))
        stats.dictations.add(date: date("2026-11-27T12:00:00Z"), words: 1, duration: nil, application: nil, deviceKind: nil, tone: nil, text: nil, calendar: utc)
        #expect(stats.secrets(now: date("2026-11-27T12:00:00Z"), calendar: utc).contains(.fullWeek))
        #expect(!stats.secrets(now: date("2027-11-20T12:00:00Z"), calendar: utc).contains(.anniversary))
        #expect(stats.secrets(now: date("2027-11-21T12:00:00Z"), calendar: utc).contains(.anniversary))
    }

    @Test func meetingsCountOnce() {
        var meetings = HoardMeetingTally()
        let added = meetings.add(id: "a", seconds: 7_300, voices: 5, marks: 3)
        let again = meetings.add(id: "a", seconds: 7_300, voices: 5, marks: 3)
        #expect(added && !again)
        #expect(meetings.count == 1 && meetings.marks == 3 && meetings.seconds == 7_300)
        #expect(meetings.found == [.marathon, .feast])
    }

    // MARK: Ledger

    @Test func firstCountFilesEverythingQuietly() {
        var ledger = HoardLedger()
        let now = date("2026-11-27T12:00:00Z")
        let first = ledger.record(["words-100", "words-1000"], now: now)
        #expect(first.count == 2 && ledger.found["words-100"]?.before == true)
        #expect(ledger.unseen.isEmpty && ledger.pending.isEmpty)
        let celebrated = ledger.celebration(now: now, calendar: utc)
        #expect(celebrated == nil)
        let later = ledger.record(["words-100", "words-1000", "words-5000"], now: now)
        #expect(later.map(\.id) == ["words-5000"])
        #expect(ledger.unseen == ["words-5000"] && ledger.found["words-5000"]?.before == false)
    }

    @Test func treasuresAreNeverTakenBack() {
        var ledger = HoardLedger()
        ledger.record(["words-100", "words-1000"])
        ledger.record([])
        #expect(Set(ledger.found.keys) == ["words-100", "words-1000"])
    }

    @Test func oneCelebrationADayMostPreciousFirst() {
        var ledger = HoardLedger()
        ledger.record([])
        let morning = date("2026-11-27T09:00:00Z")
        ledger.record(["words-100", "words-100000", "secret-night"], now: morning)
        let first = ledger.celebration(now: morning, calendar: utc)
        let evening = ledger.celebration(now: date("2026-11-27T22:00:00Z"), calendar: utc)
        let tomorrow = ledger.celebration(now: date("2026-11-28T08:00:00Z"), calendar: utc)
        // A find more than three days old stays in the Hoard without a celebration.
        let stale = ledger.celebration(now: date("2026-12-05T08:00:00Z"), calendar: utc)
        #expect(first?.id == "secret-night" && evening == nil && tomorrow?.id == "words-100000" && stale == nil)
        #expect(ledger.pending.isEmpty && ledger.unseen.count == 3)
    }

    // MARK: History

    @Test func historyCountsEachDictationOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hoard-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let early = HistoryEntry(rawText: "", finalText: "one two three", targetBundleIdentifier: "app.mail", targetApplicationName: "Mail",
                                 createdAt: date("2026-11-26T12:00:00Z"), audioDuration: 2)
        _ = try await store.insert(early)
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "four five", targetApplicationName: "Notes",
                                                createdAt: date("2026-11-27T12:00:00Z")))
        let first = try await store.hoardTally(calendar: utc)
        #expect(first.first && first.tally.words == 5 && first.tally.dictations == 2)
        #expect(first.tally.applications == ["app.mail", "Notes"] && first.tally.audioSeconds == 2)
        let again = try await store.hoardTally(calendar: utc)
        #expect(!again.first && again.tally == first.tally)
        // Deleting keeps what was counted; a new dictation adds to it.
        try await store.delete(id: early.id)
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "six", createdAt: date("2026-11-27T13:00:00Z")))
        let after = try await store.hoardTally(calendar: utc)
        #expect(after.tally.words == 6 && after.tally.dictations == 3)
        // Delete All doesn't either.
        try await store.deleteAll()
        #expect(try await store.hoardTally(calendar: utc).tally.words == 6)
    }
}
