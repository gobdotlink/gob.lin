import AppKit
import GoblinCore
import SwiftUI

struct InsightsView: View {
    @ObservedObject var history: HistoryModel
    @State private var insights: HistoryInsights?
    @State private var cloud: InsightWordCloud?
    /// 0 is this week; −1 the week before.
    @State private var weekOffset = 0
    @State private var cloudRange = CloudRange.today
    @State private var refreshID = UUID()
    @State private var error: String?

    private enum CloudRange: Hashable { case today, week }

    private struct Request: Equatable {
        var week: Int
        var revision: Int
        var refresh: UUID
    }

    var body: some View {
        Form {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { refresh() }
                }
            } else if let insights {
                sections(insights)
            } else {
                Section { Text("Loading local history…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(PlateFormStyle())
        .task(id: Request(week: weekOffset, revision: history.revision, refresh: refreshID)) { await load() }
        .task(id: Request(week: 0, revision: history.revision, refresh: refreshID)) { await loadCloud() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refresh() }
    }

    @ViewBuilder private func sections(_ data: HistoryInsights) -> some View {
        Section("This week") {
            hero(data)
            stats(data)
        }
        Section {
            ActivityRow(days: data.week, calendar: data.calendar)
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                weekStepper(data)
            }
        }
        Section {
            cloudRow
        } header: {
            HStack {
                Text("What you talked about")
                Spacer()
                Picker("Period", selection: $cloudRange) {
                    Text("Today").tag(CloudRange.today)
                    Text("This Week").tag(CloudRange.week)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .tint(GoblinBrand.moss)
                .font(.system(size: 11.5)).textCase(nil).tracking(0).foregroundStyle(.primary)
                .padding(.trailing, 14)
            }
        }
        Section("Where I typed") {
            if data.applications.isEmpty { Text("Apps show up here once History has words.").foregroundStyle(.secondary) }
            ForEach(data.applications) { app in appRow(app, total: data.totalWords) }
        }
        Section {
            DisclosureGroup("How I count") {
                Text("Based on \(data.entryCount.formatted()) saved History entries. Deleting entries and retention lower these totals. Words come from each entry's saved final text, so re-transcriptions and rewrites count again.")
                Text("Talking time is this week's recorded audio, silence included. Speaking pace divides this week's words by that time; entries without usable audio are left out.")
                Text("The word cloud shows the nouns you said most, read from this week's saved text, and counts \"chart\" and \"charts\" as one word.")
                Text("Days and hours use when each dictation started, in \(data.calendar.timeZone.identifier). Weeks begin on \(weekStart(data).formatted(.dateTime.weekday(.wide))). A streak needs words on consecutive days and can end today or yesterday.")
                Text("Everything is counted on this Mac. Insights never send transcripts or statistics anywhere.")
            }
        }
    }

    // MARK: This week

    private func hero(_ data: HistoryInsights) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(data.weekWords.formatted()).font(.system(size: 48, weight: .semibold)).monospacedDigit()
                    Text(data.weekWords == 1 ? "word" : "words").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(talkSentence(data)).font(.system(size: 15, weight: .medium)).padding(.top, 8)
                Text(sinceSentence(data)).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(.vertical, 10)
            Spacer(minLength: 0)
            // The goblin works at the plate's divider while you talk; asleep when there's nothing to type.
            Group {
                if data.weekWords > 0 {
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

    private func stats(_ data: HistoryInsights) -> some View {
        let days = { (count: Int) in count == 1 ? "day" : "days" }
        return HStack(alignment: .top, spacing: 16) {
            stat("Today", value: data.todayWords.formatted(), unit: data.todayWords == 1 ? "word" : "words")
            Divider().padding(.vertical, -9)
            stat("Speaking pace", value: data.weekWordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", unit: "wpm")
            Divider().padding(.vertical, -9)
            stat("Streak", value: data.currentStreak.formatted(),
                 unit: data.currentStreak > 0 ? "\(days(data.currentStreak)) in a row" : "days",
                 detail: "Longest: \(data.longestStreak.formatted()) \(days(data.longestStreak))")
        }
        .padding(.leading, 6)
    }

    private func stat(_ title: String, value: String, unit: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func talkSentence(_ data: HistoryInsights) -> String {
        guard data.weekWords > 0 else { return "Quiet week so far. I'm ready when you are." }
        guard data.weekAudioSeconds > 0 else { return "I did all the typing." }
        let talked = data.weekAudioSeconds < 60 ? "under a minute"
            : Duration.seconds(data.weekAudioSeconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "You talked for \(talked). I did all the typing."
    }

    private func sinceSentence(_ data: HistoryInsights) -> String {
        let start = weekStart(data)
        return data.calendar.isDateInToday(start) ? "That's today so far."
            : "That's this week, \(start.formatted(.dateTime.weekday(.wide))) to today."
    }

    private func weekStart(_ data: HistoryInsights) -> Date {
        data.calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    // MARK: Activity

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
        .font(.system(size: 11.5, weight: .medium)).textCase(nil).tracking(0)
        .padding(.trailing, 10)
    }

    private func step(_ weeks: Int) {
        weekOffset = min(0, weekOffset + weeks)
    }

    // MARK: Word cloud

    @ViewBuilder private var cloudRow: some View {
        let today = cloudRange == .today
        let words = (today ? cloud?.today : cloud?.week) ?? []
        let entries = (today ? cloud?.todayEntries : cloud?.weekEntries) ?? 0
        let period = today ? "today" : "this week"
        if cloud != nil, words.isEmpty {
            HStack(spacing: 10) {
                PixelSprite(sprite: .zz, scale: 2)
                Text("Nothing yet \(period). I'm napping.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if cloud != nil {
            VStack(spacing: 4) {
                PixelWordCloud(words: words, seed: cloudSeed, period: period)
                Text("From \(entries.formatted()) \(entries == 1 ? "dictation" : "dictations") \(period). Hover a word to see how often you said it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text("Reading this week's words…").foregroundStyle(.secondary)
        }
    }

    /// One picture per day and period, so the cloud doesn't reshuffle on every visit.
    private var cloudSeed: UInt64 {
        UInt64(Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0) &* 2 + (cloudRange == .week ? 1 : 0)
    }

    // MARK: Apps

    private func appRow(_ app: InsightApplication, total: Int) -> some View {
        let share = Double(app.words) / Double(max(1, total))
        let percent = share > 0 && share < 0.01 ? "<1%" : share.formatted(.percent.precision(.fractionLength(0)))
        return HStack(spacing: 10) {
            AppIcon(bundleIdentifier: app.bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).fontWeight(.medium).textSelection(.enabled)
                    Spacer()
                    Text("\(app.words.formatted()) \(app.words == 1 ? "word" : "words") · \(percent)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Capsule().fill(GoblinBrand.moss.opacity(0.16)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { Capsule().fill(GoblinBrand.moss).frame(width: max(4, $0.size.width * share)) }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(app.words) words, \(percent)")
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

    @MainActor private func loadCloud() async {
        guard let store = history.store, let words = try? await store.spokenWords(), !Task.isCancelled else { return }
        cloud = words
    }
}

/// Words per day beside When you talk. Both share one width, so the hour squares stay square and the
/// bars stand exactly as tall as the grid.
private struct ActivityRow: View {
    let days: [InsightDay]
    let calendar: Calendar
    @State private var width: CGFloat = 0

    private static let labelWidth: CGFloat = 26
    private static let gap: CGFloat = 2
    /// The divider and the space either side of it.
    private static let middle: CGFloat = 33

    /// Today, when the week shown contains it: full moss, a bold label and its count.
    private var today: Int? { days.firstIndex { calendar.isDateInToday($0.date) } }

    var body: some View {
        let half = max(0, (width - Self.middle) / 2)
        let cell = max(6, ((half - Self.labelWidth - 24 * Self.gap) / 24).rounded(.down))
        HStack(alignment: .top, spacing: 16) {
            bars(width: half, height: 7 * cell + 6 * Self.gap).frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.vertical, -9)
            grid(cell: cell).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Words per day

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        let top = max(1, days.map(\.words).max() ?? 0)
        let startOfToday = calendar.startOfDay(for: Date())
        let elapsed = days.filter { $0.date <= startOfToday }
        let average = elapsed.isEmpty ? 0 : Double(elapsed.reduce(0) { $0 + $1.words }) / Double(elapsed.count)
        let peak = days.indices.max { days[$0].words < days[$1].words }.flatMap { days[$0].words > 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                heading("Words per day", detail: peak.map { "\(dayName($0)) was the big one: \(days[$0].words.formatted())." } ?? "Nothing that week.")
                Spacer(minLength: 0)
                if average > 0 {
                    HStack(spacing: 5) {
                        DashedRule().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 1)
                        Text("avg \(Int(average.rounded()).formatted())").monospacedDigit()
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { index in
                    column(index, top: top, barWidth: (width / 7 * 0.54).rounded(), height: height,
                           labelled: index == today || index == peak, future: days[index].date > startOfToday)
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
                ForEach(days.indices, id: \.self) { index in
                    Text(days[index].date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 10.5, weight: index == today ? .semibold : .regular))
                        .foregroundStyle(index == today ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 7)
        }
    }

    private func column(_ index: Int, top: Int, barWidth: CGFloat, height: CGFloat, labelled: Bool, future: Bool) -> some View {
        let day = days[index]
        let barHeight = day.words > 0 ? max(4, height * CGFloat(day.words) / CGFloat(top)) : 0
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.045))
            if barHeight > 0 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(GoblinBrand.moss.opacity(index == today ? 1 : 0.55))
                    .frame(height: barHeight)
            }
        }
        .frame(width: barWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if labelled {
                Text(day.words.formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .fixedSize().offset(y: -(max(barHeight, 4) + 5))
            }
        }
        .opacity(future ? 0.5 : 1)
        .help("\(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(day.words.formatted()) words")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(day.words) words")
    }

    // MARK: When you talk

    private func grid(cell: CGFloat) -> some View {
        let top = max(1, days.flatMap(\.hours).max() ?? 0)
        let totals = (0..<24).map { hour in days.reduce(0) { $0 + $1.hours[hour] } }
        let busiest = totals.indices.max { totals[$0] < totals[$1] }.flatMap { totals[$0] > 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                heading("When you talk", detail: busiest.map { "Busiest around \(hourName($0))." } ?? "No words that week.")
                Spacer(minLength: 0)
                Text("Each square is one hour").font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(days.indices, id: \.self) { index in
                    let day = days[index]
                    HStack(spacing: Self.gap) {
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10, weight: index == today ? .semibold : .regular))
                            .foregroundStyle(index == today ? .primary : .secondary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(shade(day.hours[hour], top: top))
                                .frame(width: cell, height: cell)
                                .help("\(dayName(index)) \(hourName(hour)) · \(day.hours[hour] > 0 ? "\(day.hours[hour].formatted()) words" : "quiet")")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                    .accessibilityValue(hourSummary(day))
                }
            }
            .padding(.top, 22)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hourName(hour)).frame(width: 6 * (cell + Self.gap), alignment: .leading)
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
            .padding(.leading, Self.labelWidth + Self.gap).padding(.top, 7)
        }
    }

    /// Four steps of moss by share of the week's busiest hour; an empty hour is a faint square.
    private func shade(_ words: Int, top: Int) -> Color {
        guard words > 0 else { return .primary.opacity(0.045) }
        let level = min(3, Int(Double(words) / Double(top) * 4 - 0.0001))
        return GoblinBrand.moss.opacity([0.3, 0.55, 0.8, 1][level])
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func dayName(_ index: Int) -> String {
        calendar.isDateInToday(days[index].date) ? "Today" : days[index].date.formatted(.dateTime.weekday(.wide))
    }

    /// Every active hour with its count, so VoiceOver hears what hovering shows.
    private func hourSummary(_ day: InsightDay) -> String {
        let active = day.hours.indices.filter { day.hours[$0] > 0 }
        guard !active.isEmpty else { return "No words" }
        return active.map { "\(hourName($0)), \(day.hours[$0].formatted()) \(day.hours[$0] == 1 ? "word" : "words")" }.joined(separator: "; ")
    }

    /// The hour on a fixed date in GMT, which has every hour; today's date skips one when the clocks go forward.
    private func hourName(_ hour: Int) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return Date(timeIntervalSinceReferenceDate: Double(hour) * 3600).formatted(style)
    }
}

private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
