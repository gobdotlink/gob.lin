import Foundation

public struct InsightWords: Sendable, Identifiable {
    public var date: Date
    public var words: Int
    public var id: Date { date }
}

public struct InsightApplication: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var words: Int
}

public struct HistoryInsights: Sendable {
    public var totalWords = 0
    public var todayWords = 0
    public var weekWords = 0
    public var entryCount = 0
    public var timedEntryCount = 0
    public var timedWords = 0
    public var audioSeconds: Double = 0
    public var currentStreak = 0
    public var longestStreak = 0
    public var days: [InsightWords] = []
    public var hours: [InsightWords] = []
    public var applications: [InsightApplication] = []
    public var calendar: Calendar

    public var wordsPerMinute: Double? {
        guard audioSeconds > 0 else { return nil }
        let value = Double(timedWords) / audioSeconds * 60
        return value.isFinite ? value : nil
    }

    init(calendar: Calendar) { self.calendar = calendar }
}

struct HistoryInsightsAccumulator {
    private var result: HistoryInsights
    private let calendar: Calendar
    private let today: Date
    private let weekStart: Date
    private let selectedDay: DateInterval
    private var dailyWords: [Date: Int] = [:]
    private var hourlyWords: [Date: Int] = [:]
    private var applications: [String: InsightApplication] = [:]

    init(now: Date, day: Date, calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        selectedDay = calendar.dateInterval(of: .day, for: day)!
        result = HistoryInsights(calendar: calendar)
    }

    mutating func add(date: Date, words: Int, duration: Double?, bundle: String?, name: String?) {
        result.entryCount += 1
        guard words > 0 else { return }
        result.totalWords += words
        let day = calendar.startOfDay(for: date)
        dailyWords[day, default: 0] += words
        if day == today { result.todayWords += words }
        if date >= weekStart { result.weekWords += words }
        if date >= selectedDay.start, date < selectedDay.end {
            let hour = selectedDay.start.addingTimeInterval(floor(date.timeIntervalSince(selectedDay.start) / 3600) * 3600)
            hourlyWords[hour, default: 0] += words
        }
        if let duration, duration.isFinite, duration > 0 {
            result.timedEntryCount += 1
            result.timedWords += words
            result.audioSeconds += duration
        }
        let bundle = bundle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.flatMap { $0.isEmpty ? nil : $0 }
        let identifier = bundle.flatMap { $0.isEmpty ? nil : $0 }
        let key = identifier.map { "bundle:" + $0 } ?? label.map { "name:" + $0 } ?? "unknown"
        if var app = applications[key] {
            app.words += words
            applications[key] = app
        } else {
            applications[key] = InsightApplication(id: key, name: label ?? identifier ?? "Unknown app", words: words)
        }
    }

    mutating func finish() -> HistoryInsights {
        result.days = (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map {
                let day = calendar.startOfDay(for: $0)
                return InsightWords(date: day, words: dailyWords[day, default: 0])
            }
        }
        var hour = selectedDay.start
        while hour < selectedDay.end {
            result.hours.append(InsightWords(date: hour, words: hourlyWords[hour, default: 0]))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else { break }
            hour = next
        }
        let activeDays = dailyWords.keys.sorted()
        var previous: Date?
        var run = 0
        for day in activeDays {
            let nextDay = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }.map { calendar.startOfDay(for: $0) }
            run = nextDay == day ? run + 1 : 1
            result.longestStreak = max(result.longestStreak, run)
            previous = day
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).map { calendar.startOfDay(for: $0) }
        if let last = activeDays.last,
           last == today || last == yesterday {
            result.currentStreak = run
        }
        result.applications = applications.values.sorted {
            if $0.words != $1.words { return $0.words > $1.words }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
        return result
    }
}
