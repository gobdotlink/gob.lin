import AVFoundation
import Darwin
import Foundation

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
            case .level, .cancelled: break
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
        let device = AudioInputResolution(requestedUID: "", device: AudioInputDevice(id: 0, uid: "check", name: "Check input"))
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
        let neverStarted = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let zeros = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let zeroBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        zeroBuffer.frameLength = 160
        for i in 0..<160 { zeroBuffer.floatChannelData![0][i] = 0 }
        let gated = try CaptureProcessor(format: format, resolution: device, preview: { _ in }, onFailure: { _ in })
        let gatedID = UUID(), gatedEvidence = CaptureEvidence()
        try gated.begin(sessionID: gatedID, directory: directory, resolution: device, handler: gatedEvidence.record)
        gated.receive(buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        for tick in 0..<53 {
            zeros.receive(zeroBuffer)
            gated.receive(zeroBuffer, time: AVAudioTime(sampleTime: 1600 + Int64(tick * 160), atRate: 16_000))
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(zeros.watchdogFailure() == .allZeroStream)
        precondition(gated.watchdogFailure() == nil, "A continuous gated pause after valid input must not end capture")
        gated.receive(buffer, time: AVAudioTime(sampleTime: 10_080, atRate: 16_000))
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
        precondition(gated.watchdogFailure() == .allZeroStream && beginReset.watchdogFailure() == .allZeroStream)
        _ = try await beginReset.finish(sessionID: beginResetID, cancel: true)
        precondition(neverStarted.watchdogFailure() == .noCallbacks)
        let badDirectory = directory.appendingPathComponent("regular-file")
        try Data().write(to: badDirectory)
        do { _ = try CaptureFile(sessionID: UUID(), directory: badDirectory); preconditionFailure("Non-directory storage must fail") }
        catch { }
        print("Capture checks passed: real converter tail and ordering, complete sample counts, incremental WAV recovery, cancellation deletion, retained audio on interruption, bounded pre-roll without session leakage, overflow, initial-zero/gated-pause/reset/no-callback watchdogs, invalid storage.")
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
        var verifiedUID: String?
        for (label, uid) in [("built-in cold", builtIn?.uid ?? ""), ("selected external", external?.uid ?? ""), ("built-in restart", builtIn?.uid ?? ""), ("selected external restart", external?.uid ?? ""), ("missing UID fallback", "unavailable-probe-device")] {
            if label.hasPrefix("built-in") && builtIn == nil { print("Built-in: unavailable, not tested"); continue }
            if label.hasPrefix("selected external") && external == nil { print("Selected external: unavailable, not tested"); continue }
            let evidence = CaptureEvidence()
            do {
                let id = try service.start(uid: uid, directory: directory, onEvent: evidence.record)
                let actualUID = service.inputResolution?.device.uid
                try await Task.sleep(for: .seconds(label.hasPrefix("built-in") ? max(seconds, 6) : seconds))
                let audio = try await service.stop(sessionID: id)
                evidence.report(label: label, audio: audio)
                try evidence.check(audio, requireNonzero: true)
                verifiedUID = actualUID
            } catch {
                evidence.report(label: label + " failed")
                print("Hardware scenario \(label) unmet: \(error.localizedDescription)"); fflush(nil)
                if let id = service.activeSessionID { try? await service.cancel(sessionID: id) }
            }
        }
        guard let verifiedUID else { await service.shutdown(); throw CaptureCheckError.noNonzeroInput }
        try service.setWarmMicrophone(enabled: true, uid: verifiedUID)
        try await Task.sleep(for: .seconds(1))
        let evidence = CaptureEvidence()
        let id = try service.start(uid: verifiedUID, directory: directory, onEvent: evidence.record)
        try await Task.sleep(for: .seconds(1))
        let audio = try await service.stop(sessionID: id)
        try evidence.check(audio, requireNonzero: true); precondition(audio.preRollSampleCount > 0)
        evidence.report(label: "verified device warm", audio: audio)
        try service.setWarmMicrophone(enabled: false, uid: "")
        let cancelledID = try service.start(uid: verifiedUID, directory: directory, onEvent: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        try await service.cancel(sessionID: cancelledID)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(cancelledID.uuidString + ".partial.wav").path))
        if let longSeconds = config["longSeconds"], longSeconds >= 1800 {
            print("Starting actual long capture: \(longSeconds) wall-clock seconds"); fflush(nil)
            let evidence = CaptureEvidence()
            let id = try service.start(uid: verifiedUID, directory: directory, onEvent: evidence.record)
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
