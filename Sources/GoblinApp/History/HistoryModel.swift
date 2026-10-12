import AVFoundation
import GoblinCore
import SwiftUI

struct HistoryReprocessResult {
    var rawText: String
    var finalText: String
    var tone: String
    var polished: Bool
    var model: String
    var latencies: DictationTimings
}

struct PendingHistoryEntry: Identifiable {
    var entry: HistoryEntry
    var audioURL: URL?
    var id: UUID { entry.id }
}

@MainActor
final class HistoryModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    typealias ReprocessAction = (HistoryEntry, URL?) async throws -> HistoryReprocessResult

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var pending: [PendingHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var retranscribeAction: ReprocessAction?
    @Published var rewriteAction: ReprocessAction?
    @Published var retention: HistoryRetention
    @Published private(set) var playingEntryID: UUID?
    var onRecorded: ((HistoryEntry) -> Void)?
    private(set) var store: HistoryStore?
    private let directory: URL?
    private var requestID = UUID()
    private var player: AVAudioPlayer?

    init(directory: URL? = nil) {
        self.directory = directory
        self.retention = UserDefaults.standard.data(forKey: "history.retention")
            .flatMap { try? JSONDecoder().decode(HistoryRetention.self, from: $0) } ?? HistoryRetention()
        super.init()
        do { store = try HistoryStore(directory: directory) }
        catch { errorMessage = error.localizedDescription }
    }

    /// A failed save keeps its text and original capture available for copy/retry.
    @discardableResult
    func record(_ entry: HistoryEntry, untrimmedAudioURL: URL? = nil) async -> Bool {
        do {
            if store == nil { store = try HistoryStore(directory: directory) }
            guard let store else { return false }
            let saved = try await store.insert(entry, untrimmedAudioURL: untrimmedAudioURL)
            pending.removeAll { $0.id == entry.id }
            onRecorded?(saved)
            do { _ = try await store.applyRetention(retention) }
            catch { errorMessage = "Dictation saved, but retention cleanup failed: \(error.localizedDescription)" }
            await reload()
            return true
        } catch {
            if !pending.contains(where: { $0.id == entry.id }) {
                pending.append(PendingHistoryEntry(entry: entry, audioURL: untrimmedAudioURL))
            }
            errorMessage = "History could not save this dictation. Your raw text is still available below. \(error.localizedDescription)"
            return false
        }
    }

    func retryPending() async {
        for item in pending { _ = await record(item.entry, untrimmedAudioURL: item.audioURL) }
    }

    func reload() async {
        let id = UUID()
        requestID = id
        isLoading = true
        guard let store else { isLoading = false; return }
        do {
            let result = try await store.entries(matching: searchText, limit: 200)
            guard id == requestID else { return }
            entries = result
            hasMore = result.count == 200
        } catch {
            guard id == requestID else { return }
            errorMessage = error.localizedDescription
        }
        if id == requestID { isLoading = false }
    }

    func loadMore() async {
        guard !isLoading, hasMore, let store else { return }
        let id = requestID
        let offset = entries.count
        isLoading = true
        do {
            let result = try await store.entries(matching: searchText, limit: 200, offset: offset)
            guard id == requestID else { return }
            entries.append(contentsOf: result)
            hasMore = result.count == 200
        } catch {
            guard id == requestID else { return }
            errorMessage = error.localizedDescription
        }
        if id == requestID { isLoading = false }
    }

    func setStarred(_ starred: Bool, entry: HistoryEntry) async {
        do {
            try await store?.setStarred(starred, id: entry.id)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].starred = starred }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ entry: HistoryEntry) async {
        if playingEntryID == entry.id { stopAudio() }
        do {
            try await store?.delete(id: entry.id)
            requestID = UUID()
            isLoading = false
            entries.removeAll { $0.id == entry.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveRetention(_ policy: HistoryRetention) async {
        do {
            guard let store else { throw HistoryError.database("History is unavailable") }
            _ = try await store.applyRetention(policy)
            UserDefaults.standard.set(try JSONEncoder().encode(policy), forKey: "history.retention")
            retention = policy
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func play(_ entry: HistoryEntry) async {
        if playingEntryID == entry.id { stopAudio(); return }
        do {
            guard let audio = try await store?.audioFileURL(for: entry.id) else {
                errorMessage = "This dictation has no saved audio."
                return
            }
            stopAudio()
            player = try AVAudioPlayer(contentsOf: audio)
            player?.delegate = self
            guard player?.play() == true else {
                errorMessage = "The saved audio could not be played."
                return
            }
            playingEntryID = entry.id
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAudio() {
        player?.stop()
        player = nil
        playingEntryID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard self?.player.map(ObjectIdentifier.init) == playerID else { return }
            self?.stopAudio()
            if !flag { self?.errorMessage = "Playback of the saved audio failed." }
        }
    }

    func reprocess(_ entry: HistoryEntry, transcribe: Bool) async {
        guard let action = transcribe ? retranscribeAction : rewriteAction else {
            errorMessage = transcribe ? "Re-transcription is unavailable until a speech engine is selected." : "Enable and configure AI cleanup to rewrite this dictation."
            return
        }
        do {
            let audioURL = try await store?.audioFileURL(for: entry.id)
            let result = try await action(entry, audioURL)
            let revised = HistoryEntry(rawText: result.rawText, finalText: result.finalText,
                                       tone: result.tone, polished: result.polished,
                                       targetBundleIdentifier: entry.targetBundleIdentifier,
                                       targetApplicationName: entry.targetApplicationName,
                                       audioDuration: entry.audioDuration, model: result.model,
                                       latencies: result.latencies)
            _ = await record(revised, untrimmedAudioURL: audioURL)
        } catch { errorMessage = "History reprocessing failed: \(error.localizedDescription)" }
    }
}
