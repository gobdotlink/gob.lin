import FluidAudio
import Foundation
import GoblinEngines

/// Replays audio files through the same recorder, chunker and live transcriber as a real call,
/// faster than real time, so the pipeline can be tested without capture permissions. Writes a new
/// meeting folder under `root` (default `MeetingStorage.root`) and returns it; post-processing is separate.
/// `cancelsEchoLive` takes the call's sound out of the microphone before the live transcript, as a real call does.
/// A chunk the speech engine fails on throws `MeetingProcessingError.untranscribed` once the folder is written, so a
/// simulation never reports a transcript with speech missing.
public enum MeetingSimulator {
    public static func run(system systemURL: URL, microphone microphoneURL: URL?, echoGain: Float,
                           engine: any PCMSpeechEngine, recognition: RecognitionOptions = .init(language: "en"),
                           title: String, root: URL? = nil, cancelsEchoLive: Bool = false,
                           log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let converter = AudioConverter()
        let system = try converter.resampleAudioFile(systemURL)
        var microphone = try microphoneURL.map { try converter.resampleAudioFile($0) } ?? []
        let count = max(system.count, microphone.count)
        if microphone.count < count { microphone += [Float](repeating: 0, count: count - microphone.count) }
        if echoGain > 0, count > 640 {
            // The call leaking out of the speakers into the mic 40 ms later.
            for index in 640..<count where index - 640 < system.count { microphone[index] += echoGain * system[index - 640] }
        }
        let started = Date()
        let directory = try MeetingStorage.newDirectory(title: title, date: started, in: root ?? MeetingStorage.root)
        try await engine.prepare()
        let segmentsURL = directory.appendingPathComponent(MeetingStorage.segmentsFile)
        FileManager.default.createFile(atPath: segmentsURL.path, contents: nil)
        let segments = try FileHandle(forWritingTo: segmentsURL)
        let writeLock = NSLock()
        nonisolated(unsafe) var failed: [(seconds: Double, reason: String)] = []
        let transcriber = MeetingTranscriber(engine: engine, options: recognition, onSegment: { segment in
            writeLock.withLock { if let data = try? JSONEncoder().encode(segment) { try? segments.write(contentsOf: data + Data([0x0A])) } }
            log("live \(segment.track.rawValue) [\(String(format: "%.2f", segment.start))] (\(Int(segment.decodeMilliseconds)) ms) \(segment.text)")
        }, onError: log, onDeferred: { chunk, reason in
            guard case .failed(let message) = reason else { return }
            writeLock.withLock { failed.append((chunk.seconds, message)) }
        })
        let submit: @Sendable (SpeechChunk) -> Void = { transcriber.submit($0) }
        let echo = cancelsEchoLive ? LiveEchoCanceller(load: LiveEchoCanceller.localVQE, log: log, onChunk: submit) : nil
        let microphoneSamples: @Sendable ([Float]) -> Void = { echo?.microphone($0) }
        let systemSamples: @Sendable ([Float]) -> Void = { echo?.system($0) }
        let microphoneTrack = try TrackRecorder(track: .microphone, directory: directory, sessionStart: 0,
                                                onChunk: echo == nil ? submit : nil, onSamples: microphoneSamples, onEvent: log)
        let systemTrack = try TrackRecorder(track: .system, directory: directory, sessionStart: 0,
                                            onChunk: submit, onSamples: systemSamples, onEvent: log)
        let step = 1_600
        var position = 0
        while position < count {
            let end = min(position + step, count)
            let host = Double(position) / MeetingAudio.sampleRate
            systemTrack.append(CapturedBuffer(samples: position < system.count ? Array(system[position..<min(end, system.count)]) : [],
                                              sampleRate: MeetingAudio.sampleRate, hostSeconds: host))
            microphoneTrack.append(CapturedBuffer(samples: Array(microphone[position..<end]), sampleRate: MeetingAudio.sampleRate,
                                                  hostSeconds: host))
            position = end
        }
        let microphoneStats = microphoneTrack.finish()
        let systemStats = systemTrack.finish()
        await echo?.finish()
        await transcriber.finish()
        try? segments.close()
        var info = MeetingSessionInfo(title: title, source: "simulation", target: systemURL.lastPathComponent, startedAt: started)
        info.language = recognition.language
        info.endedAt = started.addingTimeInterval(Double(count) / MeetingAudio.sampleRate)
        info.microphone = microphoneStats
        info.system = systemStats
        try JSONEncoder.pretty.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
        if let first = writeLock.withLock({ failed.first }) {
            let seconds = writeLock.withLock { failed.reduce(0) { $0 + $1.seconds } }
            throw MeetingProcessingError.untranscribed(seconds: seconds, reason: first.reason)
        }
        return directory
    }
}
