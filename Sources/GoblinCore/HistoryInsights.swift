import Foundation
import NaturalLanguage
import Synchronization

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
    /// Set when the row is a device rather than an app: an iPhone keyboard can't tell which app it types into,
    /// so an iPhone's dictations count under the iPhone.
    public var deviceKind: String?
}

/// The words, dictations and recorded audio from one kind and name of device. A reinstalled iPhone,
/// with a new device ID, lands in the same row.
public struct InsightDevice: Sendable, Identifiable {
    public var id: String
    /// `HistoryDevice.mac` or `.iPhone`; nil for a device History has no record of.
    public var kind: String?
    public var name: String
    public var words = 0
    public var dictations = 0
    public var audioSeconds: Double = 0
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
    /// Busiest first, like `applications`.
    public var devices: [InsightDevice] = []
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
    private var devices: [String: InsightDevice] = [:]

    init(now: Date, week: Date, calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        shownWeek = calendar.dateInterval(of: .weekOfYear, for: week)!
        result = HistoryInsights(calendar: calendar)
    }

    /// A nil device kind and name is a device History has no record of.
    mutating func add(date: Date, words: Int, duration: Double?, bundle: String?, name: String?,
                      deviceKind: String? = nil, deviceName: String? = nil) {
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
        let seconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let seconds {
            result.timedEntryCount += 1
            result.timedWords += words
            result.audioSeconds += seconds
            if thisWeek {
                result.weekTimedWords += words
                result.weekAudioSeconds += seconds
            }
        }
        let bundle = bundle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.flatMap { $0.isEmpty ? nil : $0 }
        let identifier = bundle.flatMap { $0.isEmpty ? nil : $0 }
        let known = deviceKind.flatMap { kind in deviceName.map { (kind: kind, name: $0) } }
        let deviceKey = known.map { "\($0.kind):\($0.name)" } ?? "unknown"
        var device = devices[deviceKey] ?? InsightDevice(id: deviceKey, kind: known?.kind, name: known?.name ?? "Another device")
        device.words += words
        device.dictations += 1
        device.audioSeconds += seconds ?? 0
        devices[deviceKey] = device
        // An iPhone entry names no app, so its iPhone stands in for one.
        let phone = known?.kind == HistoryDevice.iPhone ? known?.name : nil
        let key = identifier.map { "bundle:" + $0 } ?? label.map { "name:" + $0 } ?? (phone == nil ? "unknown" : "device:" + deviceKey)
        if var app = applications[key] {
            app.words += words
            applications[key] = app
        } else {
            applications[key] = InsightApplication(id: key, name: label ?? identifier ?? phone ?? "Unknown app", bundleIdentifier: identifier,
                                                   words: words, deviceKind: key.hasPrefix("device:") ? HistoryDevice.iPhone : nil)
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
        result.devices = devices.values.sorted {
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
    /// Some text was in a language without word classes on this device, so all its words counted. The system may still
    /// be loading them: counting again with a `wordClassWait` waits for them.
    public var missingWordClasses = false
}

/// Picks the nouns out of dictated text, by dictionary form, so "chart" and "charts" count as one word.
struct SpokenWordCounter {
    private let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    /// Languages met without word classes on this device, either because they have none or because the system
    /// hasn't loaded them yet.
    private(set) var unclassified: Set<NLLanguage> = []

    mutating func nouns(in text: String) -> [String] {
        tagger.string = text
        // ponytail: languages without word classes keep every word, little ones included; add stop lists if that reads badly.
        let language = tagger.dominantLanguage
        let classified = language.map(Self.classifies) ?? false
        if let language, !classified { unclassified.insert(language) }
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

    static func classifies(_ language: NLLanguage) -> Bool {
        NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
    }

    /// When each language's word classes were first asked for this launch.
    private static let asked = Mutex<[NLLanguage: ContinuousClock.Instant]>([:])

    /// Asks the system to load word classes and dictionary forms for `languages`, once a launch, and waits until one
    /// of them has word classes, at most `limit` after it was first asked for. Returns whether one has them now.
    static func load(_ languages: Set<NLLanguage>, waitingAtMost limit: Duration) async -> Bool {
        let now = ContinuousClock.now
        let (new, deadline) = asked.withLock { asked in
            let new = languages.filter { asked[$0] == nil }
            for language in new { asked[language] = now }
            return (new, (languages.compactMap { asked[$0] }.max() ?? now) + limit)
        }
        for language in new {
            for scheme in [NLTagScheme.lexicalClass, .lemma] { NLTagger.requestAssets(for: language, tagScheme: scheme) { _, _ in } }
        }
        // ponytail: polls, because a request for a language that has no word classes never answers.
        while !languages.contains(where: classifies), ContinuousClock.now < deadline,
              (try? await Task.sleep(for: .milliseconds(250))) != nil {}
        return languages.contains(where: classifies)
    }

    static func top(_ counts: [String: Int], limit: Int) -> [InsightWord] {
        counts.map { InsightWord(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(limit).map { $0 }
    }
}
