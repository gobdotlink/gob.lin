import Foundation

/// Every number the Hoard reads, gathered from History, Meetings, People and the dictionary.
public struct HoardStats: Sendable, Equatable {
    public var dictations = HoardTally()
    public var meetings = HoardMeetingTally()
    /// The most people ever named at once, and the most dictionary words.
    public var people = 0
    public var dictionaryWords = 0
    /// Secrets only the app sees happen, such as dictating while a meeting records.
    public var noticed: Set<HoardSecret> = []

    public init(dictations: HoardTally = HoardTally(), meetings: HoardMeetingTally = HoardMeetingTally(), people: Int = 0,
                dictionaryWords: Int = 0, noticed: Set<HoardSecret> = []) {
        self.dictations = dictations
        self.meetings = meetings
        self.people = people
        self.dictionaryWords = dictionaryWords
        self.noticed = noticed
    }

    /// The shelf's number, in the units `HoardShelf.phrase` reads.
    public func value(_ shelf: HoardShelf, calendar: Calendar = .current) -> Int {
        switch shelf {
        case .words: dictations.words
        case .dictations: dictations.dictations
        case .talk: Int(dictations.audioSeconds / 60)
        case .saved: Int(dictations.typingSecondsSaved / 3600)
        case .meetings: meetings.count
        case .meetingTime: Int(meetings.seconds / 3600)
        case .streak: dictations.longestStreak(calendar: calendar)
        case .bigDay: dictations.biggestDay
        case .apps: dictations.applications.count
        case .dictionary: dictionaryWords
        case .people: people
        case .marks: meetings.marks
        case .secrets: secrets().count
        }
    }

    public func secrets(now: Date = Date(), calendar: Calendar = .current) -> Set<HoardSecret> {
        var found = dictations.found.union(meetings.found).union(noticed)
        if dictations.hasWeekend(calendar: calendar) { found.insert(.weekend) }
        if dictations.hasFullWeek(calendar: calendar) { found.insert(.fullWeek) }
        if let first = dictations.firstDate, let year = calendar.date(byAdding: .year, value: 1, to: first), now >= year {
            found.insert(.anniversary)
        }
        return found
    }
}

