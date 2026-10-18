import CoreML
import FluidAudio
import Foundation

struct SpeechActivityDetector: Sendable {
    static let cacheFolder = Repo.vad.folderName
    private let manager: VadManager

    static func load(beside directory: URL) throws -> Self {
        let url = directory.deletingLastPathComponent().appendingPathComponent(cacheFolder, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SpeechRuntimeError.speechDetectorNotInstalled }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return Self(manager: VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: try MLModel(contentsOf: url, configuration: configuration)))
    }

    func presence(in samples: [Float]) async throws -> SpeechPresence {
        var state = VadStreamState.initial()
        var speechEnd: Int?
        for start in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
            try Task.checkCancellation()
            let end = min(samples.count, start + VadManager.chunkSize)
            let activity = try await manager.processStreamingChunk(Array(samples[start..<end]), state: state)
            state = activity.state
            if activity.probability >= 0.5 { speechEnd = end }
        }
        return speechEnd.map { .detected(endSeconds: Double($0) / 16_000) } ?? .notDetected
    }
}
