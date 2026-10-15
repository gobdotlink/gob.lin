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
    var warning: String? = nil
}

struct PendingHistoryEntry: Identifiable {
    var entry: HistoryEntry
    var audioURL: URL?
    var ownsAudioSource: Bool
    var id: UUID { entry.id }
}

@MainActor
final class HistoryModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    typealias ReprocessAction = (HistoryEntry, URL?) async throws -> HistoryReprocessResult

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var revision = 0
    @Published private(set) var pending: [PendingHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published var searchText = ""
    @Published var filter: HistoryFilter = .all
    @Published private(set) var counts = HistoryCounts()
    @Published var errorMessage: String?
    @Published var retranscribeAction: ReprocessAction?
    @Published var rewriteAction: ReprocessAction?
    @Published var retention: HistoryRetention
    @Published private(set) var playingEntryID: UUID?
    @Published private(set) var lastFailure: DiagnosticFailure?
    var onRecorded: ((HistoryEntry) -> Void)?
    private(set) var store: HistoryStore?
    private let directory: URL?
    private let defaults: UserDefaults
    private var requestID = UUID()
    private var player: AVAudioPlayer?

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        self.retention = defaults.data(forKey: "history.retention")
            .flatMap { try? JSONDecoder().decode(HistoryRetention.self, from: $0) } ?? HistoryRetention()
        super.init()
        do { store = try HistoryStore(directory: directory) }
        catch { lastFailure = .historyUnavailable; errorMessage = error.localizedDescription }
    }

    /// A failed save keeps its text and original capture available for copy/retry.
    @discardableResult
    func record(_ entry: HistoryEntry, untrimmedAudioURL: URL? = nil, ownsAudioSource: Bool = false) async -> Bool {
        do {
            if store == nil { store = try HistoryStore(directory: directory) }
            guard let store else { return false }
            let saved = try await store.insert(entry, untrimmedAudioURL: untrimmedAudioURL)
            pending.removeAll { $0.id == entry.id }
            lastFailure = nil
            errorMessage = nil
            onRecorded?(saved)
            do { _ = try await store.applyRetention(retention) }
            catch { lastFailure = .historyOperationFailed; errorMessage = "Dictation saved, but retention cleanup failed: \(error.localizedDescription)" }
            revision += 1
            await reload()
            return true
        } catch {
            if !pending.contains(where: { $0.id == entry.id }) {
                pending.append(PendingHistoryEntry(entry: entry, audioURL: untrimmedAudioURL, ownsAudioSource: ownsAudioSource))
            }
            errorMessage = "History could not save this dictation. Your raw text is still available below. \(error.localizedDescription)"
            lastFailure = .historySaveFailed
            return false
        }
    }

    func retryPending() async {
        for item in pending {
            let saved = await record(item.entry, untrimmedAudioURL: item.audioURL, ownsAudioSource: item.ownsAudioSource)
            if saved, item.ownsAudioSource, let source = item.audioURL { try? FileManager.default.removeItem(at: source) }
        }
    }

    func reload() async {
        let id = UUID()
        requestID = id
        isLoading = true
        guard let store else { isLoading = false; return }
        do {
            let result = try await store.entries(matching: searchText, filter: filter, limit: 200)
            let counts = try await store.counts()
            guard id == requestID else { return }
            entries = result
            hasMore = result.count == 200
            self.counts = counts
        } catch {
            guard id == requestID else { return }
            errorMessage = error.localizedDescription
            lastFailure = .historyOperationFailed
        }
        if id == requestID { isLoading = false }
    }

    func loadMore() async {
        guard !isLoading, hasMore, let store else { return }
        let id = requestID
        let offset = entries.count
        isLoading = true
        do {
            let result = try await store.entries(matching: searchText, filter: filter, limit: 200, offset: offset)
            guard id == requestID else { return }
            entries.append(contentsOf: result)
            hasMore = result.count == 200
        } catch {
            guard id == requestID else { return }
            errorMessage = error.localizedDescription
            lastFailure = .historyOperationFailed
        }
        if id == requestID { isLoading = false }
    }

    func setStarred(_ starred: Bool, entry: HistoryEntry) async {
        do {
            try await store?.setStarred(starred, id: entry.id)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].starred = starred }
            if let counts = try? await store?.counts() { self.counts = counts }
        } catch { lastFailure = .historyOperationFailed; errorMessage = error.localizedDescription }
    }

    func delete(_ entry: HistoryEntry) async {
        if playingEntryID == entry.id { stopAudio() }
        do {
            try await store?.delete(id: entry.id)
            requestID = UUID()
            isLoading = false
            entries.removeAll { $0.id == entry.id }
            revision += 1
            if let counts = try? await store?.counts() { self.counts = counts }
        } catch { lastFailure = .historyOperationFailed; errorMessage = error.localizedDescription }
    }

    func saveRetention(_ policy: HistoryRetention) async {
        do {
            guard let store else { throw HistoryError.database("History is unavailable") }
            _ = try await store.applyRetention(policy)
            revision += 1
            defaults.set(try JSONEncoder().encode(policy), forKey: "history.retention")
            retention = policy
            await reload()
        } catch { lastFailure = .historyOperationFailed; errorMessage = error.localizedDescription }
    }

    func play(_ entry: HistoryEntry) async {
        if playingEntryID == entry.id { stopAudio(); return }
        do {
            guard let audio = try await store?.audioFileURL(for: entry.id) else {
                errorMessage = "This dictation has no saved audio."
                lastFailure = .historyOperationFailed
                return
            }
            stopAudio()
            player = try AVAudioPlayer(contentsOf: audio)
            player?.delegate = self
            guard player?.play() == true else {
                errorMessage = "The saved audio could not be played."
                lastFailure = .historyOperationFailed
                return
            }
            playingEntryID = entry.id
        } catch { lastFailure = .historyOperationFailed; errorMessage = error.localizedDescription }
    }

    /// How far the current recording has played, 0 to 1.
    var playbackProgress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    /// Loudness of the saved recording in even slices, 0 to 1, for the detail pane's waveform.
    func waveform(for entry: HistoryEntry, bars: Int = 72) async -> [Float] {
        guard entry.audioFilename != nil, let url = try? await store?.audioFileURL(for: entry.id) else { return [] }
        return await Task.detached(priority: .utility) { Self.peaks(url: url, bars: bars) }.value
    }

    nonisolated static func peaks(url: URL, bars: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 600))),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength), slice = max(1, count / bars)
        var levels = stride(from: 0, to: count, by: slice).prefix(bars).map { start -> Float in
            let end = min(count, start + slice)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            return (sum / Float(end - start)).squareRoot()
        }
        let loudest = levels.max() ?? 0
        if loudest > 0 { levels = levels.map { $0 / loudest } }
        return levels
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
            if !flag { self?.lastFailure = .historyOperationFailed; self?.errorMessage = "Playback of the saved audio failed." }
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
                                       latencies: result.latencies, processingWarning: result.warning)
            let saved = await record(revised, untrimmedAudioURL: audioURL)
            if saved, let warning = result.warning { errorMessage = warning }
        } catch { lastFailure = .historyOperationFailed; errorMessage = "History reprocessing failed: \(error.localizedDescription)" }
    }
}
