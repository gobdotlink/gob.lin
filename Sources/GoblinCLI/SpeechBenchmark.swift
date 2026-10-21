import AVFoundation
import Foundation
import FluidAudio
import GoblinCore
import GoblinEngines

/// Local timing output can include transcripts; keep detailed JSONL in a private evaluation directory.
enum SpeechBenchmark {
    static func prepare(_ runtime: SpeechModelRuntime, model: SpeechModelDescriptor, vocabularySupport: Bool = false) async throws {
        let engine = runtime.engine
        let directory = runtime.store.directory
        let existed = PinnedSpeechModelStore.isDownloaded(model: model, directory: directory)
        let before = SystemInfo.currentResidentMemoryBytes()
        let start = ContinuousClock.now
        _ = try await runtime.store.ensureAvailable(progress: { _ in })
        let acquisition = milliseconds(since: start)
        let auxiliaryStart = ContinuousClock.now
        if vocabularySupport {
            _ = try await SpeechRuntimeFactory.dictionaryCorrectionStore(root: directory.deletingLastPathComponent()).ensureAvailable(progress: { _ in })
        }
        let auxiliaryAcquisition = vocabularySupport ? milliseconds(since: auxiliaryStart) : 0
        let loadStart = ContinuousClock.now
        try await engine.prepare()
        let load = milliseconds(since: loadStart)
        let preparation = milliseconds(since: start)
        let loaded = SystemInfo.currentResidentMemoryBytes()
        await engine.unload()
        let unloaded = SystemInfo.currentResidentMemoryBytes()
        let reloadStart = ContinuousClock.now
        try await engine.prepare()
        let cachedReload = milliseconds(since: reloadStart)
        try write(["recordType": "preparation", "model": engine.identifier, "cacheExistedBefore": existed,
                   "prepareMilliseconds": preparation, "acquisitionMilliseconds": acquisition, "loadMilliseconds": load,
                   "auxiliaryAcquisitionMilliseconds": auxiliaryAcquisition, "vocabularySupport": vocabularySupport,
                   "auxiliaryCacheBytes": vocabularySupport ? try directoryBytes(directory.deletingLastPathComponent().appendingPathComponent(ParakeetDictionaryCorrection.cacheFolder)) : 0,
                   "cachedReloadMilliseconds": cachedReload,
                   "residentBytesBefore": before.map { $0 as Any } ?? NSNull(), "residentBytesLoaded": loaded.map { $0 as Any } ?? NSNull(),
                   "residentBytesUnloaded": unloaded.map { $0 as Any } ?? NSNull(), "cacheBytes": try directoryBytes(directory)])
    }

