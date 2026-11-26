import Foundation

/// A meeting as a Markdown note: YAML front matter (title, date, duration, app, participants,
/// speakers), then one paragraph per turn. Shaped for a notes vault such as Obsidian.
public enum MeetingMarkdown {
    /// `notes`, Markdown such as `MeetingNotesFile.markdown` writes, go between the front matter and the turns, which
    /// then sit under "## Transcript".
    public static func export(_ detail: MeetingDetail, notes: String? = nil, timeZone: TimeZone = .current) -> String {
        export(title: detail.summary.title, date: detail.summary.startedAt, duration: detail.summary.duration,
               app: detail.summary.source, participants: detail.participants.all, speakers: detail.summary.speakers,
               turns: detail.turns, notes: notes, timeZone: timeZone)
    }

    public static func export(title: String, date: Date, duration: TimeInterval, app: String, participants: [String],
                              speakers: [String], turns: [TranscriptTurn], notes: String? = nil,
                              timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        var lines = ["---",
                     "title: \(yaml(title))",
                     "date: \(formatter.string(from: date))",
                     "duration: \(yaml(WordAssembly.timestamp(duration)))",
                     "app: \(yaml(app))"]
        lines += yamlList("participants", participants)
        lines += yamlList("speakers", speakers)
        lines += ["---", ""]
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines += [notes, "", "## Transcript", ""]
        }
        lines += turnLines(turns)
        return lines.joined(separator: "\n")
    }

    /// "**Name** [00:01:02]" then the turn's text and a blank line.
    static func turnLines(_ turns: [TranscriptTurn]) -> [String] {
        turns.flatMap { turn in
            ["**\(turn.speaker)** [\(WordAssembly.timestamp(turn.start))]  ",
             turn.text.replacingOccurrences(of: "\n", with: " "), ""]
        }
    }

    private static func yamlList(_ key: String, _ values: [String]) -> [String] {
        values.isEmpty ? ["\(key): []"] : ["\(key):"] + values.map { "  - \(yaml($0))" }
    }

    /// Always double-quoted, so names like "No: 1" or "- Bob" stay strings.
    static func yaml(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 { escaped += String(format: "\\x%02X", scalar.value) } else { escaped.unicodeScalars.append(scalar) }
            }
        }
        return "\"\(escaped)\""
    }
}
