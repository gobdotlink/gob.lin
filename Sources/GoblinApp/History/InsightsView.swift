import AppKit
import GoblinCore
import SwiftUI

struct InsightsView: View {
    @ObservedObject var history: HistoryModel
    @State private var insights: HistoryInsights?
    @State private var details: PeriodDetails?
    @State private var detailsError: String?
    /// 0 is this week; −1 the week before.
    @State private var weekOffset = 0
    @State private var period = InsightPeriod.week
    @State private var refreshID = UUID()
    @State private var error: String?

    private struct PeriodDetails {
        var period: InsightPeriod
        var insights: HistoryInsights
        var cloud: InsightWordCloud
    }

    private func title(_ period: InsightPeriod) -> String {
        switch period {
        case .today: "Today"
        case .week: "This Week"
        case .allTime: "All Time"
        }
    }

    private func description(_ period: InsightPeriod) -> String {
        switch period {
        case .today: "today"
        case .week: "this week"
        case .allTime: "across all saved history"
        }
    }

    private struct Request: Equatable {
        var week: Int
        var revision: Int
        var refresh: UUID
        var period: InsightPeriod = .allTime
    }

    var body: some View {
        Form {
            if let failure = error ?? detailsError {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { refresh() }
                }
            } else if let insights, let details {
                sections(insights, details)
            } else {
                Section { Text("Loading local history…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(PlateFormStyle())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Period", selection: $period) {
                    ForEach([InsightPeriod.today, .week, .allTime], id: \.self) { Text(title($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .tint(GoblinBrand.moss)
            }
        }
        .task(id: Request(week: weekOffset, revision: history.revision, refresh: refreshID)) { await load() }
        .task(id: Request(week: 0, revision: history.revision, refresh: refreshID, period: period)) { await loadDetails() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refresh() }
    }

    /// `all` holds what doesn't narrow to a period: the stepped week, streaks and the entry count.
    @ViewBuilder private func sections(_ all: HistoryInsights, _ shown: PeriodDetails) -> some View {
        Section(title(shown.period)) {
            hero(shown)
            stats(shown, all: all)
        }
        Section {
            ActivityRow(chart: activity(all, shown))
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                activityRange(all, period: shown.period)
            }
        }
        Section("What you talked about") {
            cloudRow(shown)
        }
        // One device is the whole story, so the plate shows only when the period has more than one.
        if shown.insights.devices.count > 1 {
            Section("Where you talked") {
                ForEach(shown.insights.devices) { device in
                    shareRow(device.name, symbol: symbol(device.kind), words: device.words, dictations: device.dictations,
                             total: shown.insights.totalWords)
                }
            }
        }
        Section("Where I typed") {
            if shown.insights.applications.isEmpty { Text("No words typed \(description(shown.period)) yet.").foregroundStyle(.secondary) }
            ForEach(shown.insights.applications) { app in
                shareRow(app.name, bundleIdentifier: app.bundleIdentifier, symbol: app.deviceKind.map(symbol) ?? "app",
                         words: app.words, total: shown.insights.totalWords)
            }
        }
        Section {
            DisclosureGroup("How I count") {
                let devices = all.devices.count > 1 ? " from \(all.devices.count.formatted()) devices" : ""
                Text("Based on \(all.entryCount.formatted()) saved History entries\(devices). Deleting entries and retention lower these totals. Words come from each entry's saved final text, so re-transcriptions and rewrites count again.")
                Text("Typing saved is how long the words would take to type at \(HistoryInsights.typingWordsPerMinute.formatted()) words a minute, less the time you spent talking. Talking time is recorded audio, silence included. Speaking pace divides words by that time. Both leave out entries without usable audio.")
                Text("The period at the top sets everything except Streak, which always counts back from today. App percentages use that period's total words. The cloud shows the nouns you said most and counts \"chart\" and \"charts\" as one word.")
                if all.devices.contains(where: { $0.kind == HistoryDevice.iPhone }) {
                    Text("An iPhone keyboard can't tell which app it types into, so iPhone dictations count under the iPhone. Older iPhone dictations have no recorded length, so they count as words but not towards typing saved or speaking pace.")
                }
                Text("Days and hours use when each dictation started, in \(all.calendar.timeZone.identifier). Weeks begin on \(weekStart(all).formatted(.dateTime.weekday(.wide))). A streak needs words on consecutive days and can end today or yesterday.")
                Text("Everything is counted on this Mac. Insights never send transcripts or statistics anywhere.")
            }
        }
    }

    // MARK: Summary

    private func hero(_ shown: PeriodDetails) -> some View {
        let data = shown.insights
        let minutes = Int(data.typingSecondsSaved / 60)
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 32) {
                    figure("Typing saved", value: minutes == 0 && data.typingSecondsSaved > 0 ? "<1" : minutes.formatted(), unit: minutes > 1 || data.typingSecondsSaved == 0 ? "minutes" : "minute")
                    figure("Words", value: data.totalWords.formatted(), unit: data.totalWords == 1 ? "word" : "words")
                }
                Text(talkSentence(shown)).font(.reading.weight(.medium)).padding(.top, 8)
                Text(sinceSentence(shown)).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(.vertical, 10)
            Spacer(minLength: 0)
            // The goblin works at the plate's divider while you talk; asleep when there's nothing to type.
            Group {
                if data.totalWords > 0 {
                    PixelSprite(sprite: .look, scale: 2)
                        .overlay(alignment: .bottomTrailing) { PixelSprite(sprite: .quill, scale: 2).offset(x: 16, y: -2) }
                } else {
                    PixelSprite(sprite: .closed, scale: 2)
                        .overlay(alignment: .topTrailing) { PixelSprite(sprite: .zz, scale: 2).offset(x: 12) }
                }
            }
            .padding(.trailing, 18).padding(.bottom, -9)
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.status.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 48, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.6)
                Text(unit).font(.reading.weight(.medium)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }

    private func stats(_ shown: PeriodDetails, all: HistoryInsights) -> some View {
        let days = { (count: Int) in count == 1 ? "day" : "days" }
        let dictations = shown.cloud.entryCount
        return HStack(alignment: .top, spacing: 16) {
            stat("Dictations", value: dictations.formatted(), unit: dictations == 1 ? "take" : "takes")
            Divider().padding(.vertical, -9)
            stat("Speaking pace", value: shown.insights.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", unit: "wpm")
            Divider().padding(.vertical, -9)
            stat("Streak", value: all.currentStreak.formatted(),
                 unit: all.currentStreak > 0 ? "\(days(all.currentStreak)) in a row" : "days",
                 detail: "Longest: \(all.longestStreak.formatted()) \(days(all.longestStreak))")
        }
        .padding(.leading, 6)
    }

    private func stat(_ title: String, value: String, unit: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.meta).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.reading.weight(.semibold)).monospacedDigit()
                Text(unit).font(.row.weight(.medium)).foregroundStyle(.secondary)
            }
            if let detail { Text(detail).font(.meta).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func talkSentence(_ shown: PeriodDetails) -> String {
        let data = shown.insights
        guard data.totalWords > 0 else {
            switch shown.period {
            case .today: return "Quiet day so far. I'm ready when you are."
            case .week: return "Quiet week so far. I'm ready when you are."
            case .allTime: return "Nothing yet. I'm ready when you are."
            }
        }
        guard data.audioSeconds > 0 else { return "I did all the typing." }
        let talked = data.audioSeconds < 60 ? "under a minute"
            : Duration.seconds(data.audioSeconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "You talked for \(talked). I did all the typing."
    }

    private func sinceSentence(_ shown: PeriodDetails) -> String {
        let data = shown.insights
        switch shown.period {
        case .today:
            return "That's today so far."
        case .week:
            let start = weekStart(data)
            return data.calendar.isDateInToday(start) ? "That's today so far."
                : "That's this week, \(start.formatted(.dateTime.weekday(.wide))) to today."
        case .allTime:
            guard let first = data.firstEntryDate else { return "That's everything I've kept." }
            return "That's everything I've kept since \(first.formatted(.dateTime.day().month(.wide).year()))."
        }
    }

    private func weekStart(_ data: HistoryInsights) -> Date {
        data.calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    // MARK: Activity

    private func activity(_ all: HistoryInsights, _ shown: PeriodDetails) -> ActivityChart {
        let data = shown.insights
        switch shown.period {
        case .today:
            let today = data.week.first { data.calendar.isDateInToday($0.date) }
            return .today(today?.hours ?? Array(repeating: 0, count: 24), calendar: data.calendar)
        case .week:
            return .week(all.week, calendar: all.calendar)
        case .allTime:
            return .allTime(months: data.months, weekdayHours: data.weekdayHours, calendar: data.calendar)
        }
    }

    @ViewBuilder private func activityRange(_ all: HistoryInsights, period: InsightPeriod) -> some View {
        if period == .week {
            weekStepper(all)
        } else if period == .today {
            Text(Date().formatted(.dateTime.day().month(.abbreviated))).textCase(nil).tracking(0).padding(.trailing, 14)
        }
    }

    private func weekStepper(_ data: HistoryInsights) -> some View {
        let first = data.week.first?.date ?? Date(), last = data.week.last?.date ?? first
        let oldest = data.firstEntryDate.flatMap { data.calendar.dateInterval(of: .weekOfYear, for: $0)?.start }
        return HStack(spacing: 2) {
            Text((first..<last).formatted(.interval.day().month(.abbreviated))).monospacedDigit().padding(.trailing, 4)
            Button { step(-1) } label: { Label("Previous Week", systemImage: "chevron.left").frame(width: 22, height: 20).contentShape(Rectangle()) }
                .disabled(oldest.map { first <= $0 } ?? true)
                .help("Previous Week")
            Button { step(1) } label: { Label("Next Week", systemImage: "chevron.right").frame(width: 22, height: 20).contentShape(Rectangle()) }
                .disabled(weekOffset == 0)
                .help("Next Week")
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .font(.meta.weight(.medium)).textCase(nil).tracking(0)
        .padding(.trailing, 10)
    }

    private func step(_ weeks: Int) {
        weekOffset = min(0, weekOffset + weeks)
    }

    // MARK: Word cloud

    @ViewBuilder private func cloudRow(_ shown: PeriodDetails) -> some View {
        let entries = shown.cloud.entryCount
        if shown.cloud.words.isEmpty {
            HStack(spacing: 10) {
                PixelSprite(sprite: .zz, scale: 2)
                Text("Nothing yet \(description(shown.period)). I'm napping.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 4) {
                PixelWordCloud(words: shown.cloud.words, seed: WordCloudLayout.seed(for: shown.period), period: description(shown.period))
                Text("From \(entries.formatted()) \(entries == 1 ? "dictation" : "dictations") \(description(shown.period)). Hover a word to see how often you said it.")
                    .font(.meta).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Devices and apps

    private func symbol(_ deviceKind: String?) -> String {
        switch deviceKind {
        case HistoryDevice.mac: "laptopcomputer"
        case HistoryDevice.iPhone: "iphone"
        default: "laptopcomputer.and.iphone"
        }
    }

    /// An app or a device with its share of the period's words. Devices add their dictations.
    private func shareRow(_ name: String, bundleIdentifier: String? = nil, symbol: String, words: Int, dictations: Int? = nil,
                          total: Int) -> some View {
        let share = Double(words) / Double(max(1, total))
        let percent = share > 0 && share < 0.01 ? "<1%" : share.formatted(.percent.precision(.fractionLength(0)))
        let counts = ["\(words.formatted()) \(words == 1 ? "word" : "words")",
                      dictations.map { "\($0.formatted()) \($0 == 1 ? "dictation" : "dictations")" }].compactMap { $0 }
        return HStack(spacing: 10) {
            AppIcon(bundleIdentifier: bundleIdentifier, size: 24, symbol: symbol)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).fontWeight(.medium).textSelection(.enabled)
                    Spacer()
                    Text((counts + [percent]).joined(separator: " · "))
                        .font(.status).foregroundStyle(.secondary).monospacedDigit()
                }
                Capsule().fill(GoblinBrand.moss.opacity(0.16)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { Capsule().fill(GoblinBrand.moss).frame(width: max(4, $0.size.width * share)) }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue((counts + [percent]).joined(separator: ", "))
    }

    // MARK: Loading

    private func refresh() { refreshID = UUID() }

    @MainActor private func load() async {
        do {
            guard let store = history.store else { throw HistoryError.database("History is unavailable, so there's nothing to count yet.") }
            let now = Date(), calendar = Calendar.current
            let week = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: now) ?? now
            let result = try await store.insights(now: now, week: week, calendar: calendar)
            try Task.checkCancellation()
            insights = result
            error = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            insights = nil
        }
    }

    @MainActor private func loadDetails() async {
        let requestedPeriod = period
        // Keep the current details on screen, under their own period, until the new ones land. Blanking them
        // collapsed the page, which hid a classic scroll bar and changed the width the cloud is packed to.
        detailsError = nil
        do {
            guard let store = history.store else { throw HistoryError.database("History is unavailable, so there's nothing to count yet.") }
            let now = Date(), calendar = Calendar.current
            let data = try await store.insights(now: now, week: now, calendar: calendar,
                                                since: requestedPeriod.start(now: now, calendar: calendar))
            let cloud = try await store.spokenWords(now: now, calendar: calendar, period: requestedPeriod)
            try Task.checkCancellation()
            guard requestedPeriod == period else { return }
            details = PeriodDetails(period: requestedPeriod, insights: data, cloud: cloud)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, requestedPeriod == period else { return }
            detailsError = error.localizedDescription
        }
    }
}

/// What the Activity plate draws for a period. Without rows, the bars take the whole plate.
private struct ActivityChart {
    struct Bar {
        var label: String
        /// How a sentence names this bar: "Tuesday", "9 AM", "October".
        var name: String
        /// The full name for hovering and VoiceOver.
        var detail: String
        var words: Int
        var current = false
        var future = false
    }

    struct Row {
        var label: String
        var name: String
        var detail: String
        var hours: [Int]
        var current = false
    }

    var title: String
    var empty: String
    var bars: [Bar]
    var rows: [Row] = []
    /// The words the dashed average is taken over; empty draws none.
    var averaged: [Int] = []

    static func today(_ hours: [Int], calendar: Calendar) -> ActivityChart {
        let now = calendar.component(.hour, from: Date())
        return ActivityChart(title: "Words per hour", empty: "Nothing yet today.", bars: hours.indices.map {
            Bar(label: $0 % 6 == 0 ? hourName($0) : "", name: hourName($0), detail: hourName($0),
                words: hours[$0], current: $0 == now, future: $0 > now)
        })
    }

    static func week(_ days: [InsightDay], calendar: Calendar) -> ActivityChart {
        let startOfToday = calendar.startOfDay(for: Date())
        func label(_ day: InsightDay) -> String { day.date.formatted(.dateTime.weekday(.abbreviated)) }
        func name(_ day: InsightDay) -> String { calendar.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.wide)) }
        return ActivityChart(title: "Words per day", empty: "Nothing that week.", bars: days.map {
            Bar(label: label($0), name: name($0), detail: $0.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                words: $0.words, current: calendar.isDateInToday($0.date), future: $0.date > startOfToday)
        }, rows: days.map {
            Row(label: label($0), name: name($0), detail: $0.date.formatted(date: .complete, time: .omitted),
                hours: $0.hours, current: calendar.isDateInToday($0.date))
        }, averaged: days.filter { $0.date <= startOfToday }.map(\.words))
    }

    static func allTime(months: [InsightWords], weekdayHours: [[Int]], calendar: Calendar) -> ActivityChart {
        ActivityChart(title: "Last 12 months", empty: "Nothing in that time.", bars: months.map {
            Bar(label: $0.date.formatted(.dateTime.month(.abbreviated)), name: $0.date.formatted(.dateTime.month(.wide)),
                detail: $0.date.formatted(.dateTime.month(.wide).year()), words: $0.words,
                current: calendar.isDate($0.date, equalTo: Date(), toGranularity: .month))
        }, rows: weekdayHours.indices.map {
            let symbol = (calendar.firstWeekday - 1 + $0) % 7
            let plural = calendar.weekdaySymbols[symbol] + "s"
            return Row(label: calendar.shortWeekdaySymbols[symbol], name: plural, detail: plural, hours: weekdayHours[$0])
        }, averaged: months.drop { $0.words == 0 }.map(\.words))
    }

    /// The hour on a fixed date in GMT, which has every hour; today's date skips one when the clocks go forward.
    static func hourName(_ hour: Int) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return Date(timeIntervalSinceReferenceDate: Double(hour) * 3600).formatted(style)
    }
}

/// The bars beside When you talk. Both share one width, so the hour squares stay square and the
/// bars stand exactly as tall as the grid.
private struct ActivityRow: View {
    let chart: ActivityChart
    @State private var width: CGFloat = 0

    private static let labelWidth: CGFloat = 26
    private static let gap: CGFloat = 2
    /// The divider and the space either side of it.
    private static let middle: CGFloat = 33

    /// The bar for now, when the chart contains it: full moss, a bold label and its count.
    private var current: Int? { chart.bars.firstIndex(where: \.current) }

    var body: some View {
        let half = max(0, (width - Self.middle) / 2)
        let cell = max(6, ((half - Self.labelWidth - 24 * Self.gap) / 24).rounded(.down))
        let height = 7 * cell + 6 * Self.gap
        HStack(alignment: .top, spacing: 16) {
            bars(width: chart.rows.isEmpty ? width : half, height: height).frame(maxWidth: .infinity, alignment: .leading)
            if !chart.rows.isEmpty {
                Divider().padding(.vertical, -9)
                grid(cell: cell).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Bars

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        let bars = chart.bars
        let top = max(1, bars.map(\.words).max() ?? 0)
        let average = chart.averaged.isEmpty ? 0 : Double(chart.averaged.reduce(0, +)) / Double(chart.averaged.count)
        let peak = bars.indices.max { bars[$0].words < bars[$1].words }.flatMap { bars[$0].words > 0 ? $0 : nil }
        // Narrow columns can't hold two counts side by side, so the peak keeps its own.
        let crowded = bars.count > 7 && current != nil && peak != nil && abs(current! - peak!) == 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                heading(chart.title, detail: peak.map { "\(bars[$0].name) was the big one: \(bars[$0].words.formatted())." } ?? chart.empty)
                Spacer(minLength: 0)
                if average > 0 {
                    HStack(spacing: 5) {
                        DashedRule().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 1)
                        Text("avg \(Int(average.rounded()).formatted())").monospacedDigit()
                    }
                    .font(.meta).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            HStack(spacing: 0) {
                ForEach(bars.indices, id: \.self) { index in
                    column(index, top: top, barWidth: (width / CGFloat(bars.count) * 0.54).rounded(), height: height,
                           labelled: index == peak || (index == current && !crowded))
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                if average > 0 {
                    DashedRule().stroke(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1).offset(y: -height * min(1, average / Double(top))).allowsHitTesting(false)
                }
            }
            .padding(.top, 22)
            HStack(spacing: 0) {
                ForEach(bars.indices, id: \.self) { index in
                    Text(bars[index].label)
                        .font(.meta.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? .primary : .secondary)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 7)
        }
    }

    private func column(_ index: Int, top: Int, barWidth: CGFloat, height: CGFloat, labelled: Bool) -> some View {
        let bar = chart.bars[index]
        let barHeight = bar.words > 0 ? max(4, height * CGFloat(bar.words) / CGFloat(top)) : 0
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.primary.opacity(0.045))
            if barHeight > 0 {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(GoblinBrand.moss.opacity(index == current ? 1 : 0.55))
                    .frame(height: barHeight)
            }
        }
        .frame(width: barWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if labelled {
                Text(bar.words.formatted()).font(.meta.weight(.semibold)).monospacedDigit()
                    .fixedSize().offset(y: -(max(barHeight, 4) + 5))
            }
        }
        .opacity(bar.future ? 0.5 : 1)
        .help("\(bar.detail) · \(bar.words.formatted()) words")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.detail)
        .accessibilityValue("\(bar.words) words")
    }

    // MARK: When you talk

    private func grid(cell: CGFloat) -> some View {
        let rows = chart.rows
        let top = max(1, rows.flatMap(\.hours).max() ?? 0)
        let totals = (0..<24).map { hour in rows.reduce(0) { $0 + $1.hours[hour] } }
        let busiest = totals.indices.max { totals[$0] < totals[$1] }.flatMap { totals[$0] > 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                heading("When you talk", detail: busiest.map { "Busiest around \(ActivityChart.hourName($0))." } ?? chart.empty)
                Spacer(minLength: 0)
                Text("Each square is one hour").font(.meta).foregroundStyle(.secondary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: Self.gap) {
                        Text(row.label)
                            .font(.meta.weight(row.current ? .semibold : .regular))
                            .foregroundStyle(row.current ? .primary : .secondary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: Radius.tiny, style: .continuous)
                                .fill(shade(row.hours[hour], top: top))
                                .frame(width: cell, height: cell)
                                .help("\(row.name) \(ActivityChart.hourName(hour)) · \(row.hours[hour] > 0 ? "\(row.hours[hour].formatted()) words" : "quiet")")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.detail)
                    .accessibilityValue(hourSummary(row))
                }
            }
            .padding(.top, 22)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(ActivityChart.hourName(hour)).frame(width: 6 * (cell + Self.gap), alignment: .leading)
                }
            }
            .font(.meta).foregroundStyle(.tertiary).monospacedDigit()
            .padding(.leading, Self.labelWidth + Self.gap).padding(.top, 7)
        }
    }

    /// Four steps of moss by share of the busiest hour; an empty hour is a faint square.
    private func shade(_ words: Int, top: Int) -> Color {
        guard words > 0 else { return .primary.opacity(0.045) }
        let level = min(3, Int(Double(words) / Double(top) * 4 - 0.0001))
        return GoblinBrand.moss.opacity([0.3, 0.55, 0.8, 1][level])
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(detail).font(.status).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// Every active hour with its count, so VoiceOver hears what hovering shows.
    private func hourSummary(_ row: ActivityChart.Row) -> String {
        let active = row.hours.indices.filter { row.hours[$0] > 0 }
        guard !active.isEmpty else { return "No words" }
        return active.map { "\(ActivityChart.hourName($0)), \(row.hours[$0].formatted()) \(row.hours[$0] == 1 ? "word" : "words")" }.joined(separator: "; ")
    }
}

private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
