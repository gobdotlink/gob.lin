import Darwin
import Foundation

/// Whether macOS lets gob.lin record other apps' audio (System Settings › Privacy & Security › Screen & System Audio
/// Recording › System Audio Recording Only). Without it a process tap delivers only silence, so a call records just
/// your side. macOS has no public way to ask, so this reads TCC's own preflight, the way Apple's process-tap sample
/// apps do, and says `unknown` when it can't.
public enum SystemAudioPermission: Sendable, Equatable {
    case allowed, denied, unknown

    public static var current: SystemAudioPermission {
        guard let symbol = TCC.symbol("TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: TCC.Preflight.self)(TCC.service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    /// False when TCC can't be asked at all, so `unknown` means "can't tell" rather than "not asked yet".
    public static var checkable: Bool { TCC.symbol("TCCAccessPreflight") != nil }

    /// Whether TCC's own request can be tried, for when a process tap won't start to raise macOS's prompt.
    public static var canRequest: Bool { TCC.symbol("TCCAccessRequest") != nil }

    /// Asks TCC directly. On a real Mac this shows nothing once the person has answered before.
    public static func request() async -> Bool {
        guard let symbol = TCC.symbol("TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: TCC.Request.self)
        return await withCheckedContinuation { continuation in
            request(TCC.service, nil) { granted in continuation.resume(returning: granted) }
        }
    }

    /// The System Settings pane that holds the switch.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? { handle.flatMap { dlsym($0, name) } }
}
