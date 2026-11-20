import Foundation

/// Cuts one track's 16 kHz samples into speech chunks at pauses, as they arrive. A 20 ms frame is speech when its
/// energy is well over an adaptive noise floor. A chunk ends after 500 ms of quiet once it's 1 s long, or 200 ms once
/// it's 4 s, and at 10 s it's cut at the quietest frame of its last 3 s. Silence before speech is dropped down to a
/// lead-in of at least 300 ms. The live transcript and the echo-cancelled microphone after the call both cut with it,
/// so the speech model hears the same kind of chunks either way.
struct SpeechChunker {
    let track: MeetingTrack
    private var frameRemainder: [Float] = []
    private var pending: [Float] = []
    private var pendingStart = 0
    private var silentFrames = 0
    private var pendingHasSpeech = false
    private var noiseFloor: Float = -60
    private var ready: [SpeechChunk] = []
    private static let frame = 320  // 20 ms

    init(track: MeetingTrack) { self.track = track }

    /// A whole track's chunks, as feeding it in any number of pieces and then finishing would cut it. It is fed a second
    /// at a time, so the frames waiting to be read never hold a second copy of an hour's audio.
    static func chunks(of samples: [Float], track: MeetingTrack) -> [SpeechChunk] {
        var chunker = SpeechChunker(track: track)
        var chunks: [SpeechChunk] = []
        var start = 0
        while start < samples.count {
            let end = min(start + Int(MeetingAudio.sampleRate), samples.count)
            chunks += chunker.feed(Array(samples[start..<end]))
            start = end
        }
        return chunks + chunker.finish()
    }

    /// Takes the samples that follow the ones fed before and returns the chunks they completed.
    mutating func feed(_ samples: [Float]) -> [SpeechChunk] {
        frameRemainder.append(contentsOf: samples)
        var index = 0
        while frameRemainder.count - index >= Self.frame {
            let frame = frameRemainder[index..<index + Self.frame]
            index += Self.frame
            var sum: Float = 0
            for sample in frame { sum += sample * sample }
            let db = 10 * log10(max(sum / Float(Self.frame), 1e-10))
            if db < noiseFloor { noiseFloor = db } else { noiseFloor += 0.001 * (db - noiseFloor) }
            let speech = db > max(-52, noiseFloor + 12)
            pending.append(contentsOf: frame)
            if speech { pendingHasSpeech = true; silentFrames = 0 } else { silentFrames += 1 }
            considerCut()
        }
        frameRemainder.removeFirst(index)
        return takeReady()
    }

    /// The end of the track: speech still pending becomes the last chunk. Samples short of a whole frame are dropped.
    mutating func finish() -> [SpeechChunk] {
        frameRemainder.removeAll()
        if pendingHasSpeech, !pending.isEmpty { emit(count: pending.count, remainderHasSpeech: false) }
        return takeReady()
    }

    private mutating func takeReady() -> [SpeechChunk] {
        defer { ready.removeAll() }
        return ready
    }

    private mutating func considerCut() {
        let duration = Double(pending.count) / MeetingAudio.sampleRate
        if !pendingHasSpeech {
            // Keep 300 ms of lead-in so a chunk never clips the first syllable.
            if duration >= 2 { drop(keepingSeconds: 0.3) }
            return
        }
        if (silentFrames >= 25 && duration >= 1) || (silentFrames >= 10 && duration >= 4) {
            let trailing = max(0, silentFrames - 15) * Self.frame
            emit(count: pending.count - trailing, remainderHasSpeech: false)
        } else if duration >= 10 {
            // Hard cut at the quietest 20 ms frame in the last 3 s.
            let searchStart = max(0, pending.count - 3 * 16_000)
            var best = pending.count
            var bestEnergy = Float.greatestFiniteMagnitude
            var position = searchStart
            while position + Self.frame <= pending.count {
                var sum: Float = 0
                for sample in pending[position..<position + Self.frame] { sum += sample * sample }
                if sum < bestEnergy { bestEnergy = sum; best = position + Self.frame / 2 }
                position += Self.frame
            }
            emit(count: best, remainderHasSpeech: true)
        }
    }

    private mutating func drop(keepingSeconds seconds: Double) {
        let keep = Int(seconds * MeetingAudio.sampleRate)
        let removed = max(0, pending.count - keep)
        pending.removeFirst(removed)
        pendingStart += removed
    }

    private mutating func emit(count: Int, remainderHasSpeech: Bool) {
        let count = min(count, pending.count)
        guard count > 0 else { return }
        ready.append(SpeechChunk(track: track, startSample: pendingStart, samples: Array(pending[0..<count])))
        pending.removeFirst(count)
        pendingStart += count
        pendingHasSpeech = remainderHasSpeech
        silentFrames = 0
    }
}
