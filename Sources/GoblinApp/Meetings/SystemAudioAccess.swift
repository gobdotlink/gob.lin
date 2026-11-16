import AppKit
import Foundation
import GoblinMeetings

/// System Audio Recording (the TCC audio-capture service a process tap needs), for Settings and the setup sheet. It
/// reads `SystemAudioPermission`; when TCC can't be reached the status is unknown and nothing is blocked.
@MainActor final class SystemAudioAccess: ObservableObject {
    enum Status { case granted, denied, unknown }

    static let shared = SystemAudioAccess()

    @Published private(set) var status: Status = .unknown
    /// Previews and captures set this, since they can't ask TCC for the real answer.
    var override: Status? { didSet { refresh() } }

    /// False when TCC can't be asked at all, so an unknown status means "can't tell" rather than "not asked yet".
    var checkable: Bool { override != nil || SystemAudioPermission.checkable }

    private init() { refresh() }

    func refresh() {
        let next = override ?? {
            switch SystemAudioPermission.current {
            case .allowed: .granted
            case .denied: .denied
            case .unknown: .unknown
            }
        }()
        if next != status { status = next }
    }

    /// Shows macOS's own prompt, which only appears once a process tap starts running (asking TCC directly showed
    /// nothing on a real Mac). The tap runs for up to 20 s while the person answers, delivering nowhere; if access
    /// still isn't granted by then, or was turned down before, System Settings opens at the right pane.
    func request() async {
        refresh()
        guard status != .granted else { return }
        let tap = SystemAudioTap(target: .everything)
        let started = (try? tap.start(onEvent: { _ in }, handler: { _ in })) != nil
        if started {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                refresh()
                if status == .granted { break }
            }
            tap.stop()
        } else if SystemAudioPermission.canRequest {
            _ = await SystemAudioPermission.request()
            refresh()
        }
        if status != .granted { openSettings() }
    }

    func openSettings() { NSWorkspace.shared.open(SystemAudioPermission.settingsURL) }
}
