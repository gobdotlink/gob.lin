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
    public var duration: TimeInterval { Double(sampleCount) / 16_000 }
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

public enum AudioCaptureEvent: Sendable {
    case ready(sessionID: UUID, device: AudioInputResolution)
    case frame(AudioCaptureFrame)
    case level(sessionID: UUID, rms: Double)
    case finished(CapturedAudio)
    case failed(sessionID: UUID, failure: AudioCaptureFailure)
    case cancelled(sessionID: UUID)
}

public enum AudioPreviewEvent: Sendable {
    case input(device: AudioInputResolution, rms: Double)
    case failed(AudioCaptureFailure)
}
