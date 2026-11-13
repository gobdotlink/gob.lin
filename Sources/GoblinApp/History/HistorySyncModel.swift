import AppKit
import GoblinCore
import os

/// History sync on the Mac: the Settings switch, its status, and the engine while the switch is on.
@MainActor
final class HistorySyncModel: ObservableObject {
    /// Whether this build may sync History. Without it the switch doesn't show, and Diagnostics says why.
    private(set) var isAvailable: Bool
    @Published private(set) var isOn = false
    @Published private(set) var status: HistorySyncStatus = .off
    var onStatus: ((DiagnosticHistorySync) -> Void)?
    private let history: HistoryModel
    private var engine: HistorySyncEngine?
    private var connecting = false
    private static let log = Logger(subsystem: GoblinMetadata.bundleIdentifier + ".history-sync", category: "app")

    init(history: HistoryModel, enabled: Bool) {
        self.history = history
        isAvailable = enabled && HistorySyncEngine.isAvailable()
    }

    /// At launch: reads the switch, and syncs if it's on.
    func start() async {
        guard isAvailable else { onStatus?(.unsigned); return }
        guard let store = history.store else { onStatus?(.historyUnopened); return }
        isOn = (try? await store.isSyncEnabled()) == true
        show(await HistorySyncEngine.status(of: store))
        if isOn { await connect(store) }
    }

    func setOn(_ on: Bool) async {
        guard isAvailable, let store = history.store, on != isOn else { return }
        isOn = on
        if on {
            do { try await store.setSyncEnabled(true) } catch { isOn = false; return }
            await connect(store)
        } else {
            await stop()
            try? await store.setSyncEnabled(false)
            show(.off)
        }
    }

    /// After every History write on this Mac.
    func historyChanged() {
        guard let engine else { return }
        Task { await engine.historyChanged() }
    }

    /// Coming to the front, or Try Again.
    func syncNow() {
        guard let engine else { return }
        Task { await engine.syncNow() }
    }

    /// Keep was raised: what the old Keep left out comes back from iCloud.
    func keepRaised() {
        guard let engine else { return }
        Task { await engine.fetchAll() }
    }

    /// At quit, or when the switch turns off.
    func stop() async {
        let engine = engine
        self.engine = nil
        await engine?.stop()
    }

    private func connect(_ store: HistoryStore) async {
        guard engine == nil, !connecting else { return }
        connecting = true
        let started = await HistorySyncEngine.start(store: store, retention: { [history] in await history.retention })
        connecting = false
        guard let started else { return Self.log.error("History sync couldn't start") }
        // The switch went off while it was starting.
        guard isOn else { return await started.stop() }
        engine = started
        Task { [weak self] in
            for await update in started.updates {
                switch update {
                case .status(let status): self?.show(status)
                case .historyChanged: await self?.history.remoteChanged()
                }
            }
            // Stopped, or sync turned itself off and has finished cleaning up.
            if self?.engine === started { self?.engine = nil }
        }
    }

    /// For screenshots: shows `status` as a running sync would, without CloudKit.
    func preview(_ status: HistorySyncStatus) {
        isAvailable = true
        isOn = ![.off, .purged, .differentAccount].contains(status)
        self.status = status
    }

    private func show(_ status: HistorySyncStatus) {
        self.status = status
        // Sync turned itself off; the status row says why.
        if status == .purged || status == .differentAccount { isOn = false }
        onStatus?(.status(status))
    }
}
