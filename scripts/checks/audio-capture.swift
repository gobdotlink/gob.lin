import AVFoundation
import Foundation

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
        lock.withLock {
            precondition(file.length == expectedPosition && audio.sampleCount == expectedPosition)
            precondition(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
            precondition(audio.sampleCount > 0 && ready && failure == nil)
            if requireNonzero { precondition(peak > 0.00001, "The hardware supplied no meaningful nonzero audio") }
        }
    }

    func report(label: String, audio: CapturedAudio? = nil) {
        lock.withLock {
            let rms = expectedPosition > 0 ? sqrt(sum / Double(expectedPosition)) : 0
            print("\(label): samples=\(expectedPosition) frames=\(frames) peak=\(peak) rms=\(rms) firstBufferMs=\(firstAfter ?? -1) preRoll=\(audio?.preRollSampleCount ?? 0) failure=\(failure?.rawValue ?? "none")")
        }
    }
}

@main
struct AudioCaptureCheck {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--native") { try await native(); return }
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
        try file.append([0.125, 0.25, -0.5]); file.preserve()
        let brokenTail = try FileHandle(forWritingTo: file.partialURL)
        try brokenTail.seekToEnd(); try brokenTail.write(contentsOf: Data([1, 2])); try brokenTail.close()
        let recovered = try CaptureFile.recover(in: directory)
        precondition(recovered.count == 1)
        let recoveredFile = try AVAudioFile(forReading: recovered[0])
        precondition(recoveredFile.length == 3)
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
        print("Capture checks passed: real converter tail and ordering, complete sample counts, incremental WAV recovery, cancellation deletion, retained audio on interruption.")
    }

    @MainActor static func native() async throws {
        print("Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureFailure(.permissionMissing) }
        let devices = try AudioInputDevices.list()
        let builtIn = devices.first { $0.name.localizedCaseInsensitiveContains("MacBook") || $0.name.localizedCaseInsensitiveContains("Built-in") }
        let external = devices.first { $0.name.localizedCaseInsensitiveContains("DJI") }
        let service = AudioCaptureService.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GOBLIN_CAPTURE_PROBE_DIRECTORY"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("goblin-native-capture-" + UUID().uuidString).path)
        let seconds = Double(ProcessInfo.processInfo.environment["GOBLIN_CAPTURE_PROBE_SECONDS"] ?? "3") ?? 3
        for (label, uid) in [("built-in cold", builtIn?.uid ?? ""), ("selected external", external?.uid ?? ""), ("built-in restart", builtIn?.uid ?? ""), ("missing UID fallback", "unavailable-probe-device")] {
            if label == "selected external" && external == nil { print("Selected external: unavailable, not tested"); continue }
            let evidence = CaptureEvidence()
            let id = try service.start(uid: uid, directory: directory, onEvent: evidence.record)
            try await Task.sleep(for: .seconds(seconds))
            let audio = try await service.stop(sessionID: id)
            try evidence.check(audio, requireNonzero: true)
            evidence.report(label: label, audio: audio)
        }
        try service.setWarmMicrophone(enabled: true, uid: builtIn?.uid ?? "")
        try await Task.sleep(for: .seconds(1))
        let evidence = CaptureEvidence()
        let id = try service.start(uid: builtIn?.uid ?? "", directory: directory, onEvent: evidence.record)
        try await Task.sleep(for: .seconds(1))
        let audio = try await service.stop(sessionID: id)
        try evidence.check(audio, requireNonzero: true); precondition(audio.preRollSampleCount > 0)
        evidence.report(label: "built-in warm", audio: audio)
        try service.setWarmMicrophone(enabled: false, uid: "")
        let cancelledID = try service.start(uid: builtIn?.uid ?? "", directory: directory, onEvent: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        try await service.cancel(sessionID: cancelledID)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(cancelledID.uuidString + ".partial.wav").path))
        await service.shutdown()
        print("Native capture complete; probe engine closed. Raw probe audio is private and may be deleted after inspection.")
    }
}
