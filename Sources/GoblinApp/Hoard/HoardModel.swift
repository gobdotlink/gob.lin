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

    nonisolated static let ledgerKey = "hoard.ledger"
    /// The overlay switch: Settings › Overlay › Celebrate treasures.
    nonisolated static let celebrateKey = "overlay.milestones"

    private let defaults: UserDefaults
    private let history: HistoryModel
    private let meetings: MeetingsController
    private let dictionary: DictionaryModel
    private var counting: Task<[Treasure], Never>?

    init(defaults: UserDefaults, history: HistoryModel, meetings: MeetingsController, dictionary: DictionaryModel) {
        self.defaults = defaults
        self.history = history
        self.meetings = meetings
        self.dictionary = dictionary
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(HoardLedger.self, from: $0) } ?? HoardLedger()
        // The words-only milestones this replaces.
        for key in ["milestones.words", "milestones.celebrated"] { defaults.removeObject(forKey: key) }
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

    /// The Hoard was opened: nothing is new any more.
    func markSeen() {
        guard !ledger.unseen.isEmpty else { return }
        ledger.unseen = []
        save()
    }

    private func count(includeMeetings: Bool) async -> [Treasure] {
        guard let store = history.store, let counted = try? await store.hoardTally() else { return [] }
        let (tally, first) = counted
        if includeMeetings { await countMeetings() }
        ledger.people = max(ledger.people, meetings.people.filter { !$0.isMe }.count)
        ledger.dictionaryWords = max(ledger.dictionaryWords, dictionary.entries.count)
        let now = Date()
        let stats = HoardStats(dictations: tally, meetings: ledger.meetings, people: ledger.people,
                               dictionaryWords: ledger.dictionaryWords, noticed: ledger.noticed)
        // A first count of History files everything quietly, like the Hoard's own first count.
        let found = ledger.record(Hoard.earned(stats, now: now), now: now, quietly: first)
        self.stats = stats
        save()
        return found
    }

    /// Adds each finished meeting the Hoard hasn't counted.
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
