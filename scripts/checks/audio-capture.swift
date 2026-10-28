import AVFoundation
import Darwin
import Foundation
import GoblinCore
import os

private enum CaptureCheckError: Error, LocalizedError {
    case noNonzeroInput
    var errorDescription: String? { "The hardware supplied no meaningful nonzero audio." }
}

final class CaptureEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedPosition: Int64 = 0
    private var firstSession: UUID?
    private var ready = false
    private var frames = 0
    private var peak = 0.0
    private var sum = 0.0
    private var firstAfter: Double?
    private let start = ContinuousClock.now
    private var failure: AudioCaptureFailure.Kind?

    func record(_ event: AudioCaptureEvent) {
        lock.withLock {
            switch event {
            case .ready(let id, _):
                precondition(!ready); ready = true; firstSession = id
                let time = start.duration(to: .now).components
                firstAfter = Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15
            case .frame(let frame):
                precondition(ready && frame.sessionID == firstSession)
                precondition(frame.samplePosition == expectedPosition)
                precondition(!frame.samples.isEmpty && frame.samples.allSatisfy(\.isFinite))
                expectedPosition += Int64(frame.samples.count); frames += 1
                for sample in frame.samples { peak = max(peak, abs(Double(sample))); sum += Double(sample) * Double(sample) }
            case .failed(_, let error): failure = error.kind
            case .finished(let audio): precondition(audio.sampleCount == expectedPosition)
            case .level, .silence, .switched, .cancelled: break
            }
        }
    }

    func check(_ audio: CapturedAudio, requireNonzero: Bool = false) throws {
        let file = try AVAudioFile(forReading: audio.fileURL)
        try lock.withLock {
            precondition(file.length == expectedPosition && audio.sampleCount == expectedPosition)
            precondition(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
            precondition(audio.sampleCount > 0 && ready && failure == nil)
            if requireNonzero, peak <= 0.00001 { throw CaptureCheckError.noNonzeroInput }
        }
    }

    func report(label: String, audio: CapturedAudio? = nil) {
        lock.withLock {
            let rms = expectedPosition > 0 ? sqrt(sum / Double(expectedPosition)) : 0
            print("\(label): samples=\(expectedPosition) frames=\(frames) peak=\(peak) rms=\(rms) firstBufferMs=\(firstAfter ?? -1) preRoll=\(audio?.preRollSampleCount ?? 0) failure=\(failure?.rawValue ?? "none")")
            fflush(nil)
        }
    }
}

