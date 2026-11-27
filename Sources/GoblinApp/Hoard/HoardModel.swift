import Combine
import Foundation
import GoblinCore
import GoblinMeetings

/// The Hoard's ledger and the numbers behind it. History counts dictations (`HistoryStore.hoardTally`); meetings,
/// people and dictionary words are counted here. Treasures are never taken back, whatever is deleted later.
@MainActor
final class HoardModel: ObservableObject {
    @Published private(set) var ledger: HoardLedger
    /// The latest numbers, for progress toward what's next. Nil until the first count finishes.
    @Published private(set) var stats: HoardStats?
    /// History couldn't be read at the last count, so dictation progress may be behind.
    @Published private(set) var historyUnavailable = false

    nonisolated static let ledgerKey = "hoard.ledger"
    /// The overlay switch: Settings › Overlay › Celebrate treasures.
    nonisolated static let celebrateKey = "overlay.milestones"
    /// The words-only milestones this replaced: their lifetime total and the last threshold reached.
    private static let legacyKeys = ["milestones.words", "milestones.celebrated"]

    private let defaults: UserDefaults
    private let history: HistoryModel
    private let meetings: MeetingsController
    private let dictionary: DictionaryModel
    private var counting: Task<[Treasure], Never>?
    /// The last tally History gave, so other shelves keep counting while it can't be read.
    private var lastTally: HoardTally?
    private var subscriptions: Set<AnyCancellable> = []

    init(defaults: UserDefaults, history: HistoryModel, meetings: MeetingsController, dictionary: DictionaryModel) {
        self.defaults = defaults
        self.history = history
        self.meetings = meetings
        self.dictionary = dictionary
        var ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(HoardLedger.self, from: $0) } ?? HoardLedger()
        // Words the old milestones counted stay counted, even if History has since been cleared or trimmed.
        if !ledger.started { ledger.legacyWords = max(ledger.legacyWords, Self.legacyKeys.map(defaults.integer).max() ?? 0) }
        self.ledger = ledger
    }

    /// Counts whenever what the Hoard reads changes: a dictation saved, synced in or retried, a meeting finishing
    /// however it was processed, or a person or dictionary word added. Call once, after the first count has started.
    func observeChanges() {
        guard subscriptions.isEmpty else { return }
        history.$revision.dropFirst().sink { [weak self] _ in self?.recount() }.store(in: &subscriptions)
        dictionary.$entries.map(\.count).removeDuplicates().dropFirst().sink { [weak self] _ in self?.recount() }.store(in: &subscriptions)
        meetings.$people.map { $0.filter { !$0.isMe }.count }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.recount() }.store(in: &subscriptions)
        meetings.$meetings.map { Set($0.filter { $0.state == .ready }.map(\.id)) }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.recount(meetings: true) }.store(in: &subscriptions)
    }

    var unseenCount: Int { ledger.unseen.count }

    /// Counts what's new and files every treasure it reaches; returns the ones just found. Counts run one at a time.
    /// `meetings` lists the meeting folders too, which a dictation doesn't need.
    @discardableResult
    func refresh(meetings includeMeetings: Bool = false) async -> [Treasure] {
        let previous = counting
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.count(includeMeetings: includeMeetings)
        }
        counting = task
        return await task.value
    }

    private func recount(meetings includeMeetings: Bool = false) {
        Task { await refresh(meetings: includeMeetings) }
    }

    /// Something only the app sees happen, such as dictating while a meeting records.
    func notice(_ secret: HoardSecret) {
        guard !ledger.noticed.contains(secret) else { return }
        ledger.noticed.insert(secret)
        save()
    }

    /// The one treasure to celebrate in the overlay now, if celebrations are on and none has shown today.
    func celebration(now: Date = Date()) -> Treasure? {
        guard defaults.object(forKey: Self.celebrateKey) as? Bool ?? true else { return nil }
        guard let treasure = ledger.celebration(now: now) else { return nil }
        save()
        return treasure
    }

    /// The Hoard showed these as new: they aren't any more.
    func markSeen(_ ids: Set<String>) {
        guard !ledger.unseen.isDisjoint(with: ids) else { return }
        ledger.unseen.subtract(ids)
        save()
    }

    private func count(includeMeetings: Bool) async -> [Treasure] {
        // History failing doesn't stop meetings, people and dictionary words from counting; its first readable count
        // still files what was already there quietly.
        var tally = lastTally ?? HoardTally(), first = false
        if let counted = try? await history.store?.hoardTally() {
            (tally, first) = counted
            lastTally = tally
            historyUnavailable = false
        } else {
            historyUnavailable = true
        }
        if includeMeetings { await countMeetings() }
        // Read from People's own file rather than the published list, so the first count sees everyone already named.
        let people = meetings.library.people.people().filter { !$0.isMe }.count
        ledger.people = max(ledger.people, people)
        ledger.dictionaryWords = max(ledger.dictionaryWords, dictionary.entries.count)
        tally.words = max(tally.words, ledger.legacyWords)
        let now = Date()
        let stats = HoardStats(dictations: tally, meetings: ledger.meetings, people: ledger.people,
                               dictionaryWords: ledger.dictionaryWords, noticed: ledger.noticed)
        let found = ledger.record(Hoard.earned(stats, now: now), now: now, quietly: first)
        self.stats = stats
        save()
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
        return found
    }

    /// Adds each finished meeting the Hoard hasn't counted. Only those load their marks.
    private func countMeetings() async {
        let store = meetings.library.store
        for summary in await store.list() where summary.state == .ready && !ledger.meetings.counted.contains(summary.id) {
            let marks = (try? await store.detail(summary.id).marks.count) ?? 0
            ledger.meetings.add(id: summary.id, seconds: summary.duration, voices: Set(summary.speakers).count, marks: marks)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}
