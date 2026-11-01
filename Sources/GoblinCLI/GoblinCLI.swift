import Foundation
import FluidAudio
import GoblinCore
import GoblinEngines

@main
struct GoblinCLI {
    static func main() async {
        AppLogger.mirrorsToConsole = false
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            var modelID = SpeechModelCatalog.defaultModel.id
            var language = "auto"
            var modelDirectory: URL?
            for option in ["--model", "--language", "--model-dir"] {
                if let index = arguments.firstIndex(of: option) {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                          arguments.filter({ $0 == option }).count == 1 else {
                        throw CommandError.usage("\(option) requires one value")
                    }
                    let value = arguments[index + 1]
                    switch option {
                    case "--model": modelID = value
                    case "--language": language = SpeechModelCatalog.canonicalLanguage(value)
                    default: modelDirectory = URL(fileURLWithPath: value, isDirectory: true)
                    }
                    arguments.removeSubrange(index...index + 1)
                }
            }
            guard let model = SpeechModelCatalog.model(id: modelID) else {
                throw CommandError.usage("Unknown speech model: \(modelID). Run goblin models for supported IDs.")
            }
            guard language == "auto" || model.capabilities.languageCodes.contains(where: {
                SpeechModelCatalog.canonicalLanguage($0) == language
            }) else { throw CommandError.usage("\(model.name) does not support language \(language). Run goblin models.") }
            if ["transcribe", "replay", "live-replay", "benchmark", "dictionary-eval"].contains(arguments.first ?? ""),
               !model.capabilities.automaticLanguage, model.capabilities.languageControl != .fixed,
               language == "auto", !arguments.contains("--recorded") {
                throw CommandError.usage("\(model.name) requires --language <code>.")
            }
            if arguments.first == "rewrite-eval" {
                // Text-only: runs the saved AI cleanup over existing results without loading a speech model.
                try await RewriteEvaluation.run(Array(arguments.dropFirst()))
                return
            }
            if arguments == ["models"] {
                let models = SpeechModelCatalog.supported.map { model in
                    ["id": model.id, "name": model.name, "purpose": model.purpose, "detail": model.detail,
                     "runtime": model.runtime, "downloadBytes": model.downloadBytes, "languages": model.capabilities.languageCodes,
                     "automaticLanguage": model.capabilities.automaticLanguage, "livePreview": model.capabilities.livePreview,
                     "customVocabulary": model.capabilities.customVocabulary,
                     "recommended": model.recommended,
                     "default": model.id == SpeechModelCatalog.defaultModel.id] as [String: Any]
                }
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: models, options: [.sortedKeys]) + Data([0x0A]))
                return
            }
            let runtime = SpeechRuntimeFactory.make(model, directory: modelDirectory)
            var options = model.capabilities.options(for: language)
            if model.capabilities.customVocabulary, ["transcribe", "replay", "live-replay"].contains(arguments.first ?? ""),
               !arguments.contains("--recorded") {
                var dictionary = DictionaryRepository.applicationDefault
                if let index = arguments.firstIndex(of: "--dictionary") {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                          arguments.filter({ $0 == "--dictionary" }).count == 1 else {
                        throw CommandError.usage("--dictionary requires one path")
                    }
                    dictionary = DictionaryRepository(url: URL(fileURLWithPath: arguments[index + 1]))
                }
                for option in ["--app", "--project"] where arguments.filter({ $0 == option }).count > 1 {
                    throw CommandError.usage("\(option) accepts one value")
                }
                func value(_ option: String) -> String? {
                    arguments.firstIndex(of: option).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                }
                let scope = DictionaryScope(application: value("--app"), project: value("--project"))
                let vocabulary = try dictionary.load().vocabulary(in: scope)
                options = RecognitionOptions(language: options.language, vocabulary: vocabulary)
            }
            if arguments.first == "prepare-model" {
                guard arguments.count == 1 else { throw CommandError.usage("Usage: goblin prepare-model [--model-dir <path>]") }
                try await SpeechBenchmark.prepare(runtime, model: model)
            } else if arguments.first == "dictionary-eval" {
                try await DictionaryEvaluation.run(Array(arguments.dropFirst()), model: model, runtime: runtime, options: options)
            } else if arguments.first == "live-replay" {
                var replayArguments = Array(arguments.dropFirst())
                for option in ["--dictionary", "--app", "--project"] {
                    if let index = replayArguments.firstIndex(of: option) { replayArguments.removeSubrange(index...min(index + 1, replayArguments.count - 1)) }
                }
                try await LiveReplay.run(replayArguments, engine: runtime.engine, options: options,
                                         previewAvailable: model.capabilities.livePreview)
            } else if arguments.first == "benchmark" {
                try await SpeechBenchmark.run(Array(arguments.dropFirst()), engine: runtime.engine, options: options)
            } else {
                try await GoblinCommands(pipeline: RecordedAudioPipeline(engine: runtime.engine, options: options)).run(arguments)
            }
            await runtime.engine.unload()
        } catch {
            let code: String
            let status: Int32
            switch error {
            case RecordedAudioError.engineNotConfigured: code = "engine_not_configured"; status = 3
            case SpeechRuntimeError.modelNotInstalled: code = "model_not_installed"; status = 3
            case is CommandError: code = "usage"; status = 2
            default: code = "operation_failed"; status = 1
            }
            let payload = ["error": ["code": code, "message": error.localizedDescription]]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"error\":{\"code\":\"operation_failed\"}}".utf8)
            FileHandle.standardError.write(data + Data([0x0A]))
            exit(status)
        }
    }
}

