import Foundation

public struct AudioCaptureFrame: Sendable {
    public let sessionID: UUID
    public let samplePosition: Int64
    public let samples: [Float]
}

public struct CapturedAudio: Sendable {
    public let sessionID: UUID
    public let fileURL: URL
    public let sampleCount: Int64
    public let preRollSampleCount: Int
    /// Where stopping went, for the development log.
    public var stopTiming: CaptureStopTiming?
    public var duration: TimeInterval { Double(sampleCount) / 16_000 }
}

/// Milliseconds spent closing a take: waiting for the input buffer that covers the stop, then finishing the file.
public struct CaptureStopTiming: Sendable {
    public let seal: Double
    public let file: Double
    /// The input device's buffer length.
    public let buffer: Double
}

public struct AudioCaptureFailure: Error, LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        case permissionMissing, deviceUnavailable, invalidFormat, startFailed, alreadyRecording, staleSession
        case noCallbacks, allZeroStream, configurationChanged, systemSleep, bufferOverflow, conversionFailed, storageFailed
    }
    public let kind: Kind
    public let recoveryURL: URL?

    public init(_ kind: Kind, recoveryURL: URL? = nil) { self.kind = kind; self.recoveryURL = recoveryURL }

    public var errorDescription: String? {
        switch kind {
        case .permissionMissing: "Allow microphone access before recording."
        case .deviceUnavailable: "No usable microphone is available."
        case .invalidFormat: "The microphone has no usable input stream."
        case .startFailed: "The microphone could not start."
        case .alreadyRecording: "A recording is already active; stop it before changing microphones."
        case .staleSession: "This recording is no longer active."
        case .noCallbacks: "Microphone audio delivery could not be confirmed. Captured audio is recoverable. Reconnect it and try again."
        case .allZeroStream: "The microphone is delivering only digital silence. Check its mute, microphone permission, and laptop lid."
        case .configurationChanged: "The microphone configuration changed. Audio captured before the change is recoverable."
        case .systemSleep: "Recording stopped because the computer slept. Audio captured before sleep is recoverable."
        case .bufferOverflow: "Audio processing could not keep up. The recording stopped to avoid hiding lost audio."
        case .conversionFailed: "Microphone audio could not be converted."
        case .storageFailed: "Audio could not be saved. Check free disk space and folder permissions."
        }
    }
}

/// Why no sound is reaching the app. The first two come from the device itself; the last is
/// inferred from the samples alone when the device does not report either condition.
public enum InputSilence: Sendable, Equatable {
    case muted, volumeAtZero, silent

    public var message: String {
        switch self {
        case .muted: "Your microphone is muted, so I can't hear you."
        case .volumeAtZero: "Your microphone volume is at zero, so I can't hear you."
        case .silent: "I'm not hearing anything. Is your microphone muted?"
        }
    }
}

/// Decides whether silence is worth a warning, without touching hardware.
/// Sound thresholds only: capture itself keeps running either way.
public enum InputSilenceMonitor {
    /// Before any sound has ever arrived, this much digital silence means something is wrong.
    public static let leadingSilence: TimeInterval = 5
    /// After sound has arrived, only a long unbroken silence warns: thinking pauses stay quiet.
    public static let trailingSilence: TimeInterval = 15

    /// `device` is what the hardware reports about itself; `streak` is how long the stream has
    /// currently been all-zero; `leading` applies that interval to this session.
    public static func cause(device: InputSilence?, receivingInput: Bool, streak: TimeInterval?, leading: TimeInterval?,
                             heardSound: Bool) -> InputSilence? {
        guard receivingInput else { return nil }
        // A silenced device can still deliver nonzero noise.
        if let device { return device }
        // shortcut: sample-only warnings require exact zeros until a noise floor is calibrated on hardware.
        if !heardSound, let leading, leading >= leadingSilence { return .silent }
        if heardSound, let streak, streak >= trailingSilence { return .silent }
        return nil
    }
}

public enum AudioCaptureEvent: Sendable {
    case ready(sessionID: UUID, device: AudioInputResolution)
    case frame(AudioCaptureFrame)
    case level(sessionID: UUID, rms: Double)
    /// Non-terminal: the current silence warning, cleared with nil when sound returns.
    case silence(sessionID: UUID, cause: InputSilence?)
    /// The take moved to another input, or reopened the same one, and carries on.
    case switched(sessionID: UUID, from: AudioInputDevice, to: AudioInputResolution)
    case finished(CapturedAudio)
    case failed(sessionID: UUID, failure: AudioCaptureFailure)
    case cancelled(sessionID: UUID)
}

public enum AudioPreviewEvent: Sendable {
    case input(device: AudioInputResolution, rms: Double)
    /// Non-terminal: the current silence warning, cleared with nil when sound returns.
    case silence(InputSilence?)
    case failed(AudioCaptureFailure)
}
