import AppKit
import Charts
import GoblinCore
import SwiftUI

struct InsightsView: View {
    @ObservedObject var history: HistoryModel
    @State private var insights: HistoryInsights?
    @State private var selectedDay = Date()
    @State private var followsToday = true
    @State private var refreshID = UUID()
    @State private var loading = false
    @State private var error: String?

    private struct Request: Equatable {
        var day: Date
        var revision: Int
        var refresh: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Try again") { refresh() }
                    }
                } else if let insights {
                    sections(insights)
                } else {
                    Section { Text("Loading local history…").foregroundStyle(.secondary) }
                }
            }
            .formStyle(PlateFormStyle())
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if loading { ProgressView().controlSize(.small) }
                else { Button("Refresh Insights", systemImage: "arrow.clockwise") { refresh() } }
            }
        }
        .task(id: Request(day: selectedDay, revision: history.revision, refresh: refreshID)) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refresh() }
    }

    @ViewBuilder private func sections(_ data: HistoryInsights) -> some View {
        Section {
            if data.entryCount == 0 {
                Label("Your first dictation starts here", systemImage: "waveform").font(.headline)
                Text("Save a dictation to see your words, pace and activity. Insights stay on this Mac.").foregroundStyle(.secondary)
            }
            HStack {
                metric("Today", value: data.todayWords.formatted())
                metric("This week", value: data.weekWords.formatted())
                metric("Total words", value: data.totalWords.formatted())
            }
            HStack {
                metric("Words / minute", value: data.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                metric("Current streak", value: "\(data.currentStreak.formatted()) \(data.currentStreak == 1 ? "day" : "days")")
                metric("Longest streak", value: "\(data.longestStreak.formatted()) \(data.longestStreak == 1 ? "day" : "days")")
            }
        } header: { Text("At a glance") } footer: {
            Text("Based on \(data.entryCount.formatted()) saved History entries. Deletion and retention reduce these totals.")
        }
        Section("Words per day · last 7 days") {
            Chart(data.days) { day in
                BarMark(x: .value("Day", day.date.formatted(.dateTime.weekday(.abbreviated))), y: .value("Words", day.words))
                    .foregroundStyle(GoblinBrand.moss)
                    .annotation(position: .top) { Text(day.words.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                    .accessibilityValue("\(day.words) words")
            }
            .chartYScale(domain: 0...max(1, data.days.map(\.words).max() ?? 0))
            .frame(height: 140).padding(.top, 12)
        }
        Section {
            HStack {
                DatePicker("Day", selection: Binding(get: { selectedDay }, set: {
                    selectedDay = $0
                    followsToday = Calendar.current.isDateInToday($0)
                }), in: ...Date(), displayedComponents: .date)
                Button("Today") { followsToday = true; refresh() }
            }
            LabeledContent("Words", value: data.hours.reduce(0) { $0 + $1.words }.formatted())
            Chart(data.hours) { hour in
                RectangleMark(xStart: .value("Hour start", hour.date),
                              xEnd: .value("Hour end", min(hour.date.addingTimeInterval(3600), data.calendar.dateInterval(of: .day, for: hour.date)!.end)),
                              yStart: .value("Words", 0), yEnd: .value("Words", hour.words))
                    .foregroundStyle(GoblinBrand.moss)
                    .accessibilityLabel(hour.date.formatted(.dateTime.hour().minute().timeZone(.specificName(.short))))
                    .accessibilityValue("\(hour.words) words")
            }
            .chartYScale(domain: 0...max(1, data.hours.map(\.words).max() ?? 0))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .environment(\.calendar, data.calendar)
            .frame(height: 140)
        } header: { Text("Daily timeline") } footer: {
            Text("Words grouped by the hour each entry started · \(data.calendar.timeZone.identifier).")
        }
        Section {
            if data.applications.isEmpty { Text("App usage appears when History contains words.").foregroundStyle(.secondary) }
            ForEach(data.applications) { app in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.name).textSelection(.enabled)
                        Spacer()
                        Text("\(app.words.formatted()) words · \((Double(app.words) / Double(max(1, data.totalWords))).formatted(.percent.precision(.fractionLength(0))))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView(value: Double(app.words), total: Double(max(1, data.totalWords))).tint(GoblinBrand.moss)
                        .accessibilityLabel(app.name).accessibilityValue("\(app.words) words")
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Words by app · all saved history") }
        Section {
            DisclosureGroup("How Insights are counted") {
                Text("Words use History’s saved final-text count: whitespace-separated words, including rewritten text. Re-transcriptions and rewrites are new saved entries and count again. Unsaved dictations are excluded.")
                Text("WPM divides final words by recorded audio minutes, including silence. Only entries with words and a positive, finite audio duration contribute. Processing time is excluded. \(data.timedEntryCount.formatted()) entries have usable duration; — means none is available.")
                Text("Days use each entry’s start time in your current calendar and time zone. This week begins \(data.calendar.dateInterval(of: .weekOfYear, for: Date())!.start.formatted(date: .abbreviated, time: .omitted)). A streak needs words on consecutive calendar days; the current streak can end today or yesterday. Future-dated entries wait until their start time.")
                Text("All calculations happen locally from the entries still in History. Insights do not send transcripts or statistics anywhere.")
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        if followsToday { selectedDay = Date() }
        refreshID = UUID()
    }

    @MainActor private func load() async {
        loading = true
        error = nil
        do {
            guard let store = history.store else { throw HistoryError.database("History is unavailable. Open History to retry saving, then refresh Insights.") }
            let result = try await store.insights(day: selectedDay)
            try Task.checkCancellation()
            insights = result
            loading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            insights = nil
            loading = false
        }
    }
}
