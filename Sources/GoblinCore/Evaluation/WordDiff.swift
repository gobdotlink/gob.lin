import Foundation

public enum EvaluationError: Error, LocalizedError, Sendable {
    case invalidRecord(String)
    case duplicateID(String)
    case mismatchedReference(String)
    case transcriptTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let message): "Invalid evaluation record: \(message)"
        case .duplicateID(let id): "Duplicate evaluation ID: \(id)"
        case .mismatchedReference(let id): "Ground truth differs between A and B for ID \(id)."
        case .transcriptTooLong: "A word diff exceeds the 4,000,000-cell safety limit. Split very long recordings before evaluating."
        }
    }
}

public struct WordEdit: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case equal, insertion, deletion, replacement }
    public var operation: Operation
    public var referenceWord: String?
    public var candidateWord: String?
    public var referenceIndex: Int?
    public var candidateIndex: Int?
}

public enum WordDiff {
    /// WER ignores casing and punctuation, retaining apostrophes within words.
    public static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text.lowercased().replacingOccurrences(of: "’", with: "'") {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                if !word.isEmpty { result.append(word) }
                current = ""
            }
        }
        let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if !word.isEmpty { result.append(word) }
        return result
    }

    public static func between(_ reference: String, _ candidate: String) throws -> [WordEdit] {
        try between(words(reference), words(candidate))
    }

    public static func between(_ reference: [String], _ candidate: [String]) throws -> [WordEdit] {
        let m = reference.count
        let n = candidate.count
        guard m <= 10000, n <= 10000, (m + 1) * (n + 1) <= 4_000_000 else { throw EvaluationError.transcriptTooLong }
        let columns = n + 1
        var cost = [Int32](repeating: 0, count: (m + 1) * columns)
        for i in 0...m { cost[i * columns] = Int32(i) }
        for j in 0...n { cost[j] = Int32(j) }
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    let replacement = cost[(i - 1) * columns + j - 1] + (reference[i - 1] == candidate[j - 1] ? 0 : 1)
                    cost[i * columns + j] = min(replacement, cost[(i - 1) * columns + j] + 1, cost[i * columns + j - 1] + 1)
                }
            }
        }
        var edits: [WordEdit] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == candidate[j - 1], cost[i * columns + j] == cost[(i - 1) * columns + j - 1] {
                edits.append(WordEdit(operation: .equal, referenceWord: reference[i - 1], candidateWord: candidate[j - 1], referenceIndex: i - 1, candidateIndex: j - 1))
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i * columns + j] == cost[(i - 1) * columns + j - 1] + 1 {
                edits.append(WordEdit(operation: .replacement, referenceWord: reference[i - 1], candidateWord: candidate[j - 1], referenceIndex: i - 1, candidateIndex: j - 1))
                i -= 1; j -= 1
            } else if i > 0, cost[i * columns + j] == cost[(i - 1) * columns + j] + 1 {
                edits.append(WordEdit(operation: .deletion, referenceWord: reference[i - 1], candidateWord: nil, referenceIndex: i - 1, candidateIndex: nil))
                i -= 1
            } else {
                edits.append(WordEdit(operation: .insertion, referenceWord: nil, candidateWord: candidate[j - 1], referenceIndex: nil, candidateIndex: j - 1))
                j -= 1
            }
        }
        return edits.reversed()
    }
}
