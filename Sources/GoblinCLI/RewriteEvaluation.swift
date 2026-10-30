import CryptoKit
import Foundation
import GoblinCore

/// Runs the saved AI cleanup over an existing `dictionary-eval` JSONL, so recognizer arms and cleanup are scored together.
/// Every clip receives the same glossary; reference text is copied through for scoring, never sent to the provider.
enum RewriteEvaluation {
    static let usage = """
        Usage: goblin rewrite-eval <dictionary-eval.jsonl> (--glossary <terms.txt> | --no-glossary)
          [--source raw|text] [--concurrency 4]
        """

    static func run(_ arguments: [String]) async throws {
        guard let source = arguments.first, !source.hasPrefix("--") else { throw CommandError.usage(usage) }
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if option == "--no-glossary" { flags.insert(option); index += 1; continue }
            guard ["--glossary", "--source", "--concurrency"].contains(option),
                  values[option] == nil, index + 1 < arguments.count else { throw CommandError.usage(usage) }
            values[option] = arguments[index + 1]
            index += 2
        }
        guard (values["--glossary"] == nil) == flags.contains("--no-glossary"),
              [nil, "raw", "text"].contains(values["--source"]),
              values["--concurrency"].map({ Int($0).map { (1...16).contains($0) } ?? false }) ?? true else {
            throw CommandError.usage(usage)
        }
        let glossaryData = try values["--glossary"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let terms = glossaryData.map { String(decoding: $0, as: UTF8.self).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        let useRaw = values["--source"] == "raw"

        var processing = CLIProcessingOptions(enabled: true)
        processing.allowRewrite = true
        var configuration = try CLIProcessingConfiguration(options: processing)
        configuration.entries = terms.map { DictionaryEntry(spelling: $0) }

        let records = try jsonLines(URL(fileURLWithPath: source))
        let clips = records.filter { $0["recordType"] as? String == "clip" }
        guard !clips.isEmpty else { throw CommandError.usage("No clip records in \(source)") }

        let sourceConfiguration = records.first { $0["recordType"] as? String == "configuration" } ?? [:]
        try write(["recordType": "configuration", "source": URL(fileURLWithPath: source).lastPathComponent,
                   "engine": "\(sourceConfiguration["engine"] as? String ?? "unknown")+cleanup", "method": "rewrite",
                   "sourceField": useRaw ? "rawText" : "text", "glossary": values["--glossary"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? NSNull(),
                   "glossarySHA256": glossaryData.map(sha256) ?? NSNull(), "termCount": terms.count,
                   "provider": configuration.rewrite.provider.rawValue, "model": configuration.rewrite.model,
                   "cleanup": configuration.rewrite.cleanup.rawValue, "reasoning": configuration.rewrite.reasoning.rawValue,
                   "temperature": configuration.rewrite.temperature ?? NSNull(), "tone": configuration.tone.rawValue,
                   "promptSHA256": sha256(Data(RewritePrompt.predefined.utf8)),
                   "deduplicated": configuration.rewrite.temperature == 0, "goblinVersion": GoblinMetadata.version])

        struct Job: Sendable { let order: Int; let input: String }
        let jobs = clips.enumerated().map { order, clip in
            Job(order: order, input: (useRaw ? clip["rawText"] : clip["text"]) as? String ?? "")
        }

        // Identical requests at temperature 0 are sent once; repeated transcripts reuse the first result.
        // Any other temperature samples every clip separately.
        let processor = TranscriptPostprocessor()
        let settings = configuration
        let deterministic = settings.rewrite.temperature == 0
        let requestKey = { (job: Job) in deterministic ? job.input : "\(job.order)" }
        let unique = Dictionary(jobs.map { (requestKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var results: [String: (result: TranscriptProcessingResult, attempts: Int)] = [:]
        let limit = values["--concurrency"].flatMap(Int.init) ?? 4
        try await withThrowingTaskGroup(of: (String, TranscriptProcessingResult, Int).self) { group in
            var pending = unique.sorted { $0.value.order < $1.value.order }.makeIterator()
            func enqueue() {
                guard let (key, job) = pending.next() else { return }
                group.addTask {
                    var attempt = 1
                    while true {
                        let result = await processor.process(job.input, dictionaryEntries: settings.entries, tone: settings.tone,
                            rewriteSettings: settings.rewrite, apiKey: settings.apiKey)
                        // Rate limits and timeouts are retried; the app would show the raw text instead.
                        guard result.warning != nil, attempt < 4 else { return (key, result, attempt) }
                        try await Task.sleep(for: .seconds(Double(attempt) * 2))
                        attempt += 1
                    }
                }
            }
            for _ in 0..<limit { enqueue() }
            while let (key, result, attempts) = try await group.next() {
                results[key] = (result, attempts)
                enqueue()
            }
        }

        for (clip, job) in zip(clips, jobs) {
            let (result, attempts) = results[requestKey(job)]!
            var record = clip
            record.removeValue(forKey: "rawWords")
            record["preRewriteText"] = job.input
            record["text"] = result.finalText
            record["rewriteMilliseconds"] = result.timings.rewriteMilliseconds
            record["rewriteAttempts"] = attempts
            record["rewriteFailure"] = result.warning?.message ?? NSNull()
            try write(record)
        }
    }

    private static func jsonLines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            guard let record = try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) as? [String: Any] else {
                throw CommandError.usage("\(url.lastPathComponent) must contain one JSON object per line")
            }
            return record
        }
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
