import Foundation

public enum EvaluationJSONL {
    public static func read(_ url: URL) throws -> [EvaluationRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 64 * 1024 * 1024 else { throw EvaluationError.invalidRecord("JSONL exceeds the 64 MiB input limit") }
        }
        guard var text = String(data: data, encoding: .utf8) else { throw EvaluationError.invalidRecord("JSONL must be UTF-8") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var records: [EvaluationRecord] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            do { records.append(try JSONDecoder().decode(EvaluationRecord.self, from: Data(trimmed.utf8))) }
            catch { throw EvaluationError.invalidRecord("\(url.lastPathComponent), line \(index + 1): \(error.localizedDescription)") }
        }
        try Evaluator.validate(records)
        return records
    }

    public static func encode(_ record: EvaluationRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }
}