enum CommandError: Error, LocalizedError {
    case usage(String)
    var errorDescription: String? { switch self { case .usage(let message): message } }
}

private struct GoblinCommands {
    let pipeline: RecordedAudioPipeline?

    private func prepare() async throws {
        guard let engine = pipeline?.engine as? any PCMSpeechEngine else { return }
        try await engine.prepare()
    }
    private let processor = TranscriptPostprocessor()

    func run(_ arguments: [String]) async throws {
        switch arguments {
        case ["--version"]: print("\(GoblinMetadata.name) \(GoblinMetadata.version)")
        case ["--self-check"]: print("GoblinCore, GoblinEngines, and system SQLite loaded successfully.")
        case [], ["--help"], ["-h"]: print(Self.help)
        case let values where values.first == "transcribe":
            guard values.count >= 2, !values[1].hasPrefix("--") else { throw CommandError.usage("Usage: goblin transcribe <audio-file> [--process] [--rewrite] [--tone <tone>] [--dictionary <path>] [--app <bundle-id>] [--project <name>]") }
            var options = CLIProcessingOptions(enabled: true)
            var index = 2
            while index < values.count {
                guard try options.consume(values, index: &index) else { throw CommandError.usage("Unknown transcribe option: \(values[index])") }
            }
            let file = URL(fileURLWithPath: values[1])
            guard FileManager.default.isReadableFile(atPath: file.path),
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RecordedAudioError.invalidFile }
            guard let pipeline else { throw RecordedAudioError.engineNotConfigured }
            try await prepare()
            var result = try await pipeline.transcribe(file)
            if options.enabled {
                let configuration = try CLIProcessingConfiguration(options: options)
                let processed = await configuration.process(result.rawText, using: processor)
                result.finalText = processed.finalText
                result.tone = processed.tone.rawValue
                result.polished = processed.polished
                result.postprocessingError = processed.warning?.message
                result.timings.rewriteMilliseconds = processed.timings.rewriteMilliseconds
            }
            try writeJSON(result)
        case let values where values.first == "replay": try await replay(Array(values.dropFirst()))
        case let values where values.first == "eval": try evaluate(Array(values.dropFirst()))
        default: throw CommandError.usage("Unknown arguments. Run goblin --help.")
        }
    }

    private func replay(_ arguments: [String]) async throws {
        guard let source = arguments.first, !source.hasPrefix("--") else {
            throw CommandError.usage("Usage: goblin replay <directory | history> [--recorded] [--history-dir <path>]")
        }
        var recorded = false
        var historyDirectory: URL?
        var options = CLIProcessingOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--recorded":
                guard !recorded else { throw CommandError.usage("--recorded was supplied twice") }
                recorded = true; index += 1
            case "--history-dir":
                guard source == "history", historyDirectory == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CommandError.usage("--history-dir requires history and a directory path")
                }
                historyDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true); index += 2
            default:
                guard try options.consume(arguments, index: &index) else { throw CommandError.usage("Unknown replay option: \(arguments[index])") }
            }
        }
        if !recorded, pipeline == nil { throw RecordedAudioError.engineNotConfigured }
        if !recorded {
            options.enabled = true
            try await prepare()
        }
        let configuration = try options.enabled ? CLIProcessingConfiguration(options: options) : nil
        if source == "history" {
            let store = try HistoryStore(directory: historyDirectory)
            var offset = 0
            while true {
                let entries = try await store.entries(limit: 200, offset: offset)
                for entry in entries {
                    let record: EvaluationRecord
                    if recorded {
                        record = EvaluationRecord(id: entry.id.uuidString, rawText: entry.rawText, finalText: entry.finalText,
                                                  model: entry.model, timings: entry.latencies, postprocessingError: entry.processingWarning)
                    } else {
                        guard let file = try await store.audioFileURL(for: entry.id) else {
                            throw CommandError.usage("History entry \(entry.id) has no saved audio. Use --recorded to export its transcript.")
                        }
                        record = try await transcribedRecord(file, id: entry.id.uuidString)
                    }
                    try FileHandle.standardOutput.write(contentsOf: try EvaluationJSONL.encode(await processedRecord(record, configuration: configuration)))
                }
                if entries.count < 200 { break }
                offset += entries.count
            }
        } else {
            let directory = URL(fileURLWithPath: source, isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if recorded {
                let records = try files.filter { $0.pathExtension.lowercased() == "jsonl" }.flatMap(EvaluationJSONL.read)
                guard !records.isEmpty else { throw CommandError.usage("No recorded-transcript JSONL files found in this directory.") }
                try Evaluator.validate(records)
                for record in records {
                    var exported = record
                    exported.source = "recorded_transcript"
                    try FileHandle.standardOutput.write(contentsOf: try EvaluationJSONL.encode(await processedRecord(exported, configuration: configuration)))
                }
            } else {
                let extensions = Set(["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"])
                let audioFiles = files.filter { extensions.contains($0.pathExtension.lowercased()) }
                guard !audioFiles.isEmpty else { throw CommandError.usage("No audio recordings found in this directory.") }
                for file in audioFiles {
                    let record = try await transcribedRecord(file, id: file.lastPathComponent)
                    try FileHandle.standardOutput.write(contentsOf: try EvaluationJSONL.encode(await processedRecord(record, configuration: configuration)))
                }
            }
        }
    }

    private func processedRecord(_ record: EvaluationRecord, configuration: CLIProcessingConfiguration?) async -> EvaluationRecord {
        guard let configuration else { return record }
        let result = await configuration.process(record.rawText, using: processor)
        var processed = record
        processed.finalText = result.finalText
        processed.postprocessingError = result.warning?.message
        var timings = record.source == "recorded_transcript" ? DictationTimings() : record.timings ?? DictationTimings()
        timings.rewriteMilliseconds = result.timings.rewriteMilliseconds
        processed.timings = timings
        if record.source == "recorded_transcript" { processed.source = "recorded_postprocessing" }
        return processed
    }

    private func transcribedRecord(_ file: URL, id: String) async throws -> EvaluationRecord {
        guard let pipeline else { throw RecordedAudioError.engineNotConfigured }
        let result = try await pipeline.transcribe(file)
        return EvaluationRecord(id: id, rawText: result.rawText, finalText: result.finalText,
                                model: result.model, source: "audio_transcription", timings: result.timings,
                                postprocessingError: result.postprocessingError)
    }

    private func evaluate(_ arguments: [String]) throws {
        guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--json") else {
            throw CommandError.usage("Usage: goblin eval <A.jsonl> <B.jsonl> [--json]")
        }
        let report = try Evaluator.compare(EvaluationJSONL.read(URL(fileURLWithPath: arguments[0])),
                                           EvaluationJSONL.read(URL(fileURLWithPath: arguments[1])))
        if arguments.count == 3 { try writeJSON(report); return }
        print("Aligned \(report.alignedRecords) recordings; \(report.changedRecords) changed.")
        print("Missing from A: \(report.missingFromA.isEmpty ? "none" : report.missingFromA.joined(separator: ", "))")
        print("Missing from B: \(report.missingFromB.isEmpty ? "none" : report.missingFromB.joined(separator: ", "))")
        for (name, summary) in [("A", report.a), ("B", report.b)] {
            let wer = summary.wordErrorRate.map { String(format: "%.2f%%", $0 * 100) } ?? "unavailable (no nonempty ground truth)"
            let jargon = summary.jargonAnnotatedRecords > 0 ? "\(summary.jargonHits)/\(summary.jargonExpected)" : "unavailable (no annotations)"
            let ordinary = summary.ordinaryWordAnnotatedRecords > 0 ? "\(summary.ordinaryWordFalseCorrections)" : "unavailable (no annotations)"
            print("\(name): WER \(wer); jargon \(jargon); ordinary-word false corrections \(ordinary)")
            if let timing = summary.latencyMilliseconds["processing"] {
                print(String(format: "  Processing latency (%d samples): p50 %.1f ms, p90 %.1f ms, p95 %.1f ms, p99 %.1f ms", timing.count, timing.p50, timing.p90, timing.p95, timing.p99))
            } else { print("  Latency unavailable (no recorded timings)") }
        }
        for record in report.records where record.wordDiff.contains(where: { $0.operation != .equal }) {
            let changes = record.wordDiff.filter { $0.operation != .equal }.map { edit in
                [edit.referenceWord.map { "-\($0)" }, edit.candidateWord.map { "+\($0)" }].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " | ")
            print("\(record.id): \(changes)")
        }
    }

    private func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf: try encoder.encode(value) + Data([0x0A]))
    }

    private static let help = """
    goblin — the gob.lin command-line companion

    Usage:
      goblin transcribe <audio-file>                 JSON text and stage timings
      goblin replay <directory | history>            JSONL, using the selected engine
      goblin replay <directory | history> --recorded JSONL from existing transcripts
      goblin live-replay <audio-file>... [--speed <x>] [--texts]  Live path at key-up vs whole-recording recognition
      goblin replay history --recorded --history-dir <path>
      goblin eval <A.jsonl> <B.jsonl> [--json]        ID-aligned evaluation report
      goblin --version | --self-check | --help
      goblin models                               Catalog IDs, sizes, languages and capabilities

      goblin prepare-model                        Explicit download; JSON load/cache metrics
      goblin benchmark <file | directory>          Local batch timing JSONL
        [--repeat N] [--windows 1.5,3,6,12] [--cadence-ms 400]
      goblin dictionary-eval <manifest.json> --glossary <terms>
                                                   Paired unbiased/biased JSONL per clip [--split original|fresh]
        [--moonshine tiny|small|medium]            Moonshine key-term biasing instead of --model
        [--keyterm-boost 2] [--pad-ms 500] [--moonshine-dir <path>] [--download]
      goblin rewrite-eval <dictionary-eval.jsonl> --glossary <terms> | --no-glossary
                                                   Saved AI cleanup over those results; sends transcripts to the provider
        [--source raw|text] [--concurrency 4]
      --model-dir <path> overrides the model cache for any command.
      --model <id> chooses a catalog model. --language auto|<code> sets recognition language.

    Parakeet TDT v3 is the default.
    Parakeet's language preference guides the writing script, not a same-script language lock.
    Transcribe/replay/benchmark load local models only.
    Run prepare-model once before recognition. Recognition and benchmarks run locally.
    Processing options: --process, --tone formal|casual|veryCasual, --dictionary <JSON>, --app <bundle-id>, --project <name>.
    Transcribe/replay also send preferred spellings to models with customVocabulary support (Whisper's prompt;
    whole terms fit most specific first, up to 32, within the token budget; transcribe reports dictionaryUsage).
    --rewrite additionally opts into your enabled provider and reads its saved key.
    Ground truth, jargon, and ordinary-word annotations are needed for accuracy metrics.
    """
}
