// Capture follows Mac input devices; the iPhone app records through its own audio session.
#if os(macOS)
import AVFoundation
import Darwin
import Foundation
import Synchronization

// Audio callbacks only copy into a bounded ingress. Converter, ring, file and event handler belong to queue.
final class CaptureProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.goblin.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var pendingFrames = 0
    private var overflow = false
    private var lastCallback = ContinuousClock.now
    private var hasCallback = false
    private var hasNonzeroInput = false
    private var zeroSince: ContinuousClock.Instant?
    private var recordingSince: ContinuousClock.Instant?
    private var pendingFailure: AudioCaptureFailure.Kind?
    private var nextInputSample: AVAudioFramePosition?
    private var inputHostRange: (start: UInt64, end: UInt64)?
    private var hostTimesValid = true
    private var inputBufferDuration = 0.12
    /// The open device stopped mid-take; the service moves the take to another input.
    private var broken = false
    /// When the take last had input, kept through failed reopens and cleared only when audio arrives again.
    private var outageSince: ContinuousClock.Instant?
    /// Rebound to a new input that hasn't delivered yet; a stop now keeps what the old one gave.
    private var awaitingInput = false
    /// Rebinds since the last delivered buffer. A device that breaks again on every reopen ends the take
    /// instead of reopening forever while the take records nothing.
    private var rebindsWithoutInput = 0
    /// Set by a rebind: the first buffer from the new input is preceded by silence for the time between.
    private var gapSince: ContinuousClock.Instant?
    private var pendingStop: (id: UUID, cutoff: UInt64, deadline: DispatchTime,
                              reply: CheckedContinuation<Void, Never>, timer: DispatchSourceTimer)?
    /// The pending stop's cutoff, or 0, for the render thread to read without the lock; see `stopWaits(through:)`.
    private let waitingCutoff = Atomic<UInt64>(0)
    private var nativeRate: Double
    private var monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter
    private var inputCount: Int64 = 0
    private var outputCount: Int64 = 0
    private var ring = [Float]()
    private var file: CaptureFile?
    private var handler: (@Sendable (AudioCaptureEvent) -> Void)?
    private var resolution: AudioInputResolution
    private var ready = false
    private var firstBufferPending = false
    private var feedbackSessionID: UUID?
    private var feedback: FeedbackSounds?
    private var cueFilter: CaptureCueFilter
    private var preRollCount = 0
    private var failure: AudioCaptureFailure?
    private var failedFileURL: URL?
    private let preview: @Sendable (Double) -> Void
    private let onFailure: @Sendable (AudioCaptureFailure) -> Void

    init(format: AVAudioFormat, resolution: AudioInputResolution,
         preview: @escaping @Sendable (Double) -> Void,
         onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void) throws {
        nativeRate = format.sampleRate
        cueFilter = CaptureCueFilter(sampleRate: format.sampleRate)
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0, nativeRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: output) else { throw AudioCaptureFailure(.invalidFormat) }
        monoFormat = mono; outputFormat = output; self.converter = converter
        converter.primeMethod = .none
        self.resolution = resolution; self.preview = preview; self.onFailure = onFailure
    }

    func begin(sessionID: UUID, directory: URL, resolution: AudioInputResolution,
               feedback: FeedbackSounds? = nil,
               feedbackSessionID: UUID? = nil,
               handler: @escaping @Sendable (AudioCaptureEvent) -> Void) throws {
        lock.withLock { recordingSince = .now; hasNonzeroInput = false; zeroSince = nil; inputHostRange = nil; hostTimesValid = true }
        try queue.sync {
            guard file == nil else { throw AudioCaptureFailure(.alreadyRecording) }
            if let failure { throw failure }
            self.resolution = resolution
            do { file = try CaptureFile(sessionID: sessionID, directory: directory) }
            catch { throw AudioCaptureFailure(.storageFailed) }
            self.handler = handler; ready = false
            if let feedback { self.feedback = feedback }
            firstBufferPending = feedback != nil
            self.feedbackSessionID = feedbackSessionID ?? sessionID
            if feedbackSessionID == nil { feedback?.begin(sessionID: sessionID) }
            preRollCount = ring.count
            let preRoll = ring; ring.removeAll(keepingCapacity: true)
            if !preRoll.isEmpty { try deliver(preRoll) }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime? = nil) {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let now = ContinuousClock.now
        if let since = recordingSince, hasCallback, max(lastCallback, since).duration(to: now) > .seconds(5) {
            pendingFailure = .noCallbacks
            queue.async { self.fail(.noCallbacks) }
            closeIngressLocked()
            lock.unlock(); return
        }
        // ponytail: an outage is kept as at most 2 s of silence; longer reads as a pause, not lost time.
        let gap = gapSince.map { min(2, max(0, Self.seconds($0.duration(to: now)) - Double(buffer.frameLength) / nativeRate)) } ?? 0
        gapSince = nil
        if let time, time.isSampleTimeValid {
            if recordingSince != nil, let nextInputSample, time.sampleTime != nextInputSample {
                pendingFailure = .noCallbacks
                queue.async { self.fail(.noCallbacks) }
                closeIngressLocked()
                lock.unlock(); return
            }
            nextInputSample = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
        }
        lastCallback = now; hasCallback = true; awaitingInput = false; rebindsWithoutInput = 0; outageSince = nil
        let frames = Int(buffer.frameLength)
        // Stop instead of silently dropping input or allowing memory to grow with recording duration.
        guard pendingFrames + frames <= Int(nativeRate * 2) else {
            overflow = true
            queue.async { self.fail(.bufferOverflow) }
            closeIngressLocked()
            lock.unlock(); return
        }
        pendingFrames += frames
        var mono = [Float](repeating: 0, count: frames)
        var sums = [Double](repeating: 0, count: Int(buffer.format.channelCount))
        var nonzero = false
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frames {
                let value = channels[buffer.format.isInterleaved ? 0 : channel][frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)]
                guard value.isFinite else { continue }
                mono[frame] += value / Float(buffer.format.channelCount)
                sums[channel] += Double(value) * Double(value)
                if value != 0 { nonzero = true }
            }
        }
        if nonzero { hasNonzeroInput = true; zeroSince = nil } else if zeroSince == nil { zeroSince = now }
        let bufferSeconds = Double(frames) / nativeRate
        // A stop takes a partial batch; the next stop's deadline still allows a whole one.
        if pendingStop == nil { inputBufferDuration = bufferSeconds }
        let durationTicks = AVAudioTime.hostTime(forSeconds: bufferSeconds)
        let sampleTicks = max(1, AVAudioTime.hostTime(forSeconds: 1 / nativeRate))
        if let time, time.isHostTimeValid, time.isSampleTimeValid, time.sampleRate == nativeRate, time.hostTime > 0 {
            let (end, overflow) = time.hostTime.addingReportingOverflow(durationTicks)
            let now = mach_absolute_time()
            if overflow || time.hostTime > now || (end > now && end - now > sampleTicks) {
                hostTimesValid = false
            } else {
                if let previous = inputHostRange {
                    let gap = time.hostTime >= previous.end ? time.hostTime - previous.end : previous.end - time.hostTime
                    if time.hostTime <= previous.start || gap > sampleTicks { hostTimesValid = false }
                }
                inputHostRange = (time.hostTime, end)
            }
        } else { hostTimesValid = false }
        let rms = sqrt((sums.max() ?? 0) / Double(frames))
        let copiedSamples = mono
        let capturedAt = time?.isHostTimeValid == true ? time!.hostTime : mach_absolute_time()
        queue.async {
            defer { self.lock.withLock { self.pendingFrames -= frames } }
            guard self.failure == nil else { return }
            self.preview(rms)
            do {
                if gap > 0 { try self.deliver([Float](repeating: 0, count: Int(gap * 16_000))) }
                let protected = self.feedback?.protectsInput(at: capturedAt, duration: durationTicks) ?? false
                try self.convert(self.feedback == nil ? copiedSamples : self.cueFilter.apply(copiedSamples, enabled: protected))
                if self.firstBufferPending, self.file != nil, let id = self.feedbackSessionID {
                    self.firstBufferPending = false
                    self.feedback?.firstBuffer(sessionID: id)
                }
            }
            catch { self.fail((error as? AudioCaptureFailure)?.kind ?? .conversionFailed) }
        }
        if let pendingStop {
            if !hostTimesValid || DispatchTime.now() >= pendingStop.deadline {
                queue.async { self.fail(.noCallbacks) }
                closeIngressLocked()
            } else if let range = inputHostRange, range.end >= pendingStop.cutoff {
                // Publish the whole straddling buffer before acknowledging the cutoff.
                closeIngressLocked()
            }
        }
        lock.unlock()
    }

    /// The last input buffer's length, in seconds.
    var bufferDuration: Double { lock.withLock { inputBufferDuration } }

    func seal(atHostTime cutoff: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                lock.withLock {
                    guard accepting else { reply.resume(); return }
                    // The new input's first buffer can be a second away; the take ends with what it has.
                    if awaitingInput { closeIngressLocked(); reply.resume(); return }
                    guard pendingStop == nil else {
                        queue.async { self.fail(.staleSession) }
                        closeIngressLocked(); reply.resume(); return
                    }
                    guard hostTimesValid, cutoff > 0, cutoff <= mach_absolute_time() else {
                        queue.async { self.fail(.noCallbacks) }
                        closeIngressLocked(); reply.resume(); return
                    }
                    if let range = inputHostRange, range.end >= cutoff {
                        closeIngressLocked(); reply.resume(); return
                    }
                    let id = UUID()
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                    // Allow one observed buffer plus delivery margin, with a 120 ms ceiling.
                    let deadline = DispatchTime.now() + min(0.12, inputBufferDuration * 1.2)
                    timer.schedule(deadline: deadline)
                    timer.setEventHandler { [weak self] in
                        guard let self else { return }
                        self.lock.withLock {
                            guard self.pendingStop?.id == id else { return }
                            self.queue.async { self.fail(.noCallbacks) }
                            self.closeIngressLocked()
                        }
                    }
                    pendingStop = (id, cutoff, deadline, reply, timer)
                    waitingCutoff.store(cutoff, ordering: .releasing)
                    timer.resume()
                }
            }
        } onCancel: { self.interrupt(.noCallbacks) }
    }

    /// For the render thread, after each cycle: whether a stop is waiting for input that `end` covers. The input unit then
    /// hands over its partial batch, so a stop waits for at most one device cycle instead of the rest of a ~100 ms batch.
    /// Lock-free and allocation-free.
    func stopWaits(through end: UInt64) -> Bool {
        let cutoff = waitingCutoff.load(ordering: .acquiring)
        return cutoff != 0 && end >= cutoff
    }

    private func closeIngressLocked() {
        accepting = false
        waitingCutoff.store(0, ordering: .releasing)
        if let pendingStop {
            self.pendingStop = nil
            pendingStop.timer.cancel()
            pendingStop.reply.resume()
        }
    }

    /// A point-in-time read of the zero-stream tracking, for the silence warning.
    /// The streak counts only while callbacks are actually flowing: a stream that
    /// stopped delivering is the no-callback watchdog's problem, not a mute warning.
    func silenceSnapshot() -> (receivingInput: Bool, streak: TimeInterval?, leading: TimeInterval?, heardSound: Bool) {
        lock.withLock {
            let now = ContinuousClock.now
            func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
                let duration = start.duration(to: now).components
                return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            }
            guard accepting, hasCallback, lastCallback.duration(to: now) <= .seconds(1) else {
                return (false, nil, nil, hasNonzeroInput)
            }
            guard let zeroSince else { return (true, nil, nil, hasNonzeroInput) }
            let leading: TimeInterval?
            if hasNonzeroInput { leading = nil }
            else if let recordingSince { leading = seconds(since: max(zeroSince, recordingSince)) }
            else { leading = seconds(since: zeroSince) }
            return (true, seconds(since: zeroSince), leading, hasNonzeroInput)
        }
    }

    func watchdogFailure() -> AudioCaptureFailure.Kind? {
        lock.withLock {
            let now = ContinuousClock.now
            if let pendingFailure { return pendingFailure }
            if overflow { return .bufferOverflow }
            if lastCallback.duration(to: now) > (hasCallback ? .seconds(5) : .seconds(10)) { return .noCallbacks }
            return nil
        }
    }

    func pause() {
        lock.withLock {
            closeIngressLocked()
            if let since = recordingSince, hasCallback, max(lastCallback, since).duration(to: .now) > .seconds(5) {
                pendingFailure = .noCallbacks
                queue.async { self.fail(.noCallbacks) }
            }
        }
    }

    func resume() {
        queue.sync { converter.reset(); inputCount = 0; outputCount = 0; ring.removeAll(keepingCapacity: true) }
        lock.withLock { closeIngressLocked(); accepting = true; broken = false; gapSince = nil; outageSince = nil; awaitingInput = false; rebindsWithoutInput = 0; overflow = false; lastCallback = .now; hasCallback = false; hasNonzeroInput = false; zeroSince = nil; recordingSince = nil; pendingFailure = nil; nextInputSample = nil; inputHostRange = nil; hostTimesValid = true; inputBufferDuration = 0.12 }
    }

    private func fail(_ kind: AudioCaptureFailure.Kind, recoveryURL: URL? = nil) {
        // Call only on queue, or schedule via interrupt. Keep the first failure and its recoverable file.
        guard failure == nil else { return }
        failure = AudioCaptureFailure(kind, recoveryURL: recoveryURL ?? file?.partialURL)
        lock.withLock { closeIngressLocked() }
        failedFileURL = failure?.recoveryURL
        file?.preserve()
        if let file { handler?(.failed(sessionID: file.sessionID, failure: failure!)) }
        onFailure(failure!)
    }

    func abortStart(_ kind: AudioCaptureFailure.Kind) -> AudioCaptureFailure {
        pause()
        return queue.sync { fail(kind); return failure! }
    }

    func interrupt(_ kind: AudioCaptureFailure.Kind) {
        lock.withLock { queue.async { self.fail(kind) }; closeIngressLocked() }
    }

    /// The device stopped rendering or changed under the stream. A take stops taking input and waits for
    /// the service to move it to another one; a stop meanwhile finishes with what arrived. Outside a take
    /// this ends the stream as before.
    func inputBroke() {
        lock.withLock {
            if recordingSince != nil {
                if outageSince == nil { outageSince = .now }
                broken = true
            } else { queue.async { self.fail(.configurationChanged) } }
            closeIngressLocked()
        }
    }

    var inputBroken: Bool { lock.withLock { broken } }
    /// How long a take has gone without input since its mic first broke, failed reopens included.
    var outageFor: Duration { lock.withLock { outageSince.map { $0.duration(to: .now) } ?? .zero } }

    /// Moves a take to another input, or the same one in a new format. What the old input delivered is
    /// converted and kept; the take continues at the same sample position.
    func rebind(format: AVAudioFormat, resolution: AudioInputResolution) throws {
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0, format.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: outputFormat) else { throw AudioCaptureFailure(.invalidFormat) }
        converter.primeMethod = .none
        guard lock.withLock({ rebindsWithoutInput < 3 }) else { throw AudioCaptureFailure(.configurationChanged) }
        // Safe without the lock only because the service closed the old unit and starts the new one after
        // this returns: no render thread reads the converter or rate meanwhile.
        try queue.sync {
            guard let file, failure == nil else { throw AudioCaptureFailure(.staleSession) }
            try drainConverter()
            let previous = self.resolution.device
            self.converter = converter; monoFormat = mono; nativeRate = format.sampleRate
            cueFilter = CaptureCueFilter(sampleRate: format.sampleRate)
            inputCount = 0; outputCount = 0
            self.resolution = resolution
            handler?(.switched(sessionID: file.sessionID, from: previous, to: resolution))
        }
        lock.withLock {
            // A stop that arrived meanwhile already finished the take with what it had.
            guard recordingSince != nil else { return }
            // Counted from the last real buffer, even across several rebinds.
            gapSince = gapSince ?? lastCallback
            lastCallback = .now; nextInputSample = nil; inputHostRange = nil; hostTimesValid = true
            broken = false; awaitingInput = true; rebindsWithoutInput += 1; accepting = true
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func finish(sessionID: UUID, cancel: Bool) async throws -> CapturedAudio? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if pendingStop != nil && !cancel { queue.async { self.fail(.noCallbacks) } }
                closeIngressLocked(); recordingSince = nil
                queue.async {
                    guard let file = self.file, file.sessionID == sessionID else {
                        continuation.resume(throwing: AudioCaptureFailure(.staleSession)); return
                    }
                    defer { self.file = nil; self.handler = nil; self.firstBufferPending = false; self.ring.removeAll(keepingCapacity: true) }
                    do {
                        if cancel {
                            try file.cancel()
                            continuation.resume(returning: nil)
                        } else {
                            if let failure = self.failure { throw failure }
                            try self.drainConverter()
                            if let failure = self.failure { throw failure }
                            let result = try file.finish(preRoll: self.preRollCount)
                            continuation.resume(returning: result)
                        }
                    } catch {
                        if self.failure == nil {
                            self.fail((error as? AudioCaptureFailure)?.kind ?? .storageFailed, recoveryURL: (error as? AudioCaptureFailure)?.recoveryURL)
                        }
                        file.preserve()
                        continuation.resume(throwing: self.failure ?? AudioCaptureFailure(.storageFailed, recoveryURL: file.partialURL))
                    }
                }
            }
        }
    }

    func notify(_ event: AudioCaptureEvent, handler: (@Sendable (AudioCaptureEvent) -> Void)?) async {
        await withCheckedContinuation { continuation in
            queue.async { handler?(event); continuation.resume() }
        }
    }

    func discardFailedFile(sessionID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if let url = self.failedFileURL { try FileManager.default.removeItem(at: url) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func convert(_ samples: [Float]) throws {
        guard let input = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = input.floatChannelData?[0] else { throw AudioCaptureFailure(.conversionFailed) }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: samples.count) }
        inputCount += Int64(samples.count)
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / nativeRate) + 256)
        let source = ConverterSource(input)
        for _ in 0..<16 {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                source.supply(state)
            }
            guard status != .error, error == nil else { throw AudioCaptureFailure(.conversionFailed) }
            if output.frameLength > 0 {
                outputCount += Int64(output.frameLength)
                try deliver(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))))
            }
            if status == .inputRanDry || status == .endOfStream { return }
        }
        throw AudioCaptureFailure(.conversionFailed)
    }

    private func drainConverter() throws {
        let expected = Int64((Double(inputCount) * 16_000 / nativeRate).rounded(.up))
        for _ in 0..<16 {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            guard status != .error, error == nil else { throw AudioCaptureFailure(.conversionFailed) }
            let count = min(Int(output.frameLength), max(0, Int(expected - outputCount)))
            if count > 0 {
                outputCount += Int64(count)
                try deliver(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count)))
            }
            if status == .endOfStream {
                guard abs(expected - outputCount) <= 1 else { throw AudioCaptureFailure(.conversionFailed) }
                return
            }
        }
        throw AudioCaptureFailure(.conversionFailed)
    }

    private func deliver(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let file else {
            ring.append(contentsOf: samples)
            if ring.count > 8_000 { ring.removeFirst(ring.count - 8_000) }
            return
        }
        let position = file.sampleCount
        do { try file.append(samples) }
        catch { fail(.storageFailed); throw AudioCaptureFailure(.storageFailed, recoveryURL: file.partialURL) }
        if !ready { ready = true; handler?(.ready(sessionID: file.sessionID, device: resolution)) }
        handler?(.frame(AudioCaptureFrame(sessionID: file.sessionID, samplePosition: position, samples: samples)))
        let rms = sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        handler?(.level(sessionID: file.sessionID, rms: rms))
    }
}

// AVAudioConverter invokes its input block synchronously on the processing queue.
private final class ConverterSource: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private var supplied = false
    init(_ input: AVAudioPCMBuffer) { self.input = input }
    func supply(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied { state.pointee = .noDataNow; return nil }
        supplied = true; state.pointee = .haveData; return input
    }
}
#endif
