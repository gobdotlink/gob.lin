import FluidAudio
import Foundation

public actor NemotronSpeechEngine: PCMSpeechEngine {
    public nonisolated let identifier = SpeechModelCatalog.nemotron.id
    public nonisolated let maximumWindowSamples = 240_000
    private let directory: URL
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var detector: SpeechActivityDetector?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL) { self.directory = directory }

    public func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if manager != nil { return }
        guard PinnedSpeechModelStore.isDownloaded(model: SpeechModelCatalog.nemotron, directory: directory) else {
            throw SpeechRuntimeError.modelNotInstalled
        }
        let detector = try SpeechActivityDetector.load(beside: directory)
        let manager = StreamingNemotronMultilingualAsrManager()
        do {
            try await manager.loadModels(from: directory)
            try Task.checkCancellation()
        } catch { await manager.cleanup(); throw error }
        self.manager = manager; self.detector = detector
    }

    public func unload() async {
        await acquire()
        defer { release() }
        await manager?.cleanup()
        manager = nil; detector = nil
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard request.audioFileURL.isFileURL, FileManager.default.isReadableFile(atPath: request.audioFileURL.path),
              try request.audioFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RecordedAudioError.invalidFile }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await recognize(AudioConverter().resampleAudioFile(request.audioFileURL), options: request.options)
    }

    public func transcribe(samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        guard samples.count <= maximumWindowSamples else { throw SpeechRuntimeError.windowTooLong }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SpeechRuntimeError.invalidSamples }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await recognize(samples, options: options)
    }

    private func recognize(_ samples: [Float], options: RecognitionOptions) async throws -> TranscriptionResult {
        guard let manager else { throw SpeechRuntimeError.modelNotInstalled }
        guard let detector else { throw SpeechRuntimeError.speechDetectorNotInstalled }
        let code = try options.validatedLanguage(for: SpeechModelCatalog.nemotron)
        let dictionary = await manager.config.promptDictionary
        let language = try Self.promptLanguage(code, dictionary: dictionary)
        let presence = try await detector.presence(in: samples)
        guard presence != .notDetected else { return .init(text: "", speechPresence: .notDetected) }
        // Preview windows and file requests are independent sessions; cache only within this request.
        await manager.reset()
        await manager.setLanguage(language)
        do {
            for start in stride(from: 0, to: samples.count, by: 160_000) {
                try Task.checkCancellation()
                _ = try await manager.process(samples: Array(samples[start..<min(samples.count, start + 160_000)]))
            }
            let result = try await manager.finishWithTokenTimings()
            try Task.checkCancellation()
            await manager.reset()
            return .init(text: result.text, tokens: result.timings.map {
                TranscriptionToken(text: $0.token, startSeconds: $0.startTime, endSeconds: $0.endTime,
                                   confidence: $0.confidence, tokenID: $0.tokenId)
            }, speechPresence: presence)
        } catch { await manager.reset(); throw error }
    }

    static func promptLanguage(_ code: String?, dictionary: [String: Int]) throws -> String? {
        guard let code else { return nil }
        // The trained Bokmål locale differs from the conversion's generic Norwegian prompt.
        if code == "no", dictionary["nb-NO"] != nil { return "nb-NO" }
        if dictionary[code] != nil { return code }
        if let key = dictionary.keys.sorted().first(where: { $0.contains("-") && SpeechModelCatalog.canonicalLanguage($0) == code }) {
            return key
        }
        throw SpeechRuntimeError.unsupportedLanguage(code)
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
