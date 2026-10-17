import FluidAudio
import Foundation

public actor SenseVoiceSpeechEngine: PCMSpeechEngine {
    public nonisolated let identifier = SpeechModelCatalog.senseVoice.id
    public nonisolated let maximumWindowSamples = 240_000
    private let directory: URL
    private var models: SenseVoiceModels?
    private var detector: SpeechActivityDetector?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL) { self.directory = directory }

    public func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if models != nil { return }
        guard PinnedSpeechModelStore.isDownloaded(model: SpeechModelCatalog.senseVoice, directory: directory) else {
            throw SpeechRuntimeError.modelNotInstalled
        }
        let detector = try SpeechActivityDetector.load(beside: directory)
        let models = try SenseVoiceModels.load(from: directory, precision: .int8)
        try Task.checkCancellation()
        self.models = models; self.detector = detector
    }

    public func unload() async {
        await acquire()
        defer { release() }
        models = nil; detector = nil
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
        guard let models else { throw SpeechRuntimeError.modelNotInstalled }
        guard let detector else { throw SpeechRuntimeError.speechDetectorNotInstalled }
        let language = try Self.languageIndex(options.validatedLanguage(for: SpeechModelCatalog.senseVoice))
        let presence = try await detector.presence(in: samples)
        guard presence != .notDetected else { return .init(text: "", speechPresence: .notDetected) }
        let manager = SenseVoiceManager(models: models, language: language)
        let text = try await Self.decodeWindows(samples) { audio in
            guard try await detector.presence(in: audio) != .notDetected else { return "" }
            return try await manager.transcribe(audio: audio)
        }
        return .init(text: text, speechPresence: presence)
    }

    static func languageIndex(_ code: String?) throws -> Int32 {
        guard let code else { return 0 }
        switch code {
        case "zh": return 3
        case "en": return 4
        case "yue": return 7
        case "ja": return 11
        case "ko": return 12
        default: throw SpeechRuntimeError.unsupportedLanguage(code)
        }
    }

    static func decodeWindows(_ samples: [Float], decode: @Sendable ([Float]) async throws -> String) async throws -> String {
        // The SDK silently truncates long input. Stay well below its 108-second feature limit.
        let window = 480_000
        let overlap = 32_000
        var start = 0
        var text = ""
        var canMerge = false
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, start + window)
            let next = try await decode(Array(samples[start..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty {
                text = Self.merge(text, next, overlapping: canMerge)
                canMerge = true
            } else { canMerge = false }
            if end == samples.count { break }
            start = end - overlap
        }
        try Task.checkCancellation()
        return text
    }

    static func merge(_ text: String, _ next: String, overlapping: Bool) -> String {
        let limit = min(120, text.count, next.count - 1)
        if overlapping, limit >= 8 {
            for count in stride(from: limit, through: 8, by: -1) where text.suffix(count) == next.prefix(count) {
                return text + next.dropFirst(count)
            }
        }
        // Without timings, retain unmatched and wholly repeated hypotheses.
        return text.isEmpty ? next : text + " " + next
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