@main
struct AudioCaptureCheck {
    @MainActor static func main() async {
        if Bundle.main.bundleIdentifier == "app.goblin.dictation" {
            let log = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("native.log")
            let fd = open(log.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
            if fd >= 0 { dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd) }
        }
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Capture check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        if CommandLine.arguments.contains("--native") || Bundle.main.bundleIdentifier == "app.goblin.dictation" { try await native(); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-capture-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = AudioInputResolution(device: AudioInputDevice(id: 0, uid: "check", name: "Check input"))
        // Frequency gating must suppress cues without removing concurrent low-band speech or its timing.
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let count = Int(rate)
            let voice = (0..<count).map { Float(sin(2 * .pi * 320 * Double($0) / rate) * 0.2) }
            let mixed = (0..<count).map { voice[$0] + Float(sin(2 * .pi * 1760 * Double($0) / rate) * 0.15) }
            var filter = CaptureCueFilter(sampleRate: rate)
            let filtered = filter.apply(mixed, enabled: true)
            precondition(filtered.count == voice.count && filtered.allSatisfy(\.isFinite))
            func magnitude(_ frequency: Double) -> Double {
                let start = count / 2
                let real = (start..<count).reduce(0.0) { $0 + Double(filtered[$1]) * cos(2 * .pi * frequency * Double($1) / rate) }
                let imag = (start..<count).reduce(0.0) { $0 + Double(filtered[$1]) * sin(2 * .pi * frequency * Double($1) / rate) }
                return hypot(real, imag) * 2 / Double(count - start)
            }
            precondition(magnitude(1760) < 0.00001 && magnitude(320) > 0.18)
            let loud = filter.apply([Float](repeating: 0.99, count: 4096), enabled: true)
            precondition(loud.allSatisfy { $0.isFinite && abs($0) <= 1 })
            precondition(filter.apply(voice, enabled: false) == voice)
        }
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let processor = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
            let id = UUID(), evidence = CaptureEvidence()
            try processor.begin(sessionID: id, directory: directory, resolution: device, handler: evidence.record)
            // An awkward boundary puts real nonzero audio into the converter's final tail.
            let total = Int(rate / 10) + 77
            var offset = 0
            while offset < total {
                let count = min(1024, total - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<count {
                    buffer.floatChannelData![0][i] = Float(sin(Double(offset + i) * 0.1) * 0.25)
                    buffer.floatChannelData![1][i] = 0
                }
                processor.receive(buffer); offset += count
            }
            let audio = try await processor.finish(sessionID: id, cancel: false)!
            try evidence.check(audio, requireNonzero: true)
            precondition(abs(audio.sampleCount - Int64((Double(total) * 16_000 / rate).rounded(.up))) <= 1)
            evidence.report(label: "converter \(Int(rate))Hz stereo → mono", audio: audio)
            let data = try Data(contentsOf: audio.fileURL)
            precondition(data.count == 44 + Int(audio.sampleCount) * 4)
        }
        // A take outlives its microphone: a 48 kHz stereo device drops out, the take moves to a 24 kHz mono
        // one (a Bluetooth headset's call rate), and the timeline stays contiguous with the outage as silence.
        do {
            func feed(_ processor: CaptureProcessor, _ format: AVAudioFormat, seconds: Double) {
                var remaining = Int(format.sampleRate * seconds), phase = 0
                while remaining > 0 {
                    let count = min(1024, remaining)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = buffer.frameCapacity
                    for channel in 0..<Int(format.channelCount) {
                        for i in 0..<count { buffer.floatChannelData![channel][i] = Float(sin(Double(phase + i) * 0.05) * 0.25) }
                    }
                    processor.receive(buffer); remaining -= count; phase += count
                }
            }
            let wide = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let narrow = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
            let headset = AudioInputResolution(device: AudioInputDevice(id: 1, uid: "headset", name: "Headset", kind: .bluetooth), position: 1)
            let processor = try CaptureProcessor(format: wide, resolution: device, preview: { _ in }, onFailure: { _ in })
            let id = UUID(), evidence = CaptureEvidence()
            let switched = OSAllocatedUnfairLock(initialState: [String]())
            try processor.begin(sessionID: id, directory: directory, resolution: device) { event in
                if case .switched(_, let from, let to) = event { switched.withLock { $0.append("\(from.uid)→\(to.device.uid)") } }
                evidence.record(event)
            }
            feed(processor, wide, seconds: 0.5)
            processor.inputBroke()
            precondition(processor.inputBroken && processor.watchdogFailure() == nil, "A broken input mid-take must wait for a reroute, not fail")
            feed(processor, wide, seconds: 0.1) // late callbacks from the dead device are dropped
            try processor.rebind(format: narrow, resolution: headset)
            try await Task.sleep(for: .milliseconds(300))
            feed(processor, narrow, seconds: 0.5)
            precondition(processor.outageFor == .zero, "Audio arriving again ends the outage")
            let audio = try await processor.finish(sessionID: id, cancel: false)!
            try evidence.check(audio, requireNonzero: true)
            precondition(switched.withLock { $0 } == ["check→headset"])
            let gap = Int(audio.sampleCount) - 16_000
            precondition((3_000...6_000).contains(gap), "The outage must be kept as silence, got \(gap) samples")
            let samples = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!,
                                           frameCapacity: AVAudioFrameCount(audio.sampleCount))!
            try AVAudioFile(forReading: audio.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false).read(into: samples)
            let silence = UnsafeBufferPointer(start: samples.floatChannelData![0] + 8_100, count: gap - 200)
            precondition(silence.allSatisfy { $0 == 0 }, "The outage must read as silence")
            evidence.report(label: "rerouted take 48 kHz stereo → 24 kHz mono", audio: audio)

            // Stopping while the input is broken finishes with what arrived instead of failing.
            let stopped = try CaptureProcessor(format: wide, resolution: device, preview: { _ in }, onFailure: { _ in })
            let stoppedID = UUID(), stoppedEvidence = CaptureEvidence()
            try stopped.begin(sessionID: stoppedID, directory: directory, resolution: device, handler: stoppedEvidence.record)
            feed(stopped, wide, seconds: 0.25)
            stopped.inputBroke()
            let kept = try await stopped.finish(sessionID: stoppedID, cancel: false)!
            try stoppedEvidence.check(kept, requireNonzero: true)
            precondition(kept.sampleCount == 4_000)

            // Stopping after a switch, before the new input's first buffer, keeps what the old one gave.
            let early = try CaptureProcessor(format: wide, resolution: device, preview: { _ in }, onFailure: { _ in })
            let earlyID = UUID(), earlyEvidence = CaptureEvidence()
            try early.begin(sessionID: earlyID, directory: directory, resolution: device, handler: earlyEvidence.record)
            feed(early, wide, seconds: 0.25)
            early.inputBroke()
            try early.rebind(format: narrow, resolution: headset)
            try await Task.sleep(for: .milliseconds(200))
            await early.seal(atHostTime: mach_absolute_time())
            let earlyAudio = try await early.finish(sessionID: earlyID, cancel: false)!
            try earlyEvidence.check(earlyAudio, requireNonzero: true)
            precondition(earlyAudio.sampleCount == 4_000)

            // Two switches before audio returns count the outage from the last real buffer, and a device
            // that breaks on every reopen ends the take after three tries instead of looping.
            let flaky = try CaptureProcessor(format: wide, resolution: device, preview: { _ in }, onFailure: { _ in })
            let flakyID = UUID(), flakyEvidence = CaptureEvidence()
            try flaky.begin(sessionID: flakyID, directory: directory, resolution: device, handler: flakyEvidence.record)
            feed(flaky, wide, seconds: 0.25)
            flaky.inputBroke(); try flaky.rebind(format: narrow, resolution: headset)
            try await Task.sleep(for: .milliseconds(150))
            flaky.inputBroke(); try flaky.rebind(format: wide, resolution: device)
            try await Task.sleep(for: .milliseconds(150))
            feed(flaky, wide, seconds: 0.25)
            let twice = try await flaky.finish(sessionID: flakyID, cancel: false)!
            try flakyEvidence.check(twice, requireNonzero: true)
            precondition(twice.sampleCount - 8_000 >= 3_500, "Silence must cover both switches, got \(twice.sampleCount - 8_000)")
            let looping = try CaptureProcessor(format: wide, resolution: device, preview: { _ in }, onFailure: { _ in })
            let loopingID = UUID()
            try looping.begin(sessionID: loopingID, directory: directory, resolution: device, handler: { _ in })
            feed(looping, wide, seconds: 0.1)
            // The outage clock runs from the first break through failed reopens, so the 2 s limit holds.
            looping.inputBroke()
            try await Task.sleep(for: .milliseconds(60))
            try looping.rebind(format: narrow, resolution: headset)
            looping.inputBroke()
            precondition(looping.outageFor >= .milliseconds(60), "A failed reopen must not restart the outage clock")
            for _ in 0..<2 { try looping.rebind(format: narrow, resolution: headset); looping.inputBroke() }
            looping.inputBroke()
            do { try looping.rebind(format: narrow, resolution: headset); preconditionFailure("A fourth rebind without input must fail") }
            catch let failure as AudioCaptureFailure { precondition(failure.kind == .configurationChanged) }
            _ = try await looping.finish(sessionID: loopingID, cancel: true)
        }
        let file = try CaptureFile(sessionID: UUID(), directory: directory)
        try file.append([0.125, 0.25, -0.5])
        let whileWriting = try CaptureFile.recover(in: directory)
        precondition(whileWriting.isEmpty && FileManager.default.fileExists(atPath: file.partialURL.path))
        file.preserve()
        let brokenTail = try FileHandle(forWritingTo: file.partialURL)
        try brokenTail.seekToEnd()
        var uncheckpointedSample: Float = 0.75
        try withUnsafeBytes(of: &uncheckpointedSample) { try brokenTail.write(contentsOf: Data($0)) }
        try brokenTail.write(contentsOf: Data([1, 2])); try brokenTail.close()
        let recovered = try CaptureFile.recover(in: directory)
        precondition(recovered.count == 1)
        let recoveredFile = try AVAudioFile(forReading: recovered[0])
        precondition(recoveredFile.length == 4)
        let cancelled = try CaptureFile(sessionID: UUID(), directory: directory)
        try cancelled.append([1, 2, 3]); try cancelled.cancel()
        precondition(!FileManager.default.fileExists(atPath: cancelled.partialURL.path))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let processor = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let id = UUID(), evidence = CaptureEvidence()
        try processor.begin(sessionID: id, directory: directory, resolution: device, handler: evidence.record)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.2 }
        processor.receive(buffer); processor.interrupt(.configurationChanged)
        do { _ = try await processor.finish(sessionID: id, cancel: false); preconditionFailure("Device interruption must fail") }
        catch let error as AudioCaptureFailure {
            precondition(error.kind == .configurationChanged && error.recoveryURL != nil)
            let files = try CaptureFile.recover(in: directory)
            precondition(files.count == 1)
            let restored = try AVAudioFile(forReading: files[0])
            precondition(restored.length == 1600)
        }
        let warm = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let warmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9000)!
        warmBuffer.frameLength = 9000
        for i in 0..<9000 { warmBuffer.floatChannelData![0][i] = Float(i) / 10_000 }
        warm.receive(warmBuffer)
        let warmID = UUID(), warmEvidence = CaptureEvidence()
        try warm.begin(sessionID: warmID, directory: directory, resolution: device, handler: warmEvidence.record)
        let warmAudio = try await warm.finish(sessionID: warmID, cancel: false)!
        try warmEvidence.check(warmAudio)
        precondition(warmAudio.preRollSampleCount == 8000 && warmAudio.sampleCount == 8000)
        warm.resume()
        let nextID = UUID(), nextEvidence = CaptureEvidence()
        try warm.begin(sessionID: nextID, directory: directory, resolution: device, handler: nextEvidence.record)
        warm.receive(buffer)
        let nextAudio = try await warm.finish(sessionID: nextID, cancel: false)!
        try nextEvidence.check(nextAudio)
        precondition(nextAudio.preRollSampleCount == 0 && nextAudio.sampleCount == 1600)
        warm.resume()
        let discardID = UUID()
        try warm.begin(sessionID: discardID, directory: directory, resolution: device, handler: { _ in })
        warm.receive(buffer)
        let discarded = try await warm.finish(sessionID: discardID, cancel: true)
        precondition(discarded == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(discardID.uuidString + ".partial.wav").path))
        let overflow = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let overflowID = UUID()
        try overflow.begin(sessionID: overflowID, directory: directory, resolution: device, handler: { _ in })
        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_001)!
        oversized.frameLength = 32_001
        overflow.receive(oversized)
        do { _ = try await overflow.finish(sessionID: overflowID, cancel: false); preconditionFailure("Overload must fail explicitly") }
        catch let error as AudioCaptureFailure { precondition(error.kind == .bufferOverflow && error.recoveryURL != nil) }
        try await checkStopBoundary(directory: directory, device: device, format: format)
        let neverStarted = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let zeros = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        precondition(!zeros.silenceSnapshot().receivingInput)
        let zeroID = UUID(), zeroEvidence = CaptureEvidence()
        try zeros.begin(sessionID: zeroID, directory: directory, resolution: device, handler: zeroEvidence.record)
        let zeroBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        zeroBuffer.frameLength = 160
        for i in 0..<160 { zeroBuffer.floatChannelData![0][i] = 0 }
        let nearZero = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let nearZeroBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        nearZeroBuffer.frameLength = 160
        for i in 0..<160 { nearZeroBuffer.floatChannelData![0][i] = 0.0002 }
        let gated = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let gatedID = UUID(), gatedEvidence = CaptureEvidence()
        try gated.begin(sessionID: gatedID, directory: directory, resolution: device, handler: gatedEvidence.record)
        gated.receive(buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        for tick in 0..<53 {
            zeros.receive(zeroBuffer)
            nearZero.receive(nearZeroBuffer)
            gated.receive(zeroBuffer, time: AVAudioTime(sampleTime: 1600 + Int64(tick * 160), atRate: 16_000))
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(zeros.watchdogFailure() == nil, "Flowing digital silence must warn without ending capture")
        precondition(gated.watchdogFailure() == nil, "A continuous gated pause after valid input must not end capture")
        // Device evidence is authoritative once callbacks flow; sample-only pauses stay quiet.
        func warning(device: InputSilence? = nil, receiving: Bool = true, streak: TimeInterval? = nil, leading: TimeInterval? = nil, heard: Bool) -> InputSilence? {
            InputSilenceMonitor.cause(device: device, receivingInput: receiving, streak: streak, leading: leading, heardSound: heard)
        }
        precondition(warning(device: .muted, streak: 0.2, leading: 0.2, heard: false) == .muted)
        precondition(warning(device: .volumeAtZero, streak: 0.2, heard: true) == .volumeAtZero)
        precondition(warning(device: .muted, heard: true) == .muted, "Nonzero samples must not suppress a reported mute")
        precondition(warning(device: .volumeAtZero, heard: true) == .volumeAtZero)
        precondition(warning(device: .muted, receiving: false, heard: false) == nil)
        precondition(warning(device: .volumeAtZero, receiving: false, heard: true) == nil)
        precondition(warning(receiving: false, streak: 20, leading: 20, heard: false) == nil)
        precondition(warning(heard: true) == nil, "Restoring the device clears its warning")
        precondition(warning(streak: 4.9, leading: 4.9, heard: false) == nil)
        precondition(warning(streak: 5, leading: 5, heard: false) == .silent)
        precondition(warning(streak: 14.9, heard: true) == nil, "A thinking pause must not warn")
        precondition(warning(streak: 15, heard: true) == .silent)
        let zeroSnapshot = zeros.silenceSnapshot()
        precondition(zeroSnapshot.receivingInput && !zeroSnapshot.heardSound && (zeroSnapshot.leading ?? 0) >= 5)
        precondition(warning(streak: zeroSnapshot.streak, leading: zeroSnapshot.leading, heard: zeroSnapshot.heardSound) == .silent)
        let zeroAudio = try await zeros.finish(sessionID: zeroID, cancel: false)!
        try zeroEvidence.check(zeroAudio)
        let nearZeroSnapshot = nearZero.silenceSnapshot()
        precondition(nearZero.watchdogFailure() == nil)
        precondition(nearZeroSnapshot.receivingInput && nearZeroSnapshot.heardSound && nearZeroSnapshot.streak == nil)
        precondition(warning(device: .muted, streak: nearZeroSnapshot.streak, leading: nearZeroSnapshot.leading, heard: nearZeroSnapshot.heardSound) == .muted)
        precondition(warning(device: .volumeAtZero, streak: nearZeroSnapshot.streak, leading: nearZeroSnapshot.leading, heard: nearZeroSnapshot.heardSound) == .volumeAtZero)
        precondition(warning(streak: nearZeroSnapshot.streak, leading: nearZeroSnapshot.leading, heard: nearZeroSnapshot.heardSound) == nil,
                     "Quiet nonzero input alone must not infer mute")
        let gatedSnapshot = gated.silenceSnapshot()
        precondition(gatedSnapshot.heardSound && (gatedSnapshot.streak ?? 99) < 15)
        precondition(warning(streak: gatedSnapshot.streak, leading: gatedSnapshot.leading, heard: gatedSnapshot.heardSound) == nil,
                     "A gated pause after valid input must not warn either")
        gated.receive(buffer, time: AVAudioTime(sampleTime: 10_080, atRate: 16_000))
        precondition(gated.silenceSnapshot().streak == nil, "Returning sound clears the silence streak")
        let gatedAudio = try await gated.finish(sessionID: gatedID, cancel: false)!
        try gatedEvidence.check(gatedAudio, requireNonzero: true)
        precondition(gatedAudio.sampleCount == 11_680, "Later samples after the gated pause must remain captured")
        gated.resume()
        let beginReset = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        beginReset.receive(buffer)
        let beginResetID = UUID()
        try beginReset.begin(sessionID: beginResetID, directory: directory, resolution: device, handler: { _ in })
        // Reuse the no-callback wait to verify resume and begin do not inherit earlier nonzero input.
        for _ in 0..<53 {
            gated.receive(zeroBuffer); beginReset.receive(zeroBuffer)
            try await Task.sleep(for: .milliseconds(100))
        }
        for processor in [gated, beginReset] {
            let snapshot = processor.silenceSnapshot()
            precondition(snapshot.receivingInput && !snapshot.heardSound && (snapshot.leading ?? 0) >= 5)
            precondition(processor.watchdogFailure() == nil)
        }
        precondition(!nearZero.silenceSnapshot().receivingInput, "Stale callbacks must not support a device warning")
        _ = try await beginReset.finish(sessionID: beginResetID, cancel: true)
        precondition(neverStarted.watchdogFailure() == .noCallbacks)
        let badDirectory = directory.appendingPathComponent("regular-file")
        try Data().write(to: badDirectory)
        do { _ = try CaptureFile(sessionID: UUID(), directory: badDirectory); preconditionFailure("Non-directory storage must fail") }
        catch { }
        print("Capture checks passed: real converter tail and ordering, complete sample counts, incremental WAV recovery, cancellation deletion, retained audio on interruption, bounded pre-roll without session leakage, overflow, stop cutoff/last samples/deadline/clock/cancellation races, warning-only initial-zero/gated-pause/reset behavior, no-callback watchdogs, authoritative mute/zero-volume warnings with nonzero input, 5/15-second silence boundaries and recovery, invalid storage.")
    }

    @MainActor static func checkStopBoundary(directory: URL, device: AudioInputResolution, format: AVAudioFormat) async throws {
        let ticks = AVAudioTime.hostTime(forSeconds: 0.1)
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = value }
            return buffer
        }
        func make() throws -> (CaptureProcessor, UUID, UInt64) {
            let processor = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
            let id = UUID()
            try processor.begin(sessionID: id, directory: directory, resolution: device, handler: { _ in })
            return (processor, id, mach_absolute_time() - ticks * 4)
        }
        func time(_ host: UInt64, _ sample: Int64) -> AVAudioTime {
            AVAudioTime(hostTime: host, sampleTime: sample, atRate: 16_000)
        }
        func retained(_ processor: CaptureProcessor, _ id: UUID, _ kind: AudioCaptureFailure.Kind, _ samples: Int64) async throws {
            do { _ = try await processor.finish(sessionID: id, cancel: false); preconditionFailure("Uncertain stop must retain audio and fail") }
            catch let error as AudioCaptureFailure {
                precondition(error.kind == kind)
                let file = try AVAudioFile(forReading: error.recoveryURL!)
                precondition(file.length == samples)
            }
        }
        // A delayed callback contains the last pre-cutoff samples. Keep its whole straddling buffer.
        let (processor, id, base) = try make()
        processor.receive(buffer(0.25), time: time(base, 0))
        let cutoff = base + ticks + ticks / 2
        let sealing = Task { await processor.seal(atHostTime: cutoff) }
        try await Task.sleep(for: .milliseconds(5))
        processor.receive(buffer(0.75), time: time(base + ticks, 1600))
        await sealing.value
        processor.receive(buffer(-0.5), time: time(base + ticks * 2, 3200))
        let audio = try await processor.finish(sessionID: id, cancel: false)!
        let file = try AVAudioFile(forReading: audio.fileURL)
        let saved = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3200)!
        try file.read(into: saved)
        precondition(audio.sampleCount == 3200 && saved.frameLength == 3200)
        precondition(saved.floatChannelData![0][3199] == 0.75, "The last pre-stop samples must reach the durable file")
        // A cancelled deadline cannot poison a resumed session, including an already-covered cutoff.
        processor.resume()
        let nextID = UUID(), nextBase = mach_absolute_time() - ticks * 2
        try processor.begin(sessionID: nextID, directory: directory, resolution: device, handler: { _ in })
        processor.receive(buffer(0.25), time: time(nextBase, 0))
        try await Task.sleep(for: .milliseconds(130))
        await processor.seal(atHostTime: nextBase + ticks / 2)
        let nextAudio = try await processor.finish(sessionID: nextID, cancel: false)!
        precondition(nextAudio.sampleCount == 1600)

        let (timeout, timeoutID, timeoutBase) = try make()
        timeout.receive(buffer(0.25), time: time(timeoutBase, 0))
        let waitingSince = ContinuousClock.now
        await timeout.seal(atHostTime: timeoutBase + ticks * 2)
        let waited = waitingSince.duration(to: .now)
        precondition(waited >= .milliseconds(100) && waited < .milliseconds(250), "The source-derived deadline must be bounded")
        try await retained(timeout, timeoutID, .noCallbacks, 1600)

        // Invalid host/sample mapping must never certify a complete stop. All accepted audio stays recoverable.
        for mode in 0..<8 {
            let (invalid, invalidID, invalidBase) = try make()
            let timestamp: AVAudioTime?
            switch mode {
            case 0: timestamp = nil
            case 1: timestamp = AVAudioTime(sampleTime: 0, atRate: 16_000)
            case 2: timestamp = AVAudioTime(hostTime: invalidBase)
            case 3: timestamp = AVAudioTime(hostTime: invalidBase, sampleTime: 0, atRate: 48_000)
            case 4: timestamp = time(mach_absolute_time() + ticks, 0)
            case 5: timestamp = time(UInt64.max - 1, 0)
            default: timestamp = time(invalidBase, 0)
            }
            invalid.receive(buffer(0.25), time: timestamp)
            if mode >= 6 { invalid.receive(buffer(0.75), time: time(mode == 6 ? invalidBase - ticks : invalidBase + ticks * 2, 1600)) }
            await invalid.seal(atHostTime: invalidBase + ticks / 2)
            try await retained(invalid, invalidID, .noCallbacks, mode >= 6 ? 3200 : 1600)
        }
        for invalidCutoff in [UInt64(0), mach_absolute_time() + ticks] {
            let (invalid, invalidID, invalidBase) = try make()
            invalid.receive(buffer(0.25), time: time(invalidBase, 0))
            await invalid.seal(atHostTime: invalidCutoff)
            try await retained(invalid, invalidID, .noCallbacks, 1600)
        }
        // Cancellation before registration, during the wait, and concurrent with acknowledgement.
        for mode in 0..<7 {
            let (cancelled, cancelledID, cancelledBase) = try make()
            cancelled.receive(buffer(0.25), time: time(cancelledBase, 0))
            if mode == 0 { cancelled.pause() }
            let start = ContinuousClock.now
            let wait = Task { await cancelled.seal(atHostTime: cancelledBase + ticks + ticks / 2) }
            if mode == 6 { wait.cancel() }
            if mode != 0 { try await Task.sleep(for: .milliseconds(5)) }
            if mode == 2 { cancelled.receive(buffer(0.75), time: time(cancelledBase + ticks, 1600)) }
            if mode == 3 { wait.cancel() }
            else if mode == 4 { cancelled.interrupt(.configurationChanged) }
            else if mode == 5 { cancelled.interrupt(.storageFailed); cancelled.pause() }
            else if mode != 6 { cancelled.pause() }
            await wait.value
            precondition(start.duration(to: .now) < .milliseconds(100), "Cancellation and failure must resolve a pending cutoff immediately")
            if mode >= 3 { try await retained(cancelled, cancelledID, mode == 3 || mode == 6 ? .noCallbacks : mode == 4 ? .configurationChanged : .storageFailed, 1600) }
            else {
                let discarded = try await cancelled.finish(sessionID: cancelledID, cancel: true)
                precondition(discarded == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(cancelledID.uuidString + ".partial.wav").path))
            }
        }
        print("Stop boundary checks: delayed straddling tail saved, subsequent input rejected, cached coverage, stale deadline reset, bounded uncertainty with retained samples, invalid clocks, immediate cancel/failure and original error passed.")
    }

    @MainActor static func native() async throws {
        print("Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"); fflush(nil)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        let devices = try AudioInputDevices.list()
        let builtIn = devices.first { $0.name.localizedCaseInsensitiveContains("MacBook") || $0.name.localizedCaseInsensitiveContains("Built-in") }
        let external = devices.first { $0.name.localizedCaseInsensitiveContains("DJI") }
        let service = AudioCaptureService.shared
        let root = Bundle.main.bundleIdentifier == "app.goblin.dictation" ? Bundle.main.bundleURL.deletingLastPathComponent() : FileManager.default.temporaryDirectory.appendingPathComponent("goblin-native-capture-" + UUID().uuidString)
        let configURL = root.appendingPathComponent("native-config.json")
        let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Double] ?? [:]
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GOBLIN_CAPTURE_PROBE_DIRECTORY"] ?? root.appendingPathComponent("audio").path)
        let seconds = Double(ProcessInfo.processInfo.environment["GOBLIN_CAPTURE_PROBE_SECONDS"] ?? "3") ?? 3
        var verified: AudioInputDevice?
        for (label, uid) in [("built-in cold", builtIn?.uid ?? ""), ("selected external", external?.uid ?? ""), ("built-in restart", builtIn?.uid ?? ""), ("selected external restart", external?.uid ?? ""), ("missing UID fallback", "unavailable-probe-device")] {
            if label.hasPrefix("built-in") && builtIn == nil { print("Built-in: unavailable, not tested"); continue }
            if label.hasPrefix("selected external") && external == nil { print("Selected external: unavailable, not tested"); continue }
            let evidence = CaptureEvidence()
            do {
                let id = try await service.start(ranking: only(uid), directory: directory, onEvent: evidence.record)
                let actual = await service.inputResolution?.device
                // The ranking passes over a mic it can't use (a lid-silenced built-in one); that's no evidence for it.
                if !label.hasPrefix("missing"), actual?.uid != uid {
                    try? await service.cancel(sessionID: id)
                    print("Hardware scenario \(label) unmet: opened \(actual?.name ?? "nothing") instead"); fflush(nil)
                    continue
                }
                try await Task.sleep(for: .seconds(label.hasPrefix("built-in") ? max(seconds, 6) : seconds))
                let audio = try await service.stop(sessionID: id)
                evidence.report(label: "\(label) on \(actual?.name ?? "unknown")", audio: audio)
                try evidence.check(audio, requireNonzero: true)
                verified = actual
            } catch {
                evidence.report(label: label + " failed")
                print("Hardware scenario \(label) unmet: \(error.localizedDescription)"); fflush(nil)
                if let id = await service.activeSessionID { try? await service.cancel(sessionID: id) }
            }
        }
        guard let verified else { await service.shutdown(); throw CaptureCheckError.noNonzeroInput }
        let verifiedUID = verified.uid
        try await service.setWarmMicrophone(enabled: true, ranking: only(verifiedUID))
        try await Task.sleep(for: .seconds(1))
        // Warm mode never holds a Bluetooth mic open, so there is no pre-roll to expect.
        let bluetooth = verified.kind == .bluetooth
        let warmInput = await service.inputResolution
        if bluetooth { precondition(warmInput == nil, "Warm mode must not open a Bluetooth mic") }
        let evidence = CaptureEvidence()
        let id = try await service.start(ranking: only(verifiedUID), directory: directory, onEvent: evidence.record)
        // A cold Bluetooth mic can take over a second to switch into call mode and send its first audio.
        try await Task.sleep(for: .seconds(bluetooth ? 3 : 1))
        let audio = try await service.stop(sessionID: id)
        try evidence.check(audio, requireNonzero: true); precondition(bluetooth ? audio.preRollSampleCount == 0 : audio.preRollSampleCount > 0)
        evidence.report(label: bluetooth ? "verified Bluetooth device, not kept warm" : "verified device warm", audio: audio)
        try await service.setWarmMicrophone(enabled: false, ranking: MicrophoneRanking())
        let cancelledID = try await service.start(ranking: only(verifiedUID), directory: directory, onEvent: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        try await service.cancel(sessionID: cancelledID)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(cancelledID.uuidString + ".partial.wav").path))
        if let longSeconds = config["longSeconds"], longSeconds >= 1800 {
            print("Starting actual long capture: \(longSeconds) wall-clock seconds"); fflush(nil)
            let evidence = CaptureEvidence()
            let id = try await service.start(ranking: only(verifiedUID), directory: directory, onEvent: evidence.record)
            let start = ContinuousClock.now
            var elapsed = 0.0
            while elapsed < longSeconds {
                try await Task.sleep(for: .seconds(min(60, longSeconds - elapsed)))
                let duration = start.duration(to: .now).components
                elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                evidence.report(label: "long capture progress \(Int(elapsed))s")
            }
            let audio = try await service.stop(sessionID: id)
            try evidence.check(audio, requireNonzero: true)
            precondition(audio.duration >= longSeconds - 10)
            evidence.report(label: "actual long capture complete", audio: audio)
            print("Long capture wall-clock seconds: \(elapsed), durable WAV duration: \(audio.duration)")
        }
        await service.shutdown()
        print("Native capture complete; probe engine closed. Raw probe audio is private and may be deleted after inspection.")
    }
}

/// One device ahead of the system default, as a person ranking it first would have it.
private func only(_ uid: String) -> MicrophoneRanking {
    MicrophoneRanking(entries: uid.isEmpty ? [.systemDefault] : [.init(uid: uid, name: "Check device"), .systemDefault])
}
