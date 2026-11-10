import Foundation
import NaturalLanguage

public enum InsightPeriod: Int, Sendable {
    case today, week, allTime

    public func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .allTime: nil
        }
    }
}

public struct InsightWords: Sendable, Identifiable {
    public var date: Date
    public var words: Int
    public var id: Date { date }
}

/// One day of the Activity week: the words started in each hour of the day.
public struct InsightDay: Sendable, Identifiable {
    public var date: Date
    /// 24 buckets by hour of day. A repeated fall-back hour shares its bucket; a skipped one stays empty.
    public var hours: [Int]
    public var words: Int { hours.reduce(0, +) }
    public var id: Date { date }
}

public struct InsightApplication: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
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
    /// Timed words and recorded audio from this calendar week only.
    public var weekTimedWords = 0
    public var weekAudioSeconds: Double = 0
    public var currentStreak = 0
    public var longestStreak = 0
    /// The last seven days, ending today.
    public var days: [InsightWords] = []
    /// The calendar week that was asked for, Monday (or the calendar's first weekday) first.
    public var week: [InsightDay] = []
    /// When the oldest entry with words started, so the week stepper knows where History ends.
    public var firstEntryDate: Date?
    public var applications: [InsightApplication] = []
    /// The twelve calendar months ending with this one, oldest first.
    public var months: [InsightWords] = []
    /// Words by weekday and hour: seven rows of 24, the calendar's first weekday first.
    public var weekdayHours = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var calendar: Calendar

    /// A typical typing speed, which the time saved is measured against.
    public static let typingWordsPerMinute = 40.0

    /// How long the timed words would have taken to type, less the time spent saying them.
    public var typingSecondsSaved: Double {
        max(0, Double(timedWords) / Self.typingWordsPerMinute * 60 - audioSeconds)
    }

    public var wordsPerMinute: Double? { Self.pace(words: timedWords, seconds: audioSeconds) }
    public var weekWordsPerMinute: Double? { Self.pace(words: weekTimedWords, seconds: weekAudioSeconds) }

    private static func pace(words: Int, seconds: Double) -> Double? {
        guard seconds > 0 else { return nil }
        let value = Double(words) / seconds * 60
        return value.isFinite ? value : nil
    }

    init(calendar: Calendar) { self.calendar = calendar }
}

struct HistoryInsightsAccumulator {
    private var result: HistoryInsights
    private let calendar: Calendar
    private let today: Date
    private let weekStart: Date
    private let shownWeek: DateInterval
    private var dailyWords: [Date: Int] = [:]
    private var weekHours: [Date: [Int]] = [:]
    private var monthWords: [Date: Int] = [:]
    private var applications: [String: InsightApplication] = [:]

    init(now: Date, week: Date, calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        shownWeek = calendar.dateInterval(of: .weekOfYear, for: week)!
        result = HistoryInsights(calendar: calendar)
    }

    mutating func add(date: Date, words: Int, duration: Double?, bundle: String?, name: String?) {
        result.entryCount += 1
        guard words > 0 else { return }
        result.totalWords += words
        result.firstEntryDate = min(result.firstEntryDate ?? date, date)
        let day = calendar.startOfDay(for: date)
        dailyWords[day, default: 0] += words
        if day == today { result.todayWords += words }
        if let month = calendar.dateInterval(of: .month, for: date)?.start { monthWords[month, default: 0] += words }
        let weekday = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
        result.weekdayHours[weekday][calendar.component(.hour, from: date)] += words
        let thisWeek = date >= weekStart
        if thisWeek { result.weekWords += words }
        if date >= shownWeek.start, date < shownWeek.end {
            weekHours[day, default: Array(repeating: 0, count: 24)][calendar.component(.hour, from: date)] += words
        }
        if let duration, duration.isFinite, duration > 0 {
            result.timedEntryCount += 1
            result.timedWords += words
            result.audioSeconds += duration
            if thisWeek {
                result.weekTimedWords += words
                result.weekAudioSeconds += duration
            }
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
            applications[key] = InsightApplication(id: key, name: label ?? identifier ?? "Unknown app", bundleIdentifier: identifier, words: words)
        }
    }

    mutating func finish() -> HistoryInsights {
        result.days = (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map {
                let day = calendar.startOfDay(for: $0)
                return InsightWords(date: day, words: dailyWords[day, default: 0])
            }
        }
        result.week = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: shownWeek.start).map {
                let day = calendar.startOfDay(for: $0)
                return InsightDay(date: day, hours: weekHours[day] ?? Array(repeating: 0, count: 24))
            }
        }
        result.months = (-11...0).compactMap { offset in
            calendar.date(byAdding: .month, value: offset, to: today).flatMap { calendar.dateInterval(of: .month, for: $0)?.start }.map {
                InsightWords(date: $0, words: monthWords[$0, default: 0])
            }
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

// MARK: - Word cloud

public struct InsightWord: Sendable, Identifiable, Hashable {
    public var word: String
    public var count: Int
    public var id: String { word }
}

/// The nouns said most in the requested period.
public struct InsightWordCloud: Sendable {
    public var words: [InsightWord] = []
    public var entryCount = 0
}

/// Picks the nouns out of dictated text, by dictionary form, so "chart" and "charts" count as one word.
struct SpokenWordCounter {
    private let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])

    func nouns(in text: String) -> [String] {
        tagger.string = text
        // ponytail: languages without word classes keep every word, little ones included; add stop lists if that reads badly.
        let classified = tagger.dominantLanguage.map { NLTagger.availableTagSchemes(for: .word, language: $0).contains(.lexicalClass) } ?? false
        var words: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            guard !classified || tag == .noun else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            // Abbreviation-style tokens keep their full stop ("Dia."); the cloud wants the word alone.
            let word = (lemma.flatMap { $0.isEmpty ? nil : $0 } ?? String(text[range])).lowercased()
                .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            // One letter of an alphabet is noise, but one Chinese or Japanese character is often a whole noun (书, 車).
            let ideograph = word.count == 1 && word.unicodeScalars.allSatisfy(\.properties.isIdeographic)
            if word.count > 1 || ideograph, word.contains(where: \.isLetter) { words.append(word) }
            return true
        }
        return words
    }

    static func top(_ counts: [String: Int], limit: Int) -> [InsightWord] {
        counts.map { InsightWord(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(limit).map { $0 }
    }
}
