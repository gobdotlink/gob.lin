import Foundation
import GoblinEngines

@MainActor
final class ActiveDictation {
    let session: DictationSession
    let lease: SpeechModelLease
    let readiness: Task<any PCMSpeechEngine, Error>
    let live: LiveTranscriber
    let events: AsyncStream<AudioCaptureEvent>
    let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    var captureID: UUID?
    var startTask: Task<Void, Never>?
    var stopTask: Task<CapturedAudio, Error>?
    var cancelTask: Task<Void, Never>?
    var frameTask: Task<Void, Never>?
    var textTask: Task<Void, Never>?
    var audio: CapturedAudio?
    var failure: AudioCaptureFailure?
    var stopping = false
    var enqueued = false
    var countedForProcessing = false

    init(session: DictationSession, lease: SpeechModelLease, readiness: Task<any PCMSpeechEngine, Error>) {
        self.session = session
        self.lease = lease
        self.readiness = readiness
        live = LiveTranscriber(engine: readiness)
        // A stalled UI must not retain a growing recording; gaps trigger original-file recovery.
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }
}
