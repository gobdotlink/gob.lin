import Foundation

public enum DiagnosticArea: String, CaseIterable, Sendable {
    case microphone, permissions, hotkeys, secureInput, model, trimming, rewrite, insertion, history, dictionary, settings, application
    public var title: String {
        switch self {
        case .secureInput: "Secure Input"
        default: rawValue.capitalized
        }
    }
}

/// Only typed, static messages enter diagnostics; never pass an error's localizedDescription here.
public enum DiagnosticFailure: Equatable, Sendable {
    case microphonePermissionMissing, microphoneUnavailable, microphoneCaptureFailed
    case requiredPermissionsMissing, hotkeyUnavailable, secureInputEnabled
    case modelUnavailable, modelLoadFailed, transcriptionFailed, silenceTrimmingFailed
    case rewriteConfiguration, rewriteTimeout, rewriteTransport, rewriteHTTPStatus(Int), rewriteInvalidResponse
    case insertionPermissionMissing, insertionTargetChanged, insertionClipboardBusy, insertionNotAcknowledged, insertionFailed, noTranscriptAvailable
    case historyUnavailable, historySaveFailed, historyOperationFailed, dictionaryUnavailable, settingsSaveFailed, applicationFailed

    public var area: DiagnosticArea {
        switch self {
        case .microphonePermissionMissing, .microphoneUnavailable, .microphoneCaptureFailed: .microphone
        case .requiredPermissionsMissing: .permissions
        case .hotkeyUnavailable: .hotkeys
        case .secureInputEnabled: .secureInput
        case .modelUnavailable, .modelLoadFailed, .transcriptionFailed: .model
        case .silenceTrimmingFailed: .trimming
        case .rewriteConfiguration, .rewriteTimeout, .rewriteTransport, .rewriteHTTPStatus, .rewriteInvalidResponse: .rewrite
        case .insertionPermissionMissing, .insertionTargetChanged, .insertionClipboardBusy, .insertionNotAcknowledged, .insertionFailed, .noTranscriptAvailable: .insertion
        case .historyUnavailable, .historySaveFailed, .historyOperationFailed: .history
        case .dictionaryUnavailable: .dictionary
        case .settingsSaveFailed: .settings
        case .applicationFailed: .application
        }
    }

    public var message: String {
        switch self {
        case .microphonePermissionMissing: "Microphone access is missing. Complete microphone setup in Permissions & onboarding."
        case .microphoneUnavailable: "No microphone is available. Connect a microphone and try again."
        case .microphoneCaptureFailed: "Microphone recording failed. Check your audio device and try again."
        case .requiredPermissionsMissing: "Accessibility access is missing. Complete Permissions & onboarding."
        case .hotkeyUnavailable: "The dictation shortcut is unavailable. Check shortcut settings and permissions."
        case .secureInputEnabled: "Secure Input is enabled. Modifier-only shortcuts are paused, and protected fields cannot receive dictation."
        case .modelUnavailable: "Speech engine selection is pending the benchmark. Dictation is not available yet."
        case .modelLoadFailed: "The speech model could not load. Check engine setup and try again."
        case .transcriptionFailed: "Speech recognition failed. Your dictation could not be transcribed."
        case .silenceTrimmingFailed: "Silence trimming failed. The audio could not be prepared for recognition."
        case .rewriteConfiguration: "polish failed — pasted raw. AI cleanup configuration is incomplete or invalid."
        case .rewriteTimeout: "polish failed — pasted raw. AI cleanup exceeded its four-second deadline."
        case .rewriteTransport: "polish failed — pasted raw. The cleanup provider could not be reached."
        case .rewriteHTTPStatus(let status): "polish failed — pasted raw. The provider returned HTTP \((100...599).contains(status) ? String(status) : "error")."
        case .rewriteInvalidResponse: "polish failed — pasted raw. The provider returned no usable text."
        case .insertionPermissionMissing: "Dictation could not be inserted. Allow Accessibility access and try again."
        case .insertionTargetChanged: "Dictation was not inserted because the target application changed. Copy it from History."
        case .insertionClipboardBusy: "Dictation could not be inserted because the clipboard changed. Copy it from History."
        case .insertionNotAcknowledged: "The target did not confirm reading the dictation clipboard. Check the target before retrying."
        case .insertionFailed: "Dictation could not be inserted. Your text remains available in History."
        case .noTranscriptAvailable: "No transcript is available to paste yet."
        case .historyUnavailable: "History is unavailable. Existing records have been left untouched."
        case .historySaveFailed: "History could not save this dictation. Keep or copy its pending text before quitting."
        case .historyOperationFailed: "History could not complete this operation. Check its visible error before trying again."
        case .dictionaryUnavailable: "The dictionary could not be loaded or saved. Existing entries have been left untouched."
        case .settingsSaveFailed: "Settings could not be saved. Review the setting and try again."
        case .applicationFailed: "The operation failed. Review diagnostics and try again."
        }
    }

