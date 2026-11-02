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
    let frames: AsyncStream<AudioCaptureFrame>
    let frameContinuation: AsyncStream<AudioCaptureFrame>.Continuation
    let levels: AsyncStream<Double>
    let levelContinuation: AsyncStream<Double>.Continuation
    let onEvent: @Sendable (AudioCaptureEvent) -> Void
    var captureID: UUID?
    var audioReduction: AudioReductionSession?
    var sounds: FeedbackSounds?
    var startTask: Task<Void, Never>?
    var stopTask: Task<CapturedAudio, Error>?
    /// Capture's close and the final transcript, started at key-up off the main actor; see `AppModel.finishDictation`.
    var captureStop: Task<CapturedAudio, Error>?
    var finalTranscript: Task<LiveEnding, Error>?
    var cancelTask: Task<Void, Never>?
    var frameTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var levelTask: Task<Void, Never>?
    var textTask: Task<Void, Never>?
    var audio: CapturedAudio?
    var failure: AudioCaptureFailure?
    var stopping = false
    var enqueued = false
    var countedForProcessing = false
    var captureMilliseconds = 0.0
    /// AI cleanup of the settled text, started at a pause while the user is still holding the talk key.
    var earlyCleanup: DraftCleanup?
    var earlyCleanupTask: Task<Void, Never>?
    /// AI cleanup of the audio received by key-up, started while capture closes.
    var releaseCleanup: Task<DraftCleanup?, Never>?

    init(session: DictationSession, lease: SpeechModelLease, readiness: Task<any PCMSpeechEngine, Error>) {
        self.session = session
        self.lease = lease
        self.readiness = readiness
        live = LiveTranscriber(engine: readiness, options: lease.options, previewAvailable: lease.livePreview)
        // Audio drains independently of the UI; only meter snapshots may be coalesced.
        (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (events, eventContinuation) = AsyncStream.makeStream()
        let control = eventContinuation, audio = frameContinuation, meter = levelContinuation
        onEvent = { event in
            switch event {
            case .frame(let frame): audio.yield(frame)
            case .level(_, let rms): meter.yield(rms)
            default:
                control.yield(event)
                switch event {
                case .finished, .failed, .cancelled:
                    control.finish(); audio.finish(); meter.finish()
                default: break
                }
            }
        }
    }

    func finishEvents() {
        eventContinuation.finish()
        frameContinuation.finish()
        levelContinuation.finish()
    }
}
