import Foundation

public struct EvaluationRecord: Codable, Sendable {
    public var id: String
    public var rawText: String
    public var finalText: String
    public var referenceText: String?
    public var jargon: [String]
    public var ordinaryWords: [String]
    public var model: String?
    public var source: String
    public var timings: DictationTimings?
    public var postprocessingError: String?

    public init(id: String, rawText: String, finalText: String, referenceText: String? = nil,
                jargon: [String] = [], ordinaryWords: [String] = [], model: String? = nil,
                source: String = "recorded_transcript", timings: DictationTimings? = nil, postprocessingError: String? = nil) {
        self.id = id; self.rawText = rawText; self.finalText = finalText
        self.referenceText = referenceText; self.jargon = jargon; self.ordinaryWords = ordinaryWords
        self.model = model; self.source = source; self.timings = timings
        self.postprocessingError = postprocessingError
    }

    private enum CodingKeys: String, CodingKey { case id, rawText, finalText, referenceText, jargon, ordinaryWords, model, source, timings, postprocessingError }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(String.self, forKey: .id),
                  rawText: try fields.decode(String.self, forKey: .rawText),
                  finalText: try fields.decode(String.self, forKey: .finalText),
                  referenceText: try fields.decodeIfPresent(String.self, forKey: .referenceText),
                  jargon: try fields.decodeIfPresent([String].self, forKey: .jargon) ?? [],
                  ordinaryWords: try fields.decodeIfPresent([String].self, forKey: .ordinaryWords) ?? [],
                  model: try fields.decodeIfPresent(String.self, forKey: .model),
                  source: try fields.decodeIfPresent(String.self, forKey: .source) ?? "recorded_transcript",
                  timings: try fields.decodeIfPresent(DictationTimings.self, forKey: .timings),
                  postprocessingError: try fields.decodeIfPresent(String.self, forKey: .postprocessingError))
    }
}

public struct LatencyPercentiles: Codable, Sendable {
    public var count: Int
    public var p50: Double
    public var p90: Double
    public var p95: Double
    public var p99: Double

    public init?(samples: [Double]) {
        let sorted = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        func percentile(_ quantile: Double) -> Double { sorted[max(0, Int(ceil(quantile * Double(sorted.count))) - 1)] }
        self.count = sorted.count; self.p50 = percentile(0.5); self.p90 = percentile(0.9)
        self.p95 = percentile(0.95); self.p99 = percentile(0.99)
    }
}

public struct OrdinaryWordCorrection: Codable, Sendable, Equatable {
    public var rawWordIndex: Int
    public var original: String
    public var replacement: String?
}

public struct EvaluationSummary: Codable, Sendable {
    public var referenceRecords = 0
    public var referenceWords = 0
    public var wordErrors = 0
    public var wordErrorRate: Double? { referenceWords > 0 ? Double(wordErrors) / Double(referenceWords) : nil }
    public var jargonExpected = 0
    public var jargonHits = 0
    public var ordinaryWordFalseCorrections = 0
    public var jargonAnnotatedRecords = 0
    public var ordinaryWordAnnotatedRecords = 0
    public var latencyMilliseconds: [String: LatencyPercentiles] = [:]

    private enum CodingKeys: String, CodingKey {
        case referenceRecords, referenceWords, wordErrors, wordErrorRate, jargonExpected, jargonHits, ordinaryWordFalseCorrections, jargonAnnotatedRecords, ordinaryWordAnnotatedRecords, latencyMilliseconds
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(referenceRecords, forKey: .referenceRecords)
        try fields.encode(referenceWords, forKey: .referenceWords)
        try fields.encode(wordErrors, forKey: .wordErrors)
        try fields.encodeIfPresent(wordErrorRate, forKey: .wordErrorRate)
        try fields.encode(jargonExpected, forKey: .jargonExpected)
        try fields.encode(jargonHits, forKey: .jargonHits)
        try fields.encode(ordinaryWordFalseCorrections, forKey: .ordinaryWordFalseCorrections)
        try fields.encode(jargonAnnotatedRecords, forKey: .jargonAnnotatedRecords)
        try fields.encode(ordinaryWordAnnotatedRecords, forKey: .ordinaryWordAnnotatedRecords)
        try fields.encode(latencyMilliseconds, forKey: .latencyMilliseconds)
    }
    public init() { }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        referenceRecords = try fields.decode(Int.self, forKey: .referenceRecords)
        referenceWords = try fields.decode(Int.self, forKey: .referenceWords)
        wordErrors = try fields.decode(Int.self, forKey: .wordErrors)
        jargonExpected = try fields.decode(Int.self, forKey: .jargonExpected)
        jargonHits = try fields.decode(Int.self, forKey: .jargonHits)
        ordinaryWordFalseCorrections = try fields.decode(Int.self, forKey: .ordinaryWordFalseCorrections)
        jargonAnnotatedRecords = try fields.decode(Int.self, forKey: .jargonAnnotatedRecords)
        ordinaryWordAnnotatedRecords = try fields.decode(Int.self, forKey: .ordinaryWordAnnotatedRecords)
        latencyMilliseconds = try fields.decode([String: LatencyPercentiles].self, forKey: .latencyMilliseconds)
    }
}

public struct RecordComparison: Codable, Sendable {
    public var id: String
    public var wordDiff: [WordEdit]
    public var aFalseCorrections: [OrdinaryWordCorrection]
    public var bFalseCorrections: [OrdinaryWordCorrection]
}

public struct EvaluationReport: Codable, Sendable {
    public var alignedRecords: Int
    public var changedRecords: Int
    public var missingFromA: [String]
    public var missingFromB: [String]
    public var a: EvaluationSummary
    public var b: EvaluationSummary
    public var records: [RecordComparison]
}