    public static func rewrite(_ failure: RewriteFailure) -> Self {
        switch failure {
        case .configuration: .rewriteConfiguration
        case .timeout: .rewriteTimeout
        case .transport: .rewriteTransport
        case .httpStatus(let status): .rewriteHTTPStatus(status)
        case .invalidResponse: .rewriteInvalidResponse
        }
    }
}

public enum DiagnosticPermissionStatus: String, Sendable {
    case notRequested = "not requested"
    case granted, denied, restricted, unknown
}

public enum DiagnosticEngineStatus: String, Sendable {
    case awaitingSelection = "awaiting benchmark selection"
    case loading, ready, unavailable
}

public struct DiagnosticEnvironment: Equatable, Sendable {
    public var microphonePermission: DiagnosticPermissionStatus
    public var accessibilityPermission: DiagnosticPermissionStatus
    public var inputMonitoringPermission: DiagnosticPermissionStatus
    public var microphoneNames: [String]
    public var defaultMicrophoneName: String?
    public var secureInput: Bool
    public var engineStatus: DiagnosticEngineStatus

    public init(microphonePermission: DiagnosticPermissionStatus = .unknown,
                accessibilityPermission: DiagnosticPermissionStatus = .unknown,
                inputMonitoringPermission: DiagnosticPermissionStatus = .unknown,
                microphoneNames: [String] = [], defaultMicrophoneName: String? = nil,
                secureInput: Bool = false, engineStatus: DiagnosticEngineStatus = .awaitingSelection) {
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.inputMonitoringPermission = inputMonitoringPermission
        self.microphoneNames = microphoneNames
        self.defaultMicrophoneName = defaultMicrophoneName
        self.secureInput = secureInput
        self.engineStatus = engineStatus
    }
}

public struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let failure: DiagnosticFailure
    public init(failure: DiagnosticFailure, date: Date = Date(), id: UUID = UUID()) {
        self.failure = failure
        self.date = date
        self.id = id
    }
}

public enum DiagnosticsReport {
    public static let maximumEvents = 50

    public static func timingLines(_ timings: DictationTimings) -> [String] {
        ["Capture: " + milliseconds(timings.captureMilliseconds),
         "Silence trimming: " + milliseconds(timings.trimMilliseconds),
         "ASR: " + milliseconds(timings.asrMilliseconds),
         "Rewrite: " + milliseconds(timings.rewriteMilliseconds),
         "Insert: " + milliseconds(timings.insertionMilliseconds)]
    }

    public static func render(environment: DiagnosticEnvironment, activeFailures: [DiagnosticFailure],
                              events: [DiagnosticEvent], timings: DictationTimings?, includeDeviceNames: Bool = false) -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "other"
        #endif
        var lines = ["gob.lin diagnostics", "App: \(GoblinMetadata.version)",
                     "OS: \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(architecture))",
                     "Microphone permission: \(environment.microphonePermission.rawValue)",
                     "Accessibility permission: \(environment.accessibilityPermission.rawValue)",
                     "Input Monitoring permission (not required): \(environment.inputMonitoringPermission.rawValue)",
                     "Secure Input: \(environment.secureInput ? "enabled" : "disabled")",
                     "Speech engine: \(environment.engineStatus.rawValue)",
                     "Microphones available: \(environment.microphoneNames.count)"]
        if includeDeviceNames {
            lines += environment.microphoneNames.map { "Microphone: " + safeDeviceName($0) }
            if let name = environment.defaultMicrophoneName { lines.append("Default microphone: " + safeDeviceName(name)) }
        } else { lines.append("Device names: omitted") }
        lines += ["", "Active warnings:"]
        lines += activeFailures.isEmpty ? ["None"] : activeFailures.map { "[\($0.area.title)] \($0.message)" }
        lines += ["", "Latest dictation timings:"]
        lines += timings.map(timingLines) ?? ["No dictation timings recorded"]
        lines += ["", "Recent errors (latest \(maximumEvents), oldest first):"]
        let recent = Array(events.suffix(maximumEvents))
        if recent.isEmpty { lines.append("None") }
        let formatter = ISO8601DateFormatter()
        lines += recent.map { "\(formatter.string(from: $0.date)) [\($0.failure.area.title)] \($0.failure.message)" }
        return lines.joined(separator: "\n")
    }

    private static func milliseconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "unavailable" }
        return String(format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func safeDeviceName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120).map(Character.init))
    }
}
