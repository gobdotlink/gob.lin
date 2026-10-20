import ArgmaxCore
import CoreML
import Foundation
import GoblinCore
@preconcurrency import WhisperKit

enum WhisperDictionary {
    static let tokenLimit = (Constants.maxTokenContext / 2) - 1

    struct Prompt {
        let tokens: [Int]
        let usage: SpeechDictionaryUsage
    }

    static func prompt(terms: [String], encode: (String) -> [Int]) throws -> Prompt {
        let ordered = try DictionaryRepository.validated(terms.map { DictionaryEntry(spelling: $0) })
            .map(\.spelling).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var included: [String] = []
        var tokens: [Int] = []
        for term in ordered {
            let candidate = included + [term]
            let encoded = encode(" " + candidate.joined(separator: ", "))
            guard encoded.count <= tokenLimit else { break }
            included = candidate
            tokens = encoded
        }
        return Prompt(tokens: tokens, usage: SpeechDictionaryUsage(included: included,
            excluded: Array(ordered.dropFirst(included.count)), tokenCount: tokens.count, tokenLimit: tokenLimit))
    }
}

/// The decoder strips its vocabulary prefix from text but retains it in the alignment cache.
struct WhisperDictionarySegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                 currentSeek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
                                 specialToken: Int, tokenizer: any WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(decodingResult: decodingResult, options: options, allSegmentsCount: allSegmentsCount,
            currentSeek: currentSeek, segmentSize: segmentSize, sampleRate: sampleRate, timeToken: timeToken,
            specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
                           tokenizer: any WhisperTokenizer, seek: Int, segmentSize: Int, prependPunctuations: String,
                           appendPunctuations: String, lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        let retained = Array((options.promptTokens ?? []).suffix(WhisperDictionary.tokenLimit))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        let offset = retained.isEmpty ? 0 : retained.count + 1
        let weights = try Self.alignmentView(alignmentWeights, dropping: offset)
        return try withExtendedLifetime(alignmentWeights) {
            try base.addWordTimestamps(segments: segments, alignmentWeights: weights, tokenizer: tokenizer,
                seek: seek, segmentSize: segmentSize, prependPunctuations: prependPunctuations,
                appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp,
                options: options, timings: timings)
        }
    }

    static func alignmentView(_ weights: MLMultiArray, dropping rows: Int) throws -> MLMultiArray {
        guard rows > 0 else { return weights }
        guard weights.shape.count == 2, rows < weights.shape[0].intValue else {
            throw WhisperError.segmentingFailed("Dictionary prompt exceeds the alignment cache")
        }
        let bytes: Int
        switch weights.dataType {
        case .float16: bytes = 2
        case .float32: bytes = 4
        case .double: bytes = 8
        default: throw WhisperError.segmentingFailed("Unsupported alignment data type")
        }
        return try MLMultiArray(dataPointer: weights.dataPointer.advanced(by: rows * weights.strides[0].intValue * bytes),
            shape: [NSNumber(value: weights.shape[0].intValue - rows), weights.shape[1]],
            dataType: weights.dataType, strides: weights.strides, deallocator: nil)
    }
}
