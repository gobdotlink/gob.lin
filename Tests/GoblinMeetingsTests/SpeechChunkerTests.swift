import Foundation
import Synchronization
import Testing
@testable import GoblinMeetings

/// 40 s of synthetic sound that reaches every cut the chunker makes: a faint seeded hiss, short bursts cut after half a
/// second of quiet, a long one cut after 200 ms, one with no pause in 13 s that needs the hard cut, a long silence
/// trimmed to its lead-in, and a burst still going when the track ends.
private let golden: [Float] = {
    let bursts: [(from: Double, through: Double, frequency: Double)] = [(0.5, 1.7, 220), (3.0, 3.4, 330), (3.9, 4.6, 330), (6.0, 11.5, 180),
                                                                         (13.0, 26.0, 260), (33.0, 33.8, 200), (37.5, 40.0, 300)]
    // Plain loops over one array, made once for both tests: a closure per sample is slow enough unoptimized to hold up
    // every other test on a small CI machine.
    var seed: UInt32 = 0x2545_F491
    var signal = [Float](repeating: 0, count: Int(40 * MeetingAudio.sampleRate))
    for index in signal.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        signal[index] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.0006
    }
    for burst in bursts {
        var index = max(0, Int(burst.from * MeetingAudio.sampleRate) - 1)
        while index < signal.count {
            let time = Double(index) / MeetingAudio.sampleRate
            if time > burst.through { break }
            if time >= burst.from {
                // A slow swell, so the 13 s burst has a quietest frame for the hard cut to find.
                let swell = 0.6 + 0.4 * sin(2 * .pi * 0.37 * time)
                signal[index] += Float(sin(2 * .pi * burst.frequency * time) * 0.3 * swell)
            }
            index += 1
        }
    }
    return signal
}()

/// Where the chunker cut `golden` before it moved out of TrackRecorder: (start sample, sample count).
private let goldenCuts = [(0, 32_000), (32_000, 27_200), (59_200, 19_200), (78_400, 108_800), (187_200, 148_000), (335_200, 84_000),
                          (500_800, 44_800), (572_800, 67_200)]

@Test func theRecordersChunkerCutsTheGoldenSignalWhereItAlwaysHas() throws {
    let directory = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let signal = golden
    let chunks = Mutex<[SpeechChunk]>([])
    let recorder = try TrackRecorder(track: .microphone, directory: directory, sessionStart: 0,
                                     onChunk: { chunk in chunks.withLock { $0.append(chunk) } }, onEvent: { _ in })
    // Uneven buffers, so frames straddle them.
    var position = 0, step = 1_000
    while position < signal.count {
        let end = min(position + step, signal.count)
        recorder.append(CapturedBuffer(samples: Array(signal[position..<end]), sampleRate: MeetingAudio.sampleRate,
                                       hostSeconds: Double(position) / MeetingAudio.sampleRate))
        position = end
        step = step == 1_000 ? 1_733 : 1_000
    }
    _ = recorder.finish()
    let cut = chunks.withLock { $0 }
    #expect(cut.map(\.startSample) == goldenCuts.map(\.0))
    #expect(cut.map(\.samples.count) == goldenCuts.map(\.1))
    for chunk in cut { #expect(chunk.samples == Array(signal[chunk.startSample..<chunk.startSample + chunk.samples.count])) }
}

@Test func theChunkerCutsAWholeTrackAsTheRecorderCutsItLive() {
    let signal = golden
    let cut = SpeechChunker.chunks(of: signal, track: .microphone)
    #expect(cut.map(\.startSample) == goldenCuts.map(\.0))
    #expect(cut.map(\.samples.count) == goldenCuts.map(\.1))
    #expect(cut.allSatisfy { $0.track == .microphone })
}
