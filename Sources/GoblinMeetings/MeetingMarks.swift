import Foundation

/// A moment someone marked during a call: Mark This in the Sidekick, the popover or ⌃⌥M.
public struct MeetingMark: Codable, Sendable, Hashable {
    /// Seconds from the session start.
    public var t: Double
    /// What it was about, if they labelled it; they can label it later.
    public var label: String?

    public init(t: Double, label: String? = nil) {
        self.t = t
        self.label = label
    }
}

/// `marks.jsonl` in a meeting folder. The file is small, so a change rewrites it whole and atomically:
/// a label added later replaces its line instead of appending a second one.
public enum MeetingMarks {
    public static func url(in directory: URL) -> URL { directory.appendingPathComponent(MeetingStorage.marksFile) }

    /// The marks in time order. A missing file is no marks; an unreadable line is skipped.
    public static func read(from directory: URL) -> [MeetingMark] { MeetingMark.read(directory) }

    /// Writes every mark, in time order. Blank labels are left out, so "label it later" stays unlabelled.
    public static func write(_ marks: [MeetingMark], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try marks.sorted { $0.t < $1.t }.map { mark -> String in
            var mark = mark
            mark.t = (mark.t * 100).rounded() / 100
            let label = mark.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            mark.label = label?.isEmpty == false ? label : nil
            return String(decoding: try encoder.encode(mark), as: UTF8.self)
        }
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url(in: directory), options: .atomic)
    }
}
