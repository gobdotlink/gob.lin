import Foundation
import GoblinCore
import GoblinEngines

private struct FixtureEngine: SpeechEngine {
    let identifier = "synthetic-pipeline-smoke"
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(text: "Raw text stays recoverable.")
    }
}

@main
struct EvaluationSmoke {
    static func check(_ condition: Bool, _ message: String = "Evaluation smoke assertion failed") { precondition(condition, message) }

    static func main() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
        let a = try EvaluationJSONL.read(directory.appendingPathComponent("A.jsonl"))
        let b = try EvaluationJSONL.read(directory.appendingPathComponent("B.jsonl"))
        let report = try Evaluator.compare(a, b)
        check(report.alignedRecords == 2 && report.changedRecords == 2, "Compare IDs, not line ordering")
        check(report.a.wordErrors == 1 && report.b.wordErrors == 2)
        check(report.a.wordErrorRate == 0.1 && report.b.wordErrorRate == 0.2)
        check(report.a.jargonHits == 0 && report.b.jargonHits == 1 && report.b.jargonExpected == 1)
        check(report.a.ordinaryWordFalseCorrections == 0 && report.b.ordinaryWordFalseCorrections == 2, "Detect the like→Lisa and at→auth regression")
        check(report.a.latencyMilliseconds["processing"]?.p50 == 100 && report.b.latencyMilliseconds["processing"]?.p95 == 350)
        check(try WordDiff.between("", "").isEmpty)
        check(try WordDiff.between("", "new").map(\.operation) == [.insertion])
        check(try WordDiff.between("old", "").map(\.operation) == [.deletion])
        check(try WordDiff.between("Old, word!", "old word").allSatisfy { $0.operation == .equal })
        let weighted = try Evaluator.compare([
            EvaluationRecord(id: "short", rawText: "a", finalText: "b", referenceText: "a"),
            EvaluationRecord(id: "long", rawText: "a b c d", finalText: "a b c d", referenceText: "a b c d"),
        ], [
            EvaluationRecord(id: "long", rawText: "a b c d", finalText: "a b c d", referenceText: "a b c d"),
            EvaluationRecord(id: "short", rawText: "a", finalText: "b", referenceText: "a"),
        ])
        check(weighted.a.wordErrorRate == 0.2, "WER is weighted by reference word count, not averaged across clips")
        let actualCorrection = EvaluationRecord(id: "misheard", rawText: "at", finalText: "auth", referenceText: "auth", ordinaryWords: ["at"])
        check(try Evaluator.compare([actualCorrection], [actualCorrection]).b.ordinaryWordFalseCorrections == 0, "Correcting an ASR mistake is not an ordinary-word regression")
        let missing = try Evaluator.compare(a, [b[0]])
        check(missing.missingFromB == ["jargon"] && missing.alignedRecords == 1)
        do { _ = try Evaluator.compare([a[0], a[0]], b); preconditionFailure("Duplicate IDs were accepted") }
        catch EvaluationError.duplicateID { }
        var conflicting = b[1]
        conflicting.referenceText = "Different ground truth"
        do { _ = try Evaluator.compare(a, [conflicting]); preconditionFailure("Mismatched reference was accepted") }
        catch EvaluationError.mismatchedReference { }
        do { _ = try WordDiff.between([String](repeating: "word", count: 3000), [String](repeating: "word", count: 3000)); preconditionFailure("Unbounded matrix was accepted") }
        catch EvaluationError.transcriptTooLong { }
        let percentiles = LatencyPercentiles(samples: (1...100).map(Double.init))!
        check(percentiles.p50 == 50 && percentiles.p90 == 90 && percentiles.p95 == 95 && percentiles.p99 == 99)
        let withoutTruth = try Evaluator.compare([EvaluationRecord(id: "unknown", rawText: "a", finalText: "b")], [EvaluationRecord(id: "unknown", rawText: "a", finalText: "c")])
        check(withoutTruth.a.wordErrorRate == nil && withoutTruth.a.latencyMilliseconds.isEmpty)

        // Exercise only the shared boundary with explicit fixture output, never a recognizer.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-pipeline-smoke-\(UUID().uuidString).wav")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pipeline = RecordedAudioPipeline(engine: FixtureEngine()) { _ in throw EvaluationError.invalidRecord("Synthetic rewrite failure") }
        let run = try await pipeline.transcribe(file)
        check(run.rawText == run.finalText && run.postprocessingError != nil, "Rewrite failure must preserve raw text and report its error")
        check(run.timings.asrMilliseconds >= 0 && run.timings.rewriteMilliseconds >= 0)
        let processor = TranscriptPostprocessor()
        let terms = [DictionaryEntry(spelling: "Dev review", aliases: ["day review"]), DictionaryEntry(spelling: "Lisa")]
        let raw = "run day review. i like it at home"
        let processed = await processor.process(raw, dictionaryEntries: terms, tone: .formal, rewriteSettings: RewriteSettings())
        check(processed.rawText == raw && processed.finalText == "Run Dev review. I like it at home.")
        check(!processed.polished && processed.warning == nil, "Local dictionary and tone processing must not claim cloud polish")
        let invalidRewrite = RewriteSettings(enabled: true, model: "")
        let fallback = await processor.process(raw, dictionaryEntries: terms, tone: .formal, rewriteSettings: invalidRewrite)
        check(fallback.finalText == raw && fallback.rawText == raw && fallback.warning == .rewriteConfiguration,
              "Rewrite preflight failure must undo dictionary and tone edits without sending a request")
        let sharedPipeline = RecordedAudioPipeline(engine: FixtureEngine(), processor: processor, dictionaryEntries: [],
                                                  tone: .casual, rewriteSettings: invalidRewrite)
        let sharedRun = try await sharedPipeline.transcribe(file)
        check(sharedRun.rawText == sharedRun.finalText && sharedRun.postprocessingError == DiagnosticFailure.rewriteConfiguration.message)
        check(sharedRun.timings.rewriteMilliseconds >= 0)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--history-fixture" {
            let store = try HistoryStore(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            for record in a {
                try await store.insert(HistoryEntry(rawText: record.rawText, finalText: record.finalText, model: record.model ?? "fixture", latencies: record.timings ?? DictationTimings()))
            }
        }
        print("Evaluation safety smoke passed: ID alignment, word edits/WER, jargon, ordinary-word regressions, annotations, percentiles, matrix bounds, raw-text fallback.")
    }
}
