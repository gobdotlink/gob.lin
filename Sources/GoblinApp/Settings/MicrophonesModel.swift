import CoreAudio
import GoblinCore
import GoblinEngines
import SwiftUI

/// The microphones macOS has right now, kept current by CoreAudio's own change notices rather than
/// a refresh when a view opens, and the ranking that chooses among them.
@MainActor
final class MicrophonesModel: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var defaultUID: String?
    @Published private(set) var ranking: MicrophoneRanking
    /// Called once for each microphone seen for the first time, after it's remembered below the line.
    var onNewMicrophone: (MicrophoneFacts) -> Void = { _ in }
    private let defaults: UserDefaults
    private let monitorSystem: Bool
    private weak var diagnostics: DiagnosticsModel?
    /// False until the first listing places the devices that were already here.
    private var saved: Bool
    private var lidClosed = false
    private var listing: Task<Void, Never>?
    // Off the main queue, so a blocked main thread never holds up a device change.
    private static let listenerQueue = DispatchQueue(label: "app.goblin.microphone-changes")

    init(devices: [InputDevice]? = nil, defaultUID: String? = nil, defaults: UserDefaults, diagnostics: DiagnosticsModel? = nil) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        monitorSystem = devices == nil
        let loaded = MicrophoneRanking.load(defaults: defaults)
        ranking = loaded ?? .migrating(defaults: defaults)
        saved = loaded != nil
        if let devices {
            self.devices = devices; self.defaultUID = defaultUID
            reconcile()
            return
        }
        // ponytail: listeners last for the process; the model is created once per launch.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, Self.listenerQueue) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        lidClosed = AudioInputDevices.lidClosed()
        refresh()
    }

    /// Lists off the main thread: CoreAudio can stall while devices change. A device arrives as a burst of
    /// notices, so they settle into one listing.
    func refresh() {
        guard monitorSystem else { return }
        listing?.cancel()
        listing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let listed = await Task.detached(priority: .userInitiated) { Result { try AudioInputDevices.snapshot() } }.value
            guard !Task.isCancelled else { return }
            switch listed {
            case .success(let snapshot):
                if snapshot.devices != devices { devices = snapshot.devices }
                if snapshot.defaultUID != defaultUID { defaultUID = snapshot.defaultUID }
                reconcile()
            case .failure:
                diagnostics?.developmentLog.record(.deviceEnumerationFailed, area: .microphone, severity: .error)
            }
        }
    }

    /// The lid sends no CoreAudio notice, so the once-a-second poll asks.
    func checkLid() {
        guard monitorSystem else { return }
        let closed = AudioInputDevices.lidClosed()
        guard closed != lidClosed else { return }
        lidClosed = closed
        refresh()
    }

    var choice: MicrophoneChoice? { ranking.resolve(connected: devices.map(\.facts), systemDefault: defaultUID) }

    /// The device a recording would open right now.
    var inUse: InputDevice? { choice.flatMap { choice in devices.first { $0.uid == choice.uid } } }

    /// The highest-ranked microphone passed over for the one in use, and whether only the lid stopped it.
    var passedOver: (entry: MicrophoneRanking.Entry, lidClosed: Bool)? {
        guard let choice, let entry = ranking.entries.prefix(choice.position).first(where: { !$0.isSystemDefault }) else { return nil }
        return (entry, devices.contains { $0.uid == entry.uid && $0.silencedByLid })
    }

    func device(_ uid: String) -> InputDevice? { devices.first { $0.uid == uid } }

    func pick(_ uid: String) { change { $0.pick(uid, connected: devices.map(\.facts)) } }
    func move(fromOffsets source: IndexSet, toOffset destination: Int) { change { $0.move(fromOffsets: source, toOffset: destination) } }
    func forget(_ uid: String) { change { $0.forget(uid) } }

    private func reconcile() {
        var fresh: [MicrophoneFacts] = []
        change { ranking in
            let connected = devices.map(\.facts)
            if !saved { ranking.seed(connected, laptopFirst: MicrophoneRanking.laptopFirst(defaults: defaults)) }
            fresh = ranking.reconcile(connected)
            for device in fresh { ranking.remember(device) }
        }
        // macOS often switches to a mic as it connects. While gob.lin follows macOS that mic is already in use,
        // and no answer to the question could change it.
        let followed = choice.flatMap { $0.viaSystemDefault ? $0.uid : nil }
        fresh.filter { $0.uid != followed }.forEach(onNewMicrophone)
    }

    private func change(_ edit: (inout MicrophoneRanking) -> Void) {
        var updated = ranking
        edit(&updated)
        guard updated != ranking || !saved else { return }
        ranking = updated
        ranking.save(defaults: defaults)
        saved = true
    }
}
