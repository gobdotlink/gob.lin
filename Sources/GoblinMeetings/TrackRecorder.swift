import AVFoundation
import Foundation

public enum MeetingTrack: String, Codable, Sendable, CaseIterable {
    case microphone, system
    public var fileStem: String { rawValue }
}

/// A stretch of one track that probably holds speech, cut at a pause.
public struct SpeechChunk: Sendable {
    public let track: MeetingTrack
    public let startSample: Int
    public let samples: [Float]
    public var startSeconds: Double { Double(startSample) / MeetingAudio.sampleRate }
}

public enum MeetingAudio {
    public static let sampleRate: Double = 16_000
}

public struct TrackStats: Codable, Sendable {
    public var samples = 0
    public var firstHostOffset: Double?
    public var lastHostOffset: Double?
    public var gaps: [Gap] = []
    public var paddedLeadSeconds = 0.0
    public struct Gap: Codable, Sendable { public let atSeconds: Double; public let seconds: Double }
    /// Positive when the track's device clock ran fast against the host clock.
    public var driftMilliseconds: Double? {
        guard let lastHostOffset else { return nil }
        return (Double(samples) / MeetingAudio.sampleRate - lastHostOffset) * 1_000
    }
}

/// Resamples one source to 16 kHz mono, writes it to a WAV that stays readable after a crash
/// (only the header sizes go stale), keeps a sample → host-time index, pads gaps with silence
/// so both tracks share a timeline, and cuts speech chunks for live transcription.
final class TrackRecorder: @unchecked Sendable {
    let track: MeetingTrack
    let audioURL: URL
    private let queue: DispatchQueue
    private let file: FileHandle
    private let timing: FileHandle
    private let sessionStart: Double
    private let onChunk: @Sendable (SpeechChunk) -> Void
    /// Hears every sample written, silence included, on the session's clock.
    private let onSamples: (@Sendable ([Float]) -> Void)?
    private let onEvent: @Sendable (String) -> Void
    private let onWriteFailure: @Sendable (any Error) -> Void
    private let lock = NSLock()
    private var levelValue: Float = -100

    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MeetingAudio.sampleRate,
                                             channels: 1, interleaved: false)!
    private var stats = TrackStats()
    private var expectedHost: Double?
    private var lastTimingHost = -10.0
    private var finished = false
    /// A write failed (a full disk): the track keeps what reached the file and takes no more.
    private var writeFailed = false

    private var chunker: SpeechChunker

    /// `onWriteFailure` hears the first write that fails; the recording should stop then.
    init(track: MeetingTrack, directory: URL, sessionStart: Double,
         onChunk: @escaping @Sendable (SpeechChunk) -> Void, onSamples: (@Sendable ([Float]) -> Void)? = nil,
         onEvent: @escaping @Sendable (String) -> Void,
         onWriteFailure: @escaping @Sendable (any Error) -> Void = { _ in }) throws {
        self.track = track
        self.sessionStart = sessionStart
        self.onChunk = onChunk
        self.onSamples = onSamples
        self.onEvent = onEvent
        self.onWriteFailure = onWriteFailure
        chunker = SpeechChunker(track: track)
        queue = DispatchQueue(label: "gob.lin.meetings.track.\(track.rawValue)", qos: .userInitiated)
        audioURL = directory.appendingPathComponent("\(track.fileStem).wav")
        let timingURL = directory.appendingPathComponent("\(track.fileStem).timing.jsonl")
        FileManager.default.createFile(atPath: audioURL.path, contents: WAVFile.header(dataBytes: 0))
        FileManager.default.createFile(atPath: timingURL.path, contents: nil)
        file = try FileHandle(forWritingTo: audioURL)
        try file.seekToEnd()
        timing = try FileHandle(forWritingTo: timingURL)
    }

    /// dBFS over the most recent buffer, for meters.
    var level: Float { lock.withLock { levelValue } }

    func append(_ buffer: CapturedBuffer) {
        queue.async { [self] in process(buffer) }
    }

    func finish() -> TrackStats {
        queue.sync {
            guard !finished else { return stats }
            finished = true
            for chunk in chunker.finish() { onChunk(chunk) }
            try? file.synchronize()
            // After a failed write the header may not fit either; the reader trusts the file's length over it.
            try? WAVFile.patchHeader(file, dataBytes: stats.samples * 2)
            try? file.close()
            try? timing.close()
            return stats
        }
    }

    private func process(_ buffer: CapturedBuffer) {
        guard !finished, !writeFailed, buffer.sampleRate > 0, !buffer.samples.isEmpty else { return }
        let offset = buffer.hostSeconds - sessionStart
        if stats.firstHostOffset == nil {
            stats.firstHostOffset = offset
            if offset > 0 {
                stats.paddedLeadSeconds = offset
                writeSilence(seconds: offset)
            }
        } else if let expectedHost {
            let gap = buffer.hostSeconds - expectedHost
            // The whole gap, however long, so the track stays on the session's clock; it's written a second at a time.
            // Short ones count only where the capture reopened; elsewhere they're clock jitter.
            if gap > 0.25 || (buffer.resumes && gap > 0.001) {
                stats.gaps.append(.init(atSeconds: Double(stats.samples) / MeetingAudio.sampleRate, seconds: gap))
                onEvent("\(track.rawValue): \(String(format: "%.2f", gap)) s gap filled with silence")
                writeSilence(seconds: gap)
            }
        }
        expectedHost = buffer.hostSeconds + Double(buffer.samples.count) / buffer.sampleRate
        stats.lastHostOffset = expectedHost.map { $0 - sessionStart }
        if buffer.hostSeconds - lastTimingHost >= 1 {
            lastTimingHost = buffer.hostSeconds
            let line = "{\"sample\":\(stats.samples),\"host\":\(String(format: "%.6f", offset))}\n"
            guard append(Data(line.utf8), to: timing) else { return }
        }
        let samples = resample(buffer.samples, rate: buffer.sampleRate)
        write(samples)
        guard !writeFailed else { return }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let db = 10 * log10(max(sum / Float(max(samples.count, 1)), 1e-10))
        lock.withLock { levelValue = db }
    }

    private func writeSilence(seconds: Double) {
        var remaining = Int(seconds * MeetingAudio.sampleRate)
        let block = [Float](repeating: 0, count: 16_000)
        while remaining > 0, !writeFailed {
            let count = min(remaining, block.count)
            write(Array(block[0..<count]))
            remaining -= count
        }
    }

    private func write(_ samples: [Float]) {
        // A clipping mic and resampler overshoot both exceed ±1; the speech engine rejects those.
        let clamped = samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
        let pcm = clamped.map { Int16($0 * 32_767) }
        guard pcm.withUnsafeBytes({ append(Data($0), to: file) }) else { return }
        for chunk in chunker.feed(clamped) { onChunk(chunk) }
        onSamples?(clamped)
        stats.samples += clamped.count
    }

    /// Writes to one of the track's files. A full disk throws here, rather than raising and ending the app; the first
    /// failure stops the track and is reported once.
    private func append(_ data: Data, to handle: FileHandle) -> Bool {
        guard !writeFailed else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            writeFailed = true
            onWriteFailure(error)
            return false
        }
    }

    private func resample(_ samples: [Float], rate: Double) -> [Float] {
        if rate == MeetingAudio.sampleRate { return samples }
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        if converter == nil || converterRate != rate {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterRate = rate
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * MeetingAudio.sampleRate / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

enum WAVFile {
    static func header(dataBytes: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        return data
    }

    static func patchHeader(_ file: FileHandle, dataBytes: Int) throws {
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header(dataBytes: dataBytes))
        try file.seekToEnd()
    }

    /// Reads a 16 kHz mono 16-bit WAV written by `TrackRecorder`, trusting the file length over the
    /// header so a recording cut short by a crash still loads.
    static func readSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 44 else { return [] }
        let count = (data.count - 44) / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 44)
            for index in 0..<count {
                let value = Int16(littleEndian: base.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[index] = Float(value) / 32_768
            }
        }
        return samples
    }
}
