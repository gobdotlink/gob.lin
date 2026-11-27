import AppKit
import GoblinCore
import SwiftUI

/// A treasure on its plinth, at a whole-number scale. One not found yet is a flat silhouette.
struct TreasureSprite: View {
    let treasure: Treasure
    var scale: CGFloat = 3
    var silhouette = false

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        let image = Self.image(treasure.id)
        Image(nsImage: image).renderingMode(silhouette ? .template : .original).resizable().interpolation(.none)
            .foregroundStyle(.primary.opacity(0.14))
            .frame(width: image.size.width * scale, height: image.size.height * scale)
            .accessibilityHidden(true)
    }

    @MainActor static func image(_ id: String) -> NSImage {
        if let image = cache[id] { return image }
        let image = GoblinBrand.sprite("hoard/" + id)
        cache[id] = image
        return image
    }
}

/// Everything found so far, shelf by shelf, with the next treasure on each shelf as a silhouette. DESIGN.md › Hoard.
struct HoardView: View {
    @ObservedObject var hoard: HoardModel
    @ObservedObject var meetings: MeetingsController
    /// New since the Hoard was last open, marked for this visit.
    @State private var fresh: Set<String> = []
    @State private var inspected: Treasure?

    var body: some View {
        Form {
            // Finds show from the ledger at once; progress joins them when the first count lands.
            if hoard.stats != nil || !hoard.ledger.found.isEmpty {
                let stats = hoard.stats ?? HoardStats()
                let closest = closest(stats)
                Section {
                    hero(stats, closest: closest)
                    if !closest.isEmpty { closestRow(closest, stats: stats) }
                    if hoard.historyUnavailable {
                        StatusRow(.problem, Text("I can't read History right now, so dictation progress may be behind."))
                    }
                }
                ForEach(shelves, id: \.self) { shelf in
                    Section {
                        shelfGrid(shelf, stats: stats)
                    } header: {
                        HStack {
                            Text(shelf.title)
                            Spacer()
                            let all = Hoard.shelf(shelf)
                            Text("\(all.filter(found).count) of \(all.count)").monospacedDigit()
                        }
                    }
                }
            } else {
                Section { Text("Counting the hoard…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(PlateFormStyle())
        .task { await hoard.refresh(meetings: true) }
        // Anything new while the Hoard is open is marked NEW for this visit, and stops being new when it closes.
        .onChange(of: hoard.ledger.unseen, initial: true) { _, unseen in fresh.formUnion(unseen) }
        .onDisappear { hoard.markSeen(fresh) }
        .sheet(item: $inspected) { TreasureSheet(treasure: $0, hoard: hoard) }
    }

    // MARK: Summary

    private func hero(_ stats: HoardStats, closest: [Rung]) -> some View {
        let count = hoard.ledger.found.count, total = Hoard.treasures.count
        return HStack(alignment: .center, spacing: 22) {
            PixelSprite(sprite: .cackle, scale: 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(count.formatted()).font(.system(size: 48, weight: .semibold)).monospacedDigit()
                    Text("of \(total) treasures").font(.reading.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(sentence(stats, next: closest.first)).font(.row).padding(.top, 6)
                CandleMeter(fraction: Double(count) / Double(total)).frame(maxWidth: 360).padding(.top, 10)
                Text(latest).font(.meta).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func sentence(_ stats: HoardStats, next: Rung?) -> String {
        if hoard.ledger.found.isEmpty { return "Nothing in the hoard yet. One dictation and I'll start a pile." }
        if hoard.ledger.found.count == Hoard.treasures.count { return "Every treasure is in here. Shiny." }
        guard let next else { return "What's left are secrets and records to beat." }
        return "My hoard grows. \(next.treasure.name) is \(remaining(next.treasure, stats)) away."
    }

    private var latest: String {
        let finds = hoard.ledger.found.filter { !$0.value.before }
        // Finds from one count share a date; the later treasure in the catalogue wins, so Latest never flips.
        let order = Dictionary(uniqueKeysWithValues: Hoard.treasures.enumerated().map { ($1.id, $0) })
        guard let (id, find) = finds.max(by: { ($0.value.date, order[$0.key] ?? 0) < ($1.value.date, order[$1.key] ?? 0) }),
              let treasure = Hoard.treasure(id) else {
            return "Counts dictations from your Mac and iPhone."
        }
        return "Latest: \(treasure.name), \(find.date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func closestRow(_ closest: [Rung], stats: HoardStats) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(closest, id: \.treasure.id) { rung in
                Button { inspected = rung.treasure } label: {
                    HStack(spacing: 10) {
                        TreasureSprite(treasure: rung.treasure, scale: 2, silhouette: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rung.treasure.name).font(.row.weight(.semibold)).lineLimit(1)
                            Text("\(remaining(rung.treasure, stats)) to go").font(.meta).foregroundStyle(.secondary).lineLimit(1)
                            CandleMeter(fraction: rung.fraction, height: 3).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverTileStyle())
                .accessibilityLabel("\(rung.treasure.name), \(remaining(rung.treasure, stats)) to go")
            }
        }
    }

    // MARK: Shelves

    /// Meeting shelves show while Meetings is on, or once they hold something.
    private var shelves: [HoardShelf] {
        HoardShelf.allCases.filter { shelf in
            !shelf.needsMeetings || meetings.enabled || Hoard.shelf(shelf).contains(where: found)
        }
    }

    private func found(_ treasure: Treasure) -> Bool { hoard.ledger.found[treasure.id] != nil }

    @ViewBuilder private func shelfGrid(_ shelf: HoardShelf, stats: HoardStats) -> some View {
        let all = Hoard.shelf(shelf)
        // A ladder shows what's found and the next rung; the rest wait unseen. Secrets all show, unfound as "???".
        let next = all.first { !found($0) }
        let shown = shelf == .secrets ? all : all.filter { found($0) || $0.id == next?.id }
        let hidden = all.count - shown.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 132), spacing: 0, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(shown) { treasure in
                TreasureCell(treasure: treasure, find: hoard.ledger.found[treasure.id], isNew: fresh.contains(treasure.id),
                             progress: treasure.id == next?.id && measured(treasure) ? (fraction(treasure, stats), treasure.percent(stats)) : nil) { inspected = treasure }
            }
            if hidden > 0 {
                VStack(spacing: 0) {
                    Text("+\(hidden)").font(.cardTitle).foregroundStyle(.tertiary).frame(height: 84)
                    Ledge()
                    Text("More to find").font(.meta.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 7)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4).padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hidden) more to find")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Progress

    private struct Rung { var treasure: Treasure; var fraction: Double }

    /// The next treasure on each shown shelf, closest first. Streaks and big days count a personal best, not a running
    /// total, so they never read as nearly there.
    private func closest(_ stats: HoardStats) -> [Rung] {
        shelves.filter { ![.secrets, .streak, .bigDay].contains($0) }.compactMap { shelf in
            Hoard.shelf(shelf).first { !found($0) }.flatMap { measured($0) ? Rung(treasure: $0, fraction: fraction($0, stats)) : nil }
        }
        .sorted { $0.fraction > $1.fraction }
        .prefix(3).map { $0 }
    }

    private func fraction(_ treasure: Treasure, _ stats: HoardStats) -> Double {
        guard let threshold = treasure.threshold, threshold > 0 else { return 0 }
        return min(1, Double(stats.value(treasure.shelf)) / Double(threshold))
    }

    /// Whether `treasure` has a number to show yet: secrets never do, and History's shelves wait for its first tally.
    private func measured(_ treasure: Treasure) -> Bool {
        treasure.threshold != nil && (hoard.dictationsKnown || !treasure.shelf.countsDictations)
    }

    /// What's left to reach `treasure`: "1,520 words", "2 hours 10 minutes".
    private func remaining(_ treasure: Treasure, _ stats: HoardStats) -> String {
        treasure.shelf.phrase(max(1, (treasure.threshold ?? 0) - stats.value(treasure.shelf)))
    }
}

extension Treasure {
    /// How far there, in whole percent below 100, the same on the shelf and up close.
    func percent(_ stats: HoardStats) -> Int {
        guard let threshold, threshold > 0 else { return 0 }
        return min(99, stats.value(shelf) * 100 / threshold)
    }
}

/// One treasure on its shelf: lit when found, a silhouette with a progress bar when it's next.
private struct TreasureCell: View {
    let treasure: Treasure
    let find: HoardLedger.Find?
    let isNew: Bool
    /// Set for the next rung on a shelf: the meter's fraction and the whole percent read aloud.
    let progress: (fraction: Double, percent: Int)?
    let action: () -> Void

    private var hiddenSecret: Bool { treasure.secret != nil && find == nil }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    if find != nil { CandleGlow().frame(width: 104, height: 84) }
                    TreasureSprite(treasure: treasure, scale: 3, silhouette: find == nil)
                }
                .frame(height: 84)
                Ledge()
                Text(hiddenSecret ? "???" : treasure.name).font(.meta.weight(.semibold))
                    .foregroundStyle(find == nil ? .secondary : .primary)
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                Text(detail).font(.meta).foregroundStyle(.secondary).monospacedDigit()
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let progress { CandleMeter(fraction: progress.fraction, height: 3).frame(width: 52).padding(.top, 5) }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4).padding(.bottom, 6)
            .overlay(alignment: .topTrailing) {
                if isNew { Text("NEW").font(.system(size: 9, weight: .bold)).foregroundStyle(GoblinBrand.candle).padding(6) }
            }
        }
        .buttonStyle(HoverTileStyle())
        .accessibilityLabel(accessibilityText)
    }

    private var detail: String {
        if hiddenSecret { return "A secret" }
        if let find, !find.before { return find.date.formatted(.dateTime.day().month(.abbreviated)) }
        return treasure.requirement
    }

    private var accessibilityText: String {
        if hiddenSecret { return "A secret, not found yet" }
        if let find {
            let when = find.before ? "found" : "found " + find.date.formatted(date: .long, time: .omitted)
            return "\(isNew ? "New: " : "")\(treasure.name), \(when)"
        }
        guard let progress else { return "\(treasure.name), \(treasure.requirement), not found yet" }
        return "\(treasure.name), \(treasure.requirement), \(progress.percent) percent there"
    }
}

/// A treasure up close: what it's for, the goblin's line and when it was found.
struct TreasureSheet: View {
    let treasure: Treasure
    @ObservedObject var hoard: HoardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let find = hoard.ledger.found[treasure.id]
        let hiddenSecret = treasure.secret != nil && find == nil
        VStack(spacing: 0) {
            ZStack {
                if find != nil { CandleGlow().frame(width: 260, height: 220) }
                TreasureSprite(treasure: treasure, scale: 8, silhouette: find == nil)
            }
            .frame(height: 224)
            Text(hiddenSecret ? "A Secret" : treasure.name).font(.cardTitle)
            Text(hiddenSecret ? "I'll tell you when you find it." : "\(treasure.requirement) · \(treasure.shelf.title)")
                .font(.status).foregroundStyle(.secondary).padding(.top, 2)
            Text(hiddenSecret ? "Some treasures only show up once you stumble on them." : treasure.line)
                .font(.row).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 8) {
                Chip(text: status(find), candle: find != nil)
                if !hiddenSecret { Chip(text: "\(treasure.material.name) plinth") }
            }
            .padding(.top, 14)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).prominent()
            }
            .closingActions()
            .padding(.top, 20)
        }
        .padding(GoblinBrand.pagePadding)
        .frame(width: 380)
        .onExitCommand { dismiss() }
    }

    private func status(_ find: HoardLedger.Find?) -> String {
        if let find { return find.before ? "Found before the Hoard" : "Found \(find.date.formatted(date: .long, time: .omitted))" }
        guard treasure.threshold != nil, let stats = hoard.stats, hoard.dictationsKnown || !treasure.shelf.countsDictations else {
            return "Not found yet"
        }
        let value = stats.value(treasure.shelf)
        // A streak or a big day is a record to beat, not a total that fills up.
        if [.streak, .bigDay].contains(treasure.shelf) { return "Best so far: \(treasure.shelf.phrase(value))" }
        return "\(treasure.percent(stats))% there · \(treasure.shelf.phrase(value)) so far"
    }
}

private struct Chip: View {
    let text: String
    var candle = false

    var body: some View {
        Text(text).font(.meta).foregroundStyle(candle ? AnyShapeStyle(GoblinBrand.candle) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// The shelf a treasure stands on.
private struct Ledge: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 4)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.5)).frame(height: 0.5).blendMode(.plusLighter) }
            .padding(.horizontal, -4)
    }
}

/// Candlelight behind a found treasure.
private struct CandleGlow: View {
    var body: some View {
        Ellipse().fill(RadialGradient(colors: [GoblinBrand.candle.opacity(0.26), GoblinBrand.candle.opacity(0)],
                                      center: .center, startRadius: 0, endRadius: 52))
    }
}

/// A thin candle bar on a faint track.
private struct CandleMeter: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(GoblinBrand.candle).frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A tile that tints moss under the pointer, over its whole shape.
private struct HoverTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverTile(configuration: configuration)
    }

    private struct HoverTile: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(4)
                .background(GoblinBrand.selection.opacity(hovering || configuration.isPressed ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}
