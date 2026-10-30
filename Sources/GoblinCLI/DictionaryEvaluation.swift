import CryptoKit
import Foundation
import FluidAudio
import GoblinCore
import GoblinEngines

/// Paired unbiased/biased transcripts for every clip in a GOB-14 style manifest, one engine per process.
/// Every clip receives the same glossary; reference text is copied through for scoring, never used to pick terms.
enum DictionaryEvaluation {
    private struct Clip: Decodable {
        let id: String
        let audio: String
        let reference: String
        let target: String?
        let split: String
        let group: String
    }

    private enum Arm {
        /// Recognition alone, for models without a native dictionary: their terms reach only aliases and Cleanup.
        case recognitionOnly(any PCMSpeechEngine)
        case nativeVocabulary(any PCMSpeechEngine)
        case keyterms(MoonshineDiagnostic)
    }

    static let usage = """
        Usage: goblin dictionary-eval <manifest.json> --glossary <terms.txt | terms.json> [--split original|fresh]
          [--moonshine tiny|small|medium [--keyterm-boost 0...4] [--pad-ms 500] [--moonshine-dir <path>] [--download]]
        """

    static func run(_ arguments: [String], model: SpeechModelDescriptor, runtime: SpeechModelRuntime, options: RecognitionOptions) async throws {
        guard let source = arguments.first, !source.hasPrefix("--") else { throw CommandError.usage(usage) }
        var values: [String: String] = [:]
        var download = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if option == "--download" { download = true; index += 1; continue }
            guard ["--glossary", "--split", "--moonshine", "--keyterm-boost", "--pad-ms", "--moonshine-dir"].contains(option),
                  values[option] == nil, index + 1 < arguments.count else { throw CommandError.usage(usage) }
            values[option] = arguments[index + 1]
            index += 2
        }
        guard let glossaryPath = values["--glossary"] else { throw CommandError.usage(usage) }
        let moonshineOnly: Set<String> = ["--keyterm-boost", "--pad-ms", "--moonshine-dir"]
        guard values["--moonshine"] != nil || (moonshineOnly.isDisjoint(with: values.keys) && !download) else {
            throw CommandError.usage("Moonshine options require --moonshine")
        }
        let manifestURL = URL(fileURLWithPath: source)
        let glossaryURL = URL(fileURLWithPath: glossaryPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let glossaryData = try Data(contentsOf: glossaryURL)
        let clips = try JSONDecoder().decode([Clip].self, from: manifestData).filter { values["--split"] == nil || $0.split == values["--split"] }
        guard !clips.isEmpty else { throw CommandError.usage("No manifest clips match --split") }
        let terms = try glossaryTerms(glossaryData, json: glossaryURL.pathExtension.lowercased() == "json")
        guard !terms.isEmpty else { throw CommandError.usage("The glossary contains no terms") }

        let arm: Arm
        var configuration: [String: Any] = ["recordType": "configuration", "glossary": glossaryURL.lastPathComponent,
            "glossarySHA256": sha256(glossaryData), "manifestSHA256": sha256(manifestData), "termCount": terms.count,
            "clipCount": clips.count, "goblinVersion": GoblinMetadata.version, "language": options.language ?? "auto"]
        if let size = values["--moonshine"] {
            guard values["--keyterm-boost"].map({ Double($0) != nil }) ?? true,
                  values["--pad-ms"].map({ Int($0).map { (0...2_000).contains($0) } ?? false }) ?? true else {
                throw CommandError.usage("--keyterm-boost must be a number and --pad-ms 0...2000")
            }
            let directory = values["--moonshine-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? MoonshineDiagnostic.defaultDirectory(size: size)
            if download { try await MoonshineDiagnostic.download(size: size, to: directory) }
            let moonshine = try MoonshineDiagnostic(size: size, directory: directory,
                keytermBoost: values["--keyterm-boost"].flatMap(Double.init) ?? 2,
                trailingSilenceMilliseconds: values["--pad-ms"].flatMap(Int.init) ?? 500)
            arm = .keyterms(moonshine)
            configuration.merge(["engine": moonshine.identifier, "method": "decoder-keyterms", "keytermBoost": moonshine.keytermBoost,
                                 "trailingSilenceMilliseconds": moonshine.trailingSilenceMilliseconds]) { $1 }
        } else {
            try await runtime.engine.prepare()
            if model.capabilities.customVocabulary {
                arm = .nativeVocabulary(runtime.engine)
                configuration.merge(["engine": model.id, "method": "native-prompt"]) { $1 }
            } else {
                arm = .recognitionOnly(runtime.engine)
                configuration.merge(["engine": model.id, "method": "none"]) { $1 }
            }
        }
        try write(configuration)

        let directory = manifestURL.deletingLastPathComponent()
        var warmed = false
        for clip in clips {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(clip.audio)
            let samples = try AudioConverter().resampleAudioFile(file)
            if !warmed {
                // One untimed pass keeps model compilation and first-call allocation out of clip latency.
                _ = try await transcribe(arm, file: file, samples: samples, terms: [], options: options)
                warmed = true
            }
            var start = ContinuousClock.now
            let raw = try await transcribe(arm, file: file, samples: samples, terms: [], options: options)
            let rawMilliseconds = milliseconds(since: start)
            start = ContinuousClock.now
            let biased: (text: String, usage: SpeechDictionaryUsage?)
            if case .recognitionOnly = arm { biased = raw }
            else { biased = try await transcribe(arm, file: file, samples: samples, terms: terms, options: options) }
            var biasedMilliseconds = milliseconds(since: start)
            if case .recognitionOnly = arm { biasedMilliseconds += rawMilliseconds }
            var record: [String: Any] = ["recordType": "clip", "id": clip.id, "split": clip.split, "group": clip.group,
                "target": clip.target ?? NSNull(), "reference": clip.reference, "rawText": raw.text, "text": biased.text,
                "rawMilliseconds": rawMilliseconds, "biasedMilliseconds": biasedMilliseconds,
                "audioSeconds": Double(samples.count) / 16_000]
            if let usage = biased.usage { record["includedTerms"] = usage.included.count; record["excludedTerms"] = usage.excluded.count }
            try write(record)
        }
    }

    private static func transcribe(_ arm: Arm, file: URL, samples: [Float], terms: [String], options: RecognitionOptions)
        async throws -> (text: String, usage: SpeechDictionaryUsage?) {
        switch arm {
        case .keyterms(let moonshine):
            return (try moonshine.transcribe(samples, keyterms: terms), nil)
        case .nativeVocabulary(let engine), .recognitionOnly(let engine):
            let result = try await engine.transcribe(.init(audioFileURL: file, options: RecognitionOptions(language: options.language, vocabulary: terms)))
            return (result.text, result.dictionaryUsage)
        }
    }

    private static func glossaryTerms(_ data: Data, json: Bool) throws -> [String] {
        guard json else {
            return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        struct Document: Decodable { struct Term: Decodable { let text: String }; let terms: [Term] }
        return try JSONDecoder().decode(Document.self, from: data).terms.map(\.text)
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private static func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
