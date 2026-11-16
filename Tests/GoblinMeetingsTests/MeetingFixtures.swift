import Foundation
import GoblinEngines
@testable import GoblinMeetings

/// Synthetic meeting folders and fakes; nothing here is a recording of a person.
enum Fixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-meetings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Words of `text` starting at `start`, one every `step` seconds, each lasting `step * 0.8`.
    static func words(_ text: String, at start: Double, step: Double = 0.3) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * step
            return TranscriptWord(text: String(word), start: begin, end: begin + step * 0.8)
        }
    }

    static func segment(_ track: MeetingTrack, _ text: String, at start: Double, step: Double = 0.3) -> TranscriptSegment {
        let words = words(text, at: start, step: step)
        return TranscriptSegment(track: track, start: words.first?.start ?? start, end: words.last?.end ?? start, text: text,
                                 words: words, decodeMilliseconds: 50)
    }

    static func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * MeetingAudio.sampleRate)) }

    /// A 16 kHz mono 16-bit WAV. `finished: false` leaves the header's sizes at zero, as a crash does.
    static func writeWAV(_ samples: [Float], to url: URL, finished: Bool = true) throws {
        var data = WAVFile.header(dataBytes: finished ? samples.count * 2 : 0)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    /// A meeting folder with session.json, segments.jsonl and a silent system track.
    @discardableResult
    static func meeting(in root: URL, name: String, title: String = "Weekly sync", source: String = "Zoom",
                        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000), seconds: Double = 10, ended: Bool = true,
                        segments: [TranscriptSegment] = []) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var info = MeetingSessionInfo(title: title, source: source, target: "Zoom (2 processes)", startedAt: startedAt)
        if ended { info.endedAt = startedAt.addingTimeInterval(seconds) }
        try JSONEncoder.pretty.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
        try writeSegments(segments, to: directory)
        try writeWAV(silence(seconds: seconds), to: directory.appendingPathComponent(MeetingStorage.audioFile(.system)))
        try writeWAV(silence(seconds: seconds), to: directory.appendingPathComponent(MeetingStorage.audioFile(.microphone)))
        return directory
    }

    static func writeSegments(_ segments: [TranscriptSegment], to directory: URL) throws {
        let lines = try segments.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: directory.appendingPathComponent(MeetingStorage.segmentsFile), atomically: true, encoding: .utf8)
    }

    /// Moves every file's modification date back, so the folder no longer looks like a live recording.
    static func age(_ directory: URL, by seconds: TimeInterval = 120) throws {
        let date = Date().addingTimeInterval(-seconds)
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.appendingPathComponent(file).path)
        }
    }

    /// Post-processing options that never touch a model or the dictation history.
    static func options(spans: [DiarizedSpan], calls: Counter = Counter(),
                        dictations: [ClosedRange<Double>] = []) -> MeetingPostProcessOptions {
        MeetingPostProcessOptions(preset: "offline", diarizer: { _, _ in
            calls.increment()
            return DiarizationResult(spans: spans)
        }, dictationSpans: { _ in dictations })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A speech engine that "recognises" every chunk as two numbered words spread over the chunk.
final class ScriptedEngine: PCMSpeechEngine, @unchecked Sendable {
    let identifier = "scripted"
    let maximumWindowSamples = 16_000 * 30
    private let lock = NSLock()
    private var calls = 0

    func prepare() async throws {}
    func unload() async {}

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(text: "")
    }

    func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        let index = lock.withLock { calls += 1; return calls }
        let seconds = Double(samples.count) / MeetingAudio.sampleRate
        let first = "alpha\(index)", second = "beta\(index)"
        return TranscriptionResult(text: "\(first) \(second)", tokens: [
            TranscriptionToken(text: "▁" + first, startSeconds: seconds * 0.2, endSeconds: seconds * 0.4, confidence: 1),
            TranscriptionToken(text: "▁" + second, startSeconds: seconds * 0.5, endSeconds: seconds * 0.7, confidence: 1),
        ])
    }
}
