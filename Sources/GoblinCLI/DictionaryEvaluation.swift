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
        case ctcRescoring(any PCMSpeechEngine, VocabularyDiagnostic.Loaded, ParakeetCorrectionGuard.Policy)
        case recognitionOnly(any PCMSpeechEngine)
        case nativeVocabulary(any PCMSpeechEngine)
        case keyterms(MoonshineDiagnostic)
    }

    static let usage = """
        Usage: goblin dictionary-eval <manifest.json> --glossary <terms.txt | terms.json> [--split original|fresh]
          [--moonshine tiny|small|medium [--keyterm-boost 0...4] [--pad-ms 500] [--moonshine-dir <path>] [--download]]
          [--parakeet-correction ctc|none] [--guard none|spelling|confidence:<t>|spelling-or-confidence:<t>] [--text-join]
        """

    static func run(_ arguments: [String], model: SpeechModelDescriptor, runtime: SpeechModelRuntime, options: RecognitionOptions) async throws {
        guard let source = arguments.first, !source.hasPrefix("--") else { throw CommandError.usage(usage) }
        var values: [String: String] = [:]
        var download = false
        var textJoin = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if option == "--download" { download = true; index += 1; continue }
            if option == "--text-join" { textJoin = true; index += 1; continue }
            guard ["--glossary", "--split", "--moonshine", "--keyterm-boost", "--pad-ms", "--moonshine-dir",
                   "--parakeet-correction", "--guard"].contains(option),
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
        let correctionGuard = try ParakeetCorrectionGuard.Policy(values["--guard"] ?? "none")
        guard [nil, "ctc", "none"].contains(values["--parakeet-correction"]) else { throw CommandError.usage("--parakeet-correction must be ctc or none") }
        let usesCTC = values["--parakeet-correction"] != "none"
        guard (values["--guard"] == nil && values["--parakeet-correction"] == nil)
                || (values["--moonshine"] == nil && model.id == SpeechModelCatalog.parakeet.id) else {
            throw CommandError.usage("--guard and --parakeet-correction are Parakeet TDT v3 options")
        }
        guard usesCTC || correctionGuard == .none else { throw CommandError.usage("--guard filters CTC corrections; omit it with --parakeet-correction none") }

        let arm: Arm
        var configuration: [String: Any] = ["recordType": "configuration", "glossary": glossaryURL.lastPathComponent,
            "glossarySHA256": sha256(glossaryData), "manifestSHA256": sha256(manifestData), "termCount": terms.count,
            "clipCount": clips.count, "goblinVersion": GoblinMetadata.version, "language": options.language ?? "auto",
            "textJoin": textJoin]
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
            } else if model.id == SpeechModelCatalog.parakeet.id, !usesCTC {
                arm = .recognitionOnly(runtime.engine)
                configuration.merge(["engine": model.id, "method": "none"]) { $1 }
            } else if model.id == SpeechModelCatalog.parakeet.id {
                let vocabulary = try await VocabularyDiagnostic(termsURL: glossaryURL, modelDirectory: runtime.store.directory).load()
                arm = .ctcRescoring(runtime.engine, vocabulary, correctionGuard)
                // FLUID_* overrides change the SDK's rescoring policy; record them so arms stay reproducible.
                let overrides = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("FLUID_") }
                configuration.merge(["engine": model.id, "method": "ctc-rescoring", "sdkEnvironment": overrides,
                                     "guard": correctionGuard.description]) { $1 }
            } else {
                throw CommandError.usage("\(model.name) has no dictionary mechanism to evaluate.")
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
            var biased: (text: String, usage: SpeechDictionaryUsage?)
            var guardCounts: ParakeetCorrectionGuard.Outcome?
            switch arm {
            case .ctcRescoring(_, let vocabulary, let policy):
                // Rescoring corrects the unbiased recognition, so its full cost includes that pass.
                let corrected = try await vocabulary.rescore(raw.recognition, samples: samples).text
                guardCounts = ParakeetCorrectionGuard.apply(policy, recognition: raw.recognition, corrected: corrected, terms: terms)
                biased = (guardCounts!.text, nil)
            case .recognitionOnly:
                biased = (raw.output.text, nil)
            default:
                biased = try await transcribe(arm, file: file, samples: samples, terms: terms, options: options).output
            }
            if textJoin { biased.text = ParakeetCorrectionGuard.textJoin(biased.text, terms: terms) }
            var biasedMilliseconds = milliseconds(since: start)
            switch arm {
            case .ctcRescoring, .recognitionOnly: biasedMilliseconds += rawMilliseconds
            default: break
            }
            var record: [String: Any] = ["recordType": "clip", "id": clip.id, "split": clip.split, "group": clip.group,
                "target": clip.target ?? NSNull(), "reference": clip.reference, "rawText": raw.output.text, "text": biased.text,
                "rawMilliseconds": rawMilliseconds, "biasedMilliseconds": biasedMilliseconds,
                "audioSeconds": Double(samples.count) / 16_000]
            if let usage = biased.usage { record["includedTerms"] = usage.included.count; record["excludedTerms"] = usage.excluded.count }
            if let guardCounts, case .ctcRescoring(_, _, let policy) = arm, policy != .none {
                record["guardAccepted"] = guardCounts.accepted; record["guardRejected"] = guardCounts.rejected
            }
            switch arm {
            case .ctcRescoring, .recognitionOnly:
                record["rawWords"] = ParakeetCorrectionGuard.recognizedWords(raw.recognition).map {
                    ["word": $0.surface, "confidence": $0.confidence.map { Double($0) as Any } ?? NSNull()] as [String: Any]
                }
            default: break
            }
            try write(record)
        }
    }

    private static func transcribe(_ arm: Arm, file: URL, samples: [Float], terms: [String], options: RecognitionOptions)
        async throws -> (output: (text: String, usage: SpeechDictionaryUsage?), recognition: TranscriptionResult) {
        switch arm {
        case .keyterms(let moonshine):
            let text = try moonshine.transcribe(samples, keyterms: terms)
            return ((text, nil), TranscriptionResult(text: text))
        case .nativeVocabulary(let engine), .ctcRescoring(let engine, _, _), .recognitionOnly(let engine):
            let result = try await engine.transcribe(.init(audioFileURL: file,
                options: RecognitionOptions(language: options.language, vocabulary: terms)))
            return ((result.text, result.dictionaryUsage), result)
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
