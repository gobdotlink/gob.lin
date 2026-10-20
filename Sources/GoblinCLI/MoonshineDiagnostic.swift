import Foundation
import MoonshineVoice

/// Benchmark-only Moonshine streaming recognizer with decoder-time key-term biasing.
/// The app does not link Moonshine; this exists to compare dictionary biasing against the catalog engines.
final class MoonshineDiagnostic {
    let size: String
    let keytermBoost: Double
    let trailingSilenceMilliseconds: Int
    private let transcriber: Transcriber

    static let sizes: [String: ModelArch] = ["tiny": .tinyStreaming, "small": .smallStreaming, "medium": .mediumStreaming]

    static func defaultDirectory(size: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/models/moonshine-\(size)-streaming-en", isDirectory: true)
    }

    /// Network acquisition is explicit, matching prepare-model for catalog engines.
    static func download(size: String, to directory: URL) async throws {
        guard let arch = sizes[size] else { throw CommandError.usage("--moonshine must be tiny, small or medium") }
        try await AssetDownloader().ensureModelPresent(root: directory, spec: .stt(language: "en", modelArch: arch))
    }

    init(size: String, directory: URL, keytermBoost: Double, trailingSilenceMilliseconds: Int) throws {
        guard let arch = Self.sizes[size] else { throw CommandError.usage("--moonshine must be tiny, small or medium") }
        guard AssetDownloader().isModelPresent(root: directory, spec: .stt(language: "en", modelArch: arch)) else {
            throw CommandError.usage("Moonshine \(size) is not installed. Rerun with --download to fetch it into \(directory.path).")
        }
        // The SDK documents 4.0 as the point where biasing breaks down; keep the sweep inside its tested range.
        guard keytermBoost.isFinite, (0...4).contains(keytermBoost) else { throw CommandError.usage("--keyterm-boost must be 0...4") }
        self.size = size
        self.keytermBoost = keytermBoost
        self.trailingSilenceMilliseconds = trailingSilenceMilliseconds
        transcriber = try Transcriber(modelPath: directory.path, modelArch: arch,
                                      options: [TranscriberOption(name: "keyterm_boost", value: String(keytermBoost))])
    }

    var identifier: String { "moonshine-\(size)-streaming-en" }

    /// Streaming models look ahead; without trailing silence an abrupt clip end loses or garbles the last word.
    func transcribe(_ samples: [Float], keyterms: [String]) throws -> String {
        try transcriber.setKeyterms(keyterms)
        let padded = samples + [Float](repeating: 0, count: trailingSilenceMilliseconds * 16)
        return try transcriber.transcribeWithoutStreaming(audioData: padded).lines.map(\.text)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