/// Running totals over every dictation History has held, from every device. Each dictation is added once, so deleting
/// one, or retention trimming it, never takes anything back. `HistoryStore.hoardTally` keeps it.
public struct HoardTally: Codable, Sendable, Equatable {
    public var words = 0
    public var dictations = 0
    /// Words and recorded audio from dictations that have a length, for typing saved.
    public var timedWords = 0
    public var audioSeconds: Double = 0
    /// Each app dictated into, by bundle identifier or name.
    public var applications: Set<String> = []
    /// Words on each day with any, keyed yyyymmdd: a Gregorian date in the time zone the dictation was added in, so
    /// switching calendars never breaks a streak.
    public var days: [Int: Int] = [:]
    public var firstDate: Date?
    public var found: Set<HoardSecret> = []
    // Apps and tones for the days most recently added to, and the most recently added start times, for secrets that
    // look at one day or ten minutes. Kept by when they were added, not when they happened, so a batch of older
    // dictations synced in late still finds its neighbours.
    var recentApps: [Int: Set<String>] = [:]
    var recentTones: [Int: Set<String>] = [:]
    var recentDays: [Int] = []
    var recentStarts: [Double] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        words = try values.decodeIfPresent(Int.self, forKey: .words) ?? 0
        dictations = try values.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        timedWords = try values.decodeIfPresent(Int.self, forKey: .timedWords) ?? 0
        audioSeconds = try values.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 0
        applications = try values.decodeIfPresent(Set<String>.self, forKey: .applications) ?? []
        days = try values.decodeIfPresent([Int: Int].self, forKey: .days) ?? [:]
        firstDate = try values.decodeIfPresent(Date.self, forKey: .firstDate)
        // A secret a later build adds or drops doesn't make the tally unreadable.
        found = HoardSecret.known(try values.decodeIfPresent([String].self, forKey: .found))
        recentApps = try values.decodeIfPresent([Int: Set<String>].self, forKey: .recentApps) ?? [:]
        recentTones = try values.decodeIfPresent([Int: Set<String>].self, forKey: .recentTones) ?? [:]
        recentDays = try values.decodeIfPresent([Int].self, forKey: .recentDays) ?? []
        recentStarts = try values.decodeIfPresent([Double].self, forKey: .recentStarts) ?? []
    }

    public var typingSecondsSaved: Double {
        max(0, Double(timedWords) / HistoryInsights.typingWordsPerMinute * 60 - audioSeconds)
    }

    public var biggestDay: Int { days.values.max() ?? 0 }

    /// A dictation with no words counts for nothing.
    public mutating func add(date: Date, words: Int, duration: Double?, application: String?, deviceKind: String?,
                             tone: String?, text: String?, calendar: Calendar = .current) {
        guard words > 0 else { return }
        self.words += words
        dictations += 1
        if let duration, duration.isFinite, duration > 0 {
            timedWords += words
            audioSeconds += duration
        }
        let calendar = Self.civil(calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let day = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        days[day, default: 0] += words
        firstDate = min(firstDate ?? date, date)

        let hour = parts.hour ?? 12
        if (2..<4).contains(hour) { found.insert(.night) }
        if (4..<6).contains(hour) { found.insert(.early) }
        if words >= 500 { found.insert(.monologue) }
        if deviceKind == HistoryDevice.iPhone { found.insert(.pocket) }
        if parts.month == 1, parts.day == 1 { found.insert(.newYear) }
        if parts.month == 10, parts.day == 31 { found.insert(.halloween) }
        if let text, Self.laughs(text) { found.insert(.cackle) }

        let application = application?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !application.isEmpty {
            applications.insert(application)
            recentApps[day, default: []].insert(application)
            if recentApps[day]!.count >= 10 { found.insert(.juggler) }
        }
        if let tone, !tone.isEmpty {
            recentTones[day, default: []].insert(tone)
            if recentTones[day]!.count >= 2 { found.insert(.split) }
        }
        recentDays.removeAll { $0 == day }
        recentDays.append(day)
        if recentDays.count > 7 {
            recentDays.removeFirst(recentDays.count - 7)
            let kept = Set(recentDays)
            recentApps = recentApps.filter { kept.contains($0.key) }
            recentTones = recentTones.filter { kept.contains($0.key) }
        }
        recentStarts.append(date.timeIntervalSince1970)
        if recentStarts.count > 40 { recentStarts.removeFirst(recentStarts.count - 40) }
        let starts = recentStarts.sorted()
        if starts.count >= 10, (0...(starts.count - 10)).contains(where: { starts[$0 + 9] - starts[$0] <= 600 }) {
            found.insert(.swarm)
        }
    }

    /// The most days in a row with words.
    public func longestStreak(calendar: Calendar = .current) -> Int {
        let calendar = Self.civil(calendar)
        var longest = 0, run = 0
        var previous: Date?
        for day in dates(calendar: calendar) {
            let next = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            run = next.map { calendar.isDate($0, inSameDayAs: day) } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    func hasWeekend(calendar: Calendar) -> Bool {
        let calendar = Self.civil(calendar)
        let active = Set(days.keys)
        return dates(calendar: calendar).contains { day in
            guard calendar.component(.weekday, from: day) == 7, let sunday = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return active.contains(Self.key(sunday, calendar: calendar))
        }
    }

    func hasFullWeek(calendar: Calendar) -> Bool {
        let calendar = Self.civil(calendar)
        let active = Set(days.keys)
        return dates(calendar: calendar).contains { day in
            guard calendar.component(.weekday, from: day) == 2 else { return false }
            return (1...4).allSatisfy { offset in
                calendar.date(byAdding: .day, value: offset, to: day).map { active.contains(Self.key($0, calendar: calendar)) } ?? false
            }
        }
    }

    /// Noon of each day with words, oldest first.
    private func dates(calendar: Calendar) -> [Date] {
        days.keys.sorted().compactMap { key in
            calendar.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100, hour: 12))
        }
    }

    private static func key(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// The Gregorian calendar in `calendar`'s time zone, for day keys and the dated secrets.
    private static func civil(_ calendar: Calendar) -> Calendar {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        return civil
    }

    /// "ha ha ha", "hahaha", "Ha-ha-ha!" and longer.
    static func laughs(_ text: String) -> Bool {
        text.range(of: #"\bha(?:[\s,.!-]*ha){2,}\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension HoardSecret {
    /// The secrets in `names` this build knows; one a later build adds or drops doesn't make a record unreadable.
    static func known(_ names: [String]?) -> Set<HoardSecret> { Set(names?.compactMap(HoardSecret.init(rawValue:)) ?? []) }
}

/// Running totals over every finished meeting. Like `HoardTally`, deleting a meeting takes nothing back.
public struct HoardMeetingTally: Codable, Sendable, Equatable {
    public var counted: Set<String> = []
    public var seconds: Double = 0
    public var marks = 0
    public var found: Set<HoardSecret> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        counted = try values.decodeIfPresent(Set<String>.self, forKey: .counted) ?? []
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        marks = try values.decodeIfPresent(Int.self, forKey: .marks) ?? 0
        found = HoardSecret.known(try values.decodeIfPresent([String].self, forKey: .found))
    }

    public var count: Int { counted.count }

    /// Adds a finished meeting once; false if it was already counted.
    @discardableResult
    public mutating func add(id: String, seconds: Double, voices: Int, marks: Int) -> Bool {
        guard counted.insert(id).inserted else { return false }
        if seconds.isFinite, seconds > 0 { self.seconds += seconds }
        self.marks += max(0, marks)
        if seconds > 2 * 3600 { found.insert(.marathon) }
        if voices >= 5 { found.insert(.feast) }
        return true
    }
}

/// What the Hoard holds and when each treasure arrived. Treasures are never taken back.
public struct HoardLedger: Codable, Sendable, Equatable {
    public struct Find: Codable, Sendable, Equatable {
        public var date: Date
        /// Found when the Hoard first counted, from what was already there.
        public var before: Bool
    }

    public var found: [String: Find] = [:]
    /// Found since the Hoard was last open.
    public var unseen: Set<String> = []
    /// Found but not yet celebrated in the overlay.
    public var pending: Set<String> = []
    public var lastCelebration: Date?
    public var meetings = HoardMeetingTally()
    public var people = 0
    public var dictionaryWords = 0
    public var noticed: Set<HoardSecret> = []
    /// The lifetime words the milestones this replaced had counted, which History may no longer hold.
    public var legacyWords = 0
    /// Whether the Hoard has counted before, so the first count files everything quietly.
    public var started = false

    public init() {}

    /// Fields a later build adds read as their defaults, so the ledger never becomes unreadable.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        found = try values.decodeIfPresent([String: Find].self, forKey: .found) ?? [:]
        unseen = try values.decodeIfPresent(Set<String>.self, forKey: .unseen) ?? []
        pending = try values.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
        lastCelebration = try values.decodeIfPresent(Date.self, forKey: .lastCelebration)
        meetings = try values.decodeIfPresent(HoardMeetingTally.self, forKey: .meetings) ?? HoardMeetingTally()
        people = try values.decodeIfPresent(Int.self, forKey: .people) ?? 0
        dictionaryWords = try values.decodeIfPresent(Int.self, forKey: .dictionaryWords) ?? 0
        noticed = HoardSecret.known(try values.decodeIfPresent([String].self, forKey: .noticed))
        legacyWords = try values.decodeIfPresent(Int.self, forKey: .legacyWords) ?? 0
        started = try values.decodeIfPresent(Bool.self, forKey: .started) ?? false
    }

    /// Files what `earned` holds that isn't here yet and returns it. The first time, and when `quietly`, they're
    /// found before the Hoard: not new and not celebrated.
    @discardableResult
    public mutating func record(_ earned: Set<String>, now: Date = Date(), quietly: Bool = false) -> [Treasure] {
        let quiet = quietly || !started
        started = true
        let new = Hoard.treasures.filter { earned.contains($0.id) && found[$0.id] == nil }
        for treasure in new {
            found[treasure.id] = Find(date: now, before: quiet)
            if !quiet {
                unseen.insert(treasure.id)
                pending.insert(treasure.id)
            }
        }
        return new
    }

    /// The one treasure the overlay should celebrate now: at most one a calendar day, the most precious found in the
    /// last three days. The rest stay in the Hoard, new.
    public mutating func celebration(now: Date = Date(), calendar: Calendar = .current) -> Treasure? {
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        pending = pending.filter { (found[$0]?.date ?? .distantPast) >= cutoff }
        if let last = lastCelebration, calendar.isDate(last, inSameDayAs: now) { return nil }
        let order = Dictionary(uniqueKeysWithValues: Hoard.treasures.enumerated().map { ($1.id, $0) })
        guard let best = pending.compactMap(Hoard.treasure).max(by: { a, b in
            if a.material.rank != b.material.rank { return a.material.rank < b.material.rank }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }) else { return nil }
        pending.remove(best.id)
        lastCelebration = now
        return best
    }
}
