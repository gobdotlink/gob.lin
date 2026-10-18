import Foundation
import Testing
@testable import GoblinCore

struct HistoryInsightsTests {
    private func calendar(_ zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = firstWeekday
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("insights-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recentWindowPreservesWeekAndChartTotals() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let now = date("2026-10-14T12:00:00Z"), firstChartDay = date("2026-10-08T00:00:00Z")
        for (timestamp, text) in [("2026-10-07T23:59:59Z", "outside"),
                                  ("2026-10-08T00:00:00Z", "chart starts"),
                                  ("2026-10-11T12:00:00Z", "previous week"),
                                  ("2026-10-14T12:00:00Z", "current week words")] {
            _ = try await store.insert(HistoryEntry(rawText: "", finalText: text, createdAt: date(timestamp)))
        }
        let all = try await store.insights(now: now, week: now, calendar: calendar())
        let recent = try await store.insights(now: now, week: now, calendar: calendar(), since: firstChartDay)
        #expect(all.entryCount == 4 && all.totalWords == 8)
        #expect(recent.entryCount == 3 && recent.totalWords == 7)
        #expect(recent.todayWords == all.todayWords && recent.weekWords == all.weekWords)
        #expect(recent.days.map(\.words) == all.days.map(\.words))
        #expect(recent.days.first?.words == 2 && recent.weekWords == 3)
    }

    @Test func retainedWordsAndWeightedAudioSpeedUseAllPages() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let now = date("2026-10-14T12:00:00Z")
        for _ in 0..<2105 {
            _ = try await store.insert(HistoryEntry(rawText: "raw is different", finalText: "one", createdAt: now, audioDuration: 1))
        }
        let old = HistoryEntry(rawText: "raw", finalText: "two\tfinal\nwords", targetBundleIdentifier: "app.editor", targetApplicationName: "Editor",
                               createdAt: date("2026-10-13T12:00:00Z"), audioDuration: 9, starred: true)
        _ = try await store.insert(old)
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "untimed words", createdAt: now))
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "", createdAt: now, audioDuration: 1000))
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "future", createdAt: now.addingTimeInterval(1), audioDuration: 1))
        let snapshot = try await store.insights(now: now, week: now, calendar: calendar())
        #expect(snapshot.entryCount == 2108 && snapshot.totalWords == 2110)
        #expect(snapshot.todayWords == 2107 && snapshot.weekWords == 2110)
        #expect(snapshot.timedEntryCount == 2106 && snapshot.timedWords == 2108 && snapshot.audioSeconds == 2114)
        #expect(abs(snapshot.wordsPerMinute! - 59.8297067) < 0.0001)
        #expect(snapshot.applications.map(\.words).reduce(0, +) == 2110)
        #expect(snapshot.week[2].words == 2107 && snapshot.week.reduce(0) { $0 + $1.words } == 2110)
        #expect(snapshot.weekTimedWords == 2108 && snapshot.weekAudioSeconds == 2114)
        #expect(snapshot.currentStreak == 2 && snapshot.longestStreak == 2)
        #expect(try await store.entries(limit: 2000).count == 2000)
        _ = try await store.applyRetention(HistoryRetention(maximumUnstarredCount: 0), now: now)
        let retained = try await store.insights(now: now, week: now, calendar: calendar())
        #expect(retained.entryCount == 1 && retained.totalWords == 3 && retained.currentStreak == 1)
        #expect(retained.applications.first?.name == "Editor")
        try await store.delete(id: old.id)
        let empty = try await store.insights(now: now, week: now, calendar: calendar())
        #expect(empty.totalWords == 0 && empty.entryCount == 0 && empty.wordsPerMinute == nil)
        #expect(empty.currentStreak == 0 && empty.longestStreak == 0 && empty.applications.isEmpty)
        #expect(empty.days.count == 7 && empty.week.count == 7 && empty.week.allSatisfy { $0.hours.count == 24 })
    }

    @Test func unavailableDurationsAndApplicationIdentity() {
        let now = date("2026-10-14T12:00:00Z")
        var aggregate = HistoryInsightsAccumulator(now: now, week: now, calendar: calendar())
        for duration in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            aggregate.add(date: now, words: 2, duration: duration, bundle: nil, name: "  ")
        }
        aggregate.add(date: now, words: 4, duration: 2, bundle: "app.editor", name: "Editor")
        aggregate.add(date: now, words: 2, duration: 1, bundle: "app.editor", name: "Renamed editor")
        aggregate.add(date: now, words: 1, duration: nil, bundle: "another.editor", name: "Editor")
        aggregate.add(date: now, words: 1, duration: nil, bundle: nil, name: "Editor")
        let result = aggregate.finish()
        #expect(result.totalWords == 18 && result.wordsPerMinute == 120)
        #expect(result.timedEntryCount == 2 && result.audioSeconds == 3)
        #expect(result.applications.count == 4)
        #expect(result.applications.first?.name == "Unknown app" && result.applications.first?.words == 10)
        #expect(result.applications.first(where: { $0.id == "bundle:app.editor" })?.words == 6)
        #expect(result.applications.first(where: { $0.id == "bundle:app.editor" })?.bundleIdentifier == "app.editor")
    }

    @Test func localMidnightCalendarWeekAndStreakGaps() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let now = date("2027-01-04T08:30:00Z") // Monday, 00:30 in Los Angeles.
        for timestamp in ["2026-12-28T20:00:00Z", "2026-12-29T20:00:00Z", "2026-12-30T20:00:00Z",
                          "2027-01-03T20:00:00Z", "2027-01-04T07:59:00Z", "2027-01-04T08:00:00Z"] {
            _ = try await store.insert(HistoryEntry(rawText: "", finalText: "one", createdAt: date(timestamp), audioDuration: 1))
        }
        let local = try await store.insights(now: now, week: now, calendar: calendar("America/Los_Angeles"))
        #expect(local.todayWords == 1 && local.weekWords == 1 && local.currentStreak == 2 && local.longestStreak == 3)
        let sundayWeek = try await store.insights(now: now, week: now, calendar: calendar("America/Los_Angeles", firstWeekday: 1))
        #expect(sundayWeek.weekWords == 3)
        let utc = try await store.insights(now: now, week: now, calendar: calendar())
        #expect(utc.todayWords == 2 && utc.weekWords == 2)
        let yesterday = try await store.insights(now: date("2027-01-05T08:30:00Z"), week: now, calendar: calendar("America/Los_Angeles"))
        #expect(yesterday.currentStreak == 2)
        let broken = try await store.insights(now: date("2027-01-06T08:30:00Z"), week: now, calendar: calendar("America/Los_Angeles"))
        #expect(broken.currentStreak == 0 && broken.longestStreak == 3)
    }

    @Test func skippedMidnightKeepsChartsAndStreaksOnCalendarDates() {
        let cal = calendar("America/Santiago")
        let days = ["2026-09-05T18:00:00Z", "2026-09-06T18:00:00Z", "2026-09-07T18:00:00Z"].map(date)
        for (now, activity, streak) in [(days[2], days, 3), (days[1], Array(days.prefix(2)), 2), (days[1], [days[0]], 1)] {
            var aggregate = HistoryInsightsAccumulator(now: now, week: now, calendar: cal)
            for day in activity { aggregate.add(date: day, words: 1, duration: 1, bundle: nil, name: nil) }
            let result = aggregate.finish()
            #expect(result.currentStreak == streak && result.longestStreak == streak)
            #expect(result.totalWords == activity.count && result.days.reduce(0) { $0 + $1.words } == activity.count)
            #expect(result.days.allSatisfy { $0.date == cal.startOfDay(for: $0.date) })
        }
    }

    @Test func daylightSavingWeekBucketsByHourOfDay() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        // Both 01:30s on the fall-back Sunday, then Monday of the next week.
        for timestamp in ["2026-10-31T18:00:00Z", "2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z", "2026-11-02T18:00:00Z"] {
            _ = try await store.insert(HistoryEntry(rawText: "", finalText: "one", createdAt: date(timestamp), audioDuration: 1))
        }
        let cal = calendar("America/Los_Angeles")
        let fall = try await store.insights(now: date("2026-11-02T20:00:00Z"), week: date("2026-11-01T20:00:00Z"), calendar: cal)
        #expect(fall.week.count == 7 && fall.week.allSatisfy { $0.hours.count == 24 })
        #expect(fall.week[6].hours[1] == 2 && fall.week[5].hours[11] == 1)
        #expect(fall.week.reduce(0) { $0 + $1.words } == 3)
        #expect(fall.currentStreak == 3 && fall.firstEntryDate == date("2026-10-31T18:00:00Z"))
        let spring = try await store.insights(now: date("2026-11-02T20:00:00Z"), week: date("2026-03-08T20:00:00Z"), calendar: cal)
        #expect(spring.week.count == 7 && spring.week.allSatisfy { $0.words == 0 })
        _ = try await store.insert(HistoryEntry(rawText: "", finalText: "half hour shift", createdAt: date("2026-10-03T16:15:00Z")))
        let halfHour = try await store.insights(now: date("2026-11-02T20:00:00Z"), week: date("2026-10-04T00:00:00Z"), calendar: calendar("Australia/Lord_Howe"))
        #expect(halfHour.week.allSatisfy { $0.hours.count == 24 } && halfHour.week.reduce(0) { $0 + $1.words } == 3)
    }

    @Test func spokenWordsCountNounsByDictionaryForm() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let now = date("2026-10-14T12:00:00Z") // Wednesday; the week starts Monday the 12th.
        for (timestamp, text) in [("2026-10-14T11:00:00Z", "The charts look great and the chart is done."),
                                  ("2026-10-12T09:00:00Z", "The goblin made two charts in Dia."),
                                  ("2026-10-11T09:00:00Z", "Last week's chart"),
                                  ("2026-10-13T09:00:00Z", "我买了一本书。"),
                                  ("2026-10-13T10:00:00Z", "本と車が好きです。"),
                                  ("2026-10-14T13:00:00Z", "Future chart")] {
            _ = try await store.insert(HistoryEntry(rawText: "", finalText: text, createdAt: date(timestamp)))
        }
        let cloud = try await store.spokenWords(now: now, calendar: calendar())
        #expect(cloud.weekEntries == 4 && cloud.todayEntries == 1)
        #expect(cloud.week.first == InsightWord(word: "chart", count: 3) && cloud.week.contains(InsightWord(word: "goblin", count: 1)))
        #expect(cloud.today.first == InsightWord(word: "chart", count: 2))
        #expect(!cloud.week.contains { ["the", "and", "be", "is", "look", "great", "make", "made", "two"].contains($0.word) })
        #expect(cloud.week.allSatisfy { !$0.word.hasSuffix(".") })
        // A one-character Chinese noun counts; Japanese particles, which the tagger cannot classify, do not.
        #expect(cloud.week.contains { $0.word == "书" } && !cloud.week.contains { ["と", "が", "は"].contains($0.word) })
    }
}