    static func run(_ arguments: [String], engine: any PCMSpeechEngine, directory: URL, options: RecognitionOptions = .init()) async throws {
        guard let source = arguments.first, !source.hasPrefix("--") else {
            throw CommandError.usage("Usage: goblin benchmark <file | directory> [--repeat N] [--windows 1.5,3,6,12] [--cadence-ms 400]")
        }
        var repeats = 1
        var windows: [Double] = []
        var cadence = 400.0
        var vocabularyURL: URL?
        var seen = Set<String>()
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted, index + 1 < arguments.count else { throw CommandError.usage("Missing or repeated benchmark option: \(option)") }
            let value = arguments[index + 1]
            switch option {
            case "--repeat":
                guard let count = Int(value), (1...20).contains(count) else { throw CommandError.usage("--repeat must be 1...20") }
                repeats = count
            case "--windows":
                let values = value.split(separator: ",", omittingEmptySubsequences: false)
                windows = try values.map {
                    guard let duration = Double($0), duration.isFinite, (0.1...15).contains(duration) else {
                        throw CommandError.usage("--windows requires comma-separated seconds in 0.1...15")
                    }
                    return duration
                }
            case "--vocabulary": vocabularyURL = URL(fileURLWithPath: value)
            case "--cadence-ms":
                guard let duration = Double(value), duration.isFinite, (100...5000).contains(duration) else {
                    throw CommandError.usage("--cadence-ms must be 100...5000")
                }
                cadence = duration
            default: throw CommandError.usage("Unknown benchmark option: \(option)")
            }
            index += 2
        }
        let url = URL(fileURLWithPath: source)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw RecordedAudioError.invalidFile }
        let extensions = Set(["wav", "aiff", "aif", "caf", "m4a", "mp3", "flac"])
        let files = isDirectory.boolValue
            ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { extensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            : [url]
        guard !files.isEmpty else { throw CommandError.usage("No audio files found") }
        guard vocabularyURL == nil || SpeechModelCatalog.model(id: engine.identifier)?.sharesParakeetV3Vocabulary == true else {
            throw CommandError.usage("--vocabulary needs a Parakeet model with v3's vocabulary.")
        }
        let loadStart = ContinuousClock.now
        try await engine.prepare()
        try write(["recordType": "load", "model": engine.identifier, "milliseconds": milliseconds(since: loadStart),
                   "residentBytes": SystemInfo.currentResidentMemoryBytes().map { $0 as Any } ?? NSNull()])
        let vocabulary = try await vocabularyURL.map { try VocabularyDiagnostic(termsURL: $0, modelDirectory: directory) }?.load()
        for file in files {
            try Task.checkCancellation()
            let audio = try AVAudioFile(forReading: file)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            var times: [Double] = []
            var recognition = TranscriptionResult(text: "")
            for _ in 0..<repeats {
                let start = ContinuousClock.now
                recognition = try await engine.transcribe(.init(audioFileURL: file, options: options))
                times.append(milliseconds(since: start))
            }
            try write(["recordType": "batch", "id": file.lastPathComponent, "model": engine.identifier,
                       "audioSeconds": duration, "milliseconds": times, "text": recognition.text,
                       "residentBytes": SystemInfo.currentResidentMemoryBytes().map { $0 as Any } ?? NSNull(),
                       "peakResidentBytes": SystemInfo.peakResidentMemoryBytes().map { $0 as Any } ?? NSNull()])
            if !windows.isEmpty || vocabulary != nil {
                let samples = try AudioConverter().resampleAudioFile(file)
                if let vocabulary {
                    let start = ContinuousClock.now
                    let boosted = try await vocabulary.rescore(recognition, samples: samples)
                    try write(["recordType": "vocabulary", "id": file.lastPathComponent, "termCount": vocabulary.termCount,
                               "milliseconds": milliseconds(since: start), "rawText": recognition.text, "text": boosted.text,
                               "replacements": boosted.replacements, "detectedTerms": boosted.detectedTerms,
                               "residentBytes": SystemInfo.currentResidentMemoryBytes().map { $0 as Any } ?? NSNull()])
                }
                for window in windows { try await benchmarkWindows(samples, file: file, seconds: window, cadenceMilliseconds: cadence, engine: engine, options: options) }
            }
        }
    }

    /// Accelerated replay measures per-window work, not native key-up/insertion or queue latency.
    private static func benchmarkWindows(_ samples: [Float], file: URL, seconds: Double, cadenceMilliseconds: Double,
                                         engine: any PCMSpeechEngine, options: RecognitionOptions) async throws {
        let stride = Int(cadenceMilliseconds * 16)
        let lookback = Int(seconds * 16_000)
        var end = min(stride, samples.count)
        while end < samples.count {
            try await measureWindow(samples, start: max(0, end - lookback), end: end, file: file,
                                    seconds: seconds, final: false, engine: engine, options: options)
            end = min(end + stride, samples.count)
        }
        try await measureWindow(samples, start: max(0, samples.count - lookback), end: samples.count,
                                file: file, seconds: seconds, final: true, engine: engine, options: options)
    }

    private static func measureWindow(_ samples: [Float], start: Int, end: Int, file: URL, seconds: Double,
                                      final: Bool, engine: any PCMSpeechEngine, options: RecognitionOptions) async throws {
        let window = Array(samples[start..<end])
        let begin = ContinuousClock.now
        let result = try await engine.transcribe(samples: window, options: options)
        try write(["recordType": "window", "id": file.lastPathComponent, "lookbackSeconds": seconds,
                   "audioPositionSeconds": Double(end) / 16_000, "windowStartSeconds": Double(start) / 16_000,
                   "final": final, "milliseconds": milliseconds(since: begin), "text": result.text,
                   "tokens": result.tokens.map { ["text": $0.text, "startSeconds": $0.startSeconds, "endSeconds": $0.endSeconds] as [String: Any] }])
    }

    private static func directoryBytes(_ directory: URL) throws -> Int64 {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in iterator {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if properties.isRegularFile == true { total += Int64(properties.fileSize ?? 0) }
        }
        return total
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private static func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