public enum Evaluator {
    public static func validate(_ records: [EvaluationRecord]) throws { _ = try index(records) }
    public static func compare(_ a: [EvaluationRecord], _ b: [EvaluationRecord]) throws -> EvaluationReport {
        let left = try index(a)
        let right = try index(b)
        let ids = Set(left.keys).intersection(right.keys).sorted()
        var aSummary = EvaluationSummary()
        var bSummary = EvaluationSummary()
        var comparisons: [RecordComparison] = []
        for id in ids {
            let baseline = left[id]!
            let candidate = right[id]!
            if let referenceA = baseline.referenceText, let referenceB = candidate.referenceText, referenceA != referenceB {
                throw EvaluationError.mismatchedReference(id)
            }
            let reference = baseline.referenceText ?? candidate.referenceText
            let jargon = Set(baseline.jargon + candidate.jargon)
            let ordinary = Set((baseline.ordinaryWords + candidate.ordinaryWords).map { WordDiff.words($0).first ?? "" })
            let aFalse = try accumulate(baseline, reference: reference, jargon: jargon, ordinary: ordinary, summary: &aSummary)
            let bFalse = try accumulate(candidate, reference: reference, jargon: jargon, ordinary: ordinary, summary: &bSummary)
            comparisons.append(RecordComparison(id: id, wordDiff: try WordDiff.between(baseline.finalText, candidate.finalText),
                                                aFalseCorrections: aFalse, bFalseCorrections: bFalse))
        }
        aSummary.latencyMilliseconds = latency(ids.compactMap { left[$0]?.timings })
        bSummary.latencyMilliseconds = latency(ids.compactMap { right[$0]?.timings })
        return EvaluationReport(alignedRecords: ids.count,
                                changedRecords: comparisons.filter { $0.wordDiff.contains(where: { $0.operation != .equal }) }.count,
                                missingFromA: Set(right.keys).subtracting(left.keys).sorted(),
                                missingFromB: Set(left.keys).subtracting(right.keys).sorted(),
                                a: aSummary, b: bSummary, records: comparisons)
    }

    private static func index(_ records: [EvaluationRecord]) throws -> [String: EvaluationRecord] {
        var result: [String: EvaluationRecord] = [:]
        for record in records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EvaluationError.invalidRecord("ID is empty") }
            for ordinary in record.ordinaryWords where WordDiff.words(ordinary).count != 1 {
                throw EvaluationError.invalidRecord("ordinaryWords annotations must contain individual words")
            }
            if let timings = record.timings {
                let values = [timings.captureMilliseconds, timings.trimMilliseconds, timings.asrMilliseconds,
                              timings.rewriteMilliseconds, timings.insertionMilliseconds]
                guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), timings.processingMilliseconds.isFinite else { throw EvaluationError.invalidRecord("timings must be finite, nonnegative milliseconds") }
            }
            guard result.updateValue(record, forKey: record.id) == nil else { throw EvaluationError.duplicateID(record.id) }
        }
        return result
    }

    private static func accumulate(_ record: EvaluationRecord, reference: String?, jargon: Set<String>, ordinary: Set<String>,
                                   summary: inout EvaluationSummary) throws -> [OrdinaryWordCorrection] {
        guard let reference else { return [] }
        summary.referenceRecords += 1
        if !jargon.isEmpty { summary.jargonAnnotatedRecords += 1 }
        if !ordinary.isEmpty { summary.ordinaryWordAnnotatedRecords += 1 }
        let referenceWords = WordDiff.words(reference)
        let finalWords = WordDiff.words(record.finalText)
        summary.referenceWords += referenceWords.count
        summary.wordErrors += try WordDiff.between(referenceWords, finalWords).filter { $0.operation != .equal }.count
        for term in jargon {
            let phrase = WordDiff.words(term)
            let expected = occurrences(phrase, in: referenceWords)
            summary.jargonExpected += expected
            summary.jargonHits += min(expected, occurrences(phrase, in: finalWords))
        }
        let rawWords = WordDiff.words(record.rawText)
        let correctRawIndices = Set(try WordDiff.between(rawWords, referenceWords).filter { $0.operation == .equal }.compactMap(\.referenceIndex))
        let changes = try WordDiff.between(rawWords, finalWords).compactMap { edit -> OrdinaryWordCorrection? in
            guard edit.operation == .replacement || edit.operation == .deletion,
                  let index = edit.referenceIndex, let original = edit.referenceWord,
                  ordinary.contains(original), correctRawIndices.contains(index) else { return nil }
            return OrdinaryWordCorrection(rawWordIndex: index, original: original, replacement: edit.candidateWord)
        }
        summary.ordinaryWordFalseCorrections += changes.count
        return changes
    }

    private static func occurrences(_ phrase: [String], in words: [String]) -> Int {
        guard !phrase.isEmpty, words.count >= phrase.count else { return 0 }
        return (0...(words.count - phrase.count)).filter { Array(words[$0..<($0 + phrase.count)]) == phrase }.count
    }

    private static func latency(_ timings: [DictationTimings]) -> [String: LatencyPercentiles] {
        let stages: [(String, KeyPath<DictationTimings, Double>)] = [
            ("capture", \.captureMilliseconds), ("trim", \.trimMilliseconds), ("asr", \.asrMilliseconds),
            ("rewrite", \.rewriteMilliseconds), ("insertion", \.insertionMilliseconds), ("processing", \.processingMilliseconds),
        ]
        return Dictionary(uniqueKeysWithValues: stages.compactMap { name, field in
            LatencyPercentiles(samples: timings.map { $0[keyPath: field] }).map { (name, $0) }
        })
    }
}
