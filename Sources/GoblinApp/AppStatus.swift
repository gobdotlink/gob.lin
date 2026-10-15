import GoblinCore
import SwiftUI

/// The one-line status shown with a light in the popover header and the Settings sidebar.
struct AppStatus {
    var light: LightState
    var title: String
    var detail: String
}

extension AppModel {
    var status: AppStatus {
        let model = speechModels.selectedModel.name
        if diagnostics.hasWarning {
            let count = diagnostics.warnings.count
            return AppStatus(light: .waiting, title: "Needs attention", detail: count == 1 ? "1 thing" : "\(count) things")
        }
        switch speechModels.state {
        case .ready: return AppStatus(light: .ready, title: "Ready", detail: "\(model) · on this Mac")
        case .unloaded: return AppStatus(light: .ready, title: "Ready", detail: "\(model) wakes when you talk")
        case .preparing, .unloading, .cancelling: return AppStatus(light: .waiting, title: "Getting ready", detail: "Preparing \(model)")
        case .failed: return AppStatus(light: .problem, title: "Model failed", detail: "Retry in Model settings")
        case .notPrepared, .cancelled, .stopped: return AppStatus(light: .off, title: "Not loaded", detail: "Prepare it in Model settings")
        }
    }

    /// Opens the window that fixes a warning. Nil when there is nothing to open.
    func fix(for failure: DiagnosticFailure) -> (title: String, action: () -> Void)? {
        switch failure.area {
        case .microphone, .permissions: ("Open Setup…", { [weak self] in self?.permissions.showOnboarding() })
        case .model: ("Open Model Settings", { [weak self] in self?.openSettings(.model) })
        case .rewrite: ("Open Cleanup Settings", { [weak self] in self?.openSettings(.cleanup) })
        case .hotkeys: ("Open General Settings", { [weak self] in self?.openSettings(.general) })
        case .history: ("Open History", { [weak self] in self?.openHistory() })
        case .dictionary: ("Open Dictionary", { [weak self] in self?.openSettings(.dictionary) })
        case .secureInput, .trimming, .insertion, .settings, .application: nil
        }
    }

    func openSettings(_ section: SettingsSection) {
        settingsSelection = section
        openWindow?("settings")
    }

    func openHistory(_ scope: HistoryScope = .all, focus: UUID? = nil) {
        historyScope = scope
        historyFocus = focus
        openWindow?("history")
    }
}

extension DiagnosticFailure {
    /// A short title and one plain sentence for the popover's problem modules.
    var plainWords: (title: String, detail: String) {
        switch self {
        case .microphonePermissionMissing: ("Microphone access is off", "I can't hear you until you allow it.")
        case .microphoneUnavailable: ("No microphone", "Plug one in, or pick another in Audio settings.")
        case .microphoneCaptureFailed: ("The microphone stopped", "Check the device, then try again.")
        case .requiredPermissionsMissing, .insertionPermissionMissing: ("Accessibility is off", "I can't type for you or notice the talk key until you allow it.")
        case .hotkeyUnavailable: ("The talk key isn't working", "Check it in General settings.")
        case .secureInputEnabled: ("Secure Input is on", "An app is guarding a password field, so modifier-only talk keys wait until it's done.")
        case .modelUnavailable, .modelLoadFailed: ("The speech model isn't ready", "Retry it in Model settings.")
        case .transcriptionFailed: ("A dictation couldn't be transcribed", "The recording is in History.")
        case .silenceTrimmingFailed: ("A recording couldn't be prepared", "It's in History if you want to retry.")
        case .rewriteConfiguration: ("Cleanup isn't set up", "Finish it in Cleanup settings, or turn it off.")
        case .rewriteTimeout, .rewriteTransport, .rewriteHTTPStatus, .rewriteInvalidResponse:
            ("Cleanup didn't work", "Your words went in as you said them.")
        case .insertionTargetChanged, .insertionClipboardBusy, .insertionNotAcknowledged, .insertionFailed:
            ("A dictation didn't go in", "It's waiting in History.")
        case .noTranscriptAvailable: ("Nothing to paste yet", "Dictate something first.")
        case .historyUnavailable, .historySaveFailed, .historyOperationFailed: ("History had a problem", "Open History to see what happened.")
        case .dictionaryUnavailable: ("The dictionary couldn't load", "Your entries are untouched.")
        case .settingsSaveFailed: ("A setting didn't save", "Try again in Settings.")
        case .applicationFailed: ("Something went wrong", "Diagnostics has the details.")
        }
    }
}
