import Foundation

/// Who the call app said was in the meeting, gathered from the call window while recording and kept in participants.json.
/// Zoom: tiles "<name>, Computer audio muted" and "More options for <name>"; Meet: "More options for <name>",
/// or a whole tile read as one group, "Pin <name> to your main screen … More options for <name> <name>".
/// Self is "<name> (Host, me)", Zoom's account button "Zoom, <name>, In a Zoom Meeting", or this Mac's user name.
/// A recording with the raw accessibility log (`meetingsDebugAccessibilityLog`) is re-read from that log instead,
/// so changed rules apply to old test captures.
public struct MeetingParticipants: Codable, Sendable, Hashable {
    public var all: [String] = []
    public var me: String?
    public var others: [String] { all.filter { $0.caseInsensitiveCompare(me ?? "") != .orderedSame } }

    public init(all: [String] = [], me: String? = nil) {
        self.all = all
        self.me = me
    }

    public static func read(_ directory: URL) -> MeetingParticipants {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(MeetingStorage.accessibilityFile), encoding: .utf8) else {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStorage.participantsFile)),
                  let saved = try? JSONDecoder().decode(MeetingParticipants.self, from: data) else { return MeetingParticipants() }
            return saved
        }
        return parse(text)
    }

    /// Parses accessibility.jsonl rows (`lines` of full snapshots, `added` of diffs).
    static func parse(_ text: String) -> MeetingParticipants {
        var collector = Collector()
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            collector.add(((row["lines"] as? [String]) ?? []) + ((row["added"] as? [String]) ?? []))
        }
        return collector.participants
    }

    /// Gathers names from the call window's text as it's read (`"<depth> <role>: <text>"` lines), so a recording
    /// keeps who was there without keeping the window's text.
    public struct Collector: Sendable {
        private var names: [String] = []
        private var me: String?

        public init() {}

        public mutating func add<S: Sequence>(_ entries: S) where S.Element == String {
            for entry in entries {
                guard let colon = entry.range(of: ": ") else { continue }
                let role = entry[..<colon.lowerBound]
                let value = String(entry[colon.upperBound...])
                if role.hasSuffix("AXTabGroup"), let range = value.range(of: ", Computer audio") ?? value.range(of: ", No audio connected") {
                    add(name: String(value[..<range.lowerBound]))
                }
                for part in value.components(separatedBy: " | ") {
                    if part.hasPrefix("More options for ") {
                        let name = part.dropFirst("More options for ".count).components(separatedBy: ",").first ?? ""
                        if !name.hasSuffix("Zoom Meeting"), !name.contains("'s Zoom") { add(name: name) }
                    } else if part.hasPrefix("Pin "), part.contains("More options for ") {
                        // Meet also reads a whole tile as one group ("Pin <name> to your main screen … More options for
                        // <name> <name>"). The tile's label runs on after the last name, so the name comes from the start,
                        // cut at a comma as the button's is.
                        let rest = part.dropFirst("Pin ".count)
                        guard let end = rest.range(of: " to your main screen") else { continue }
                        add(name: rest[..<end.lowerBound].components(separatedBy: ",").first ?? "")
                    }
                }
                if let range = value.range(of: " (Host, me)") ?? value.range(of: " (me)") { me = String(value[..<range.lowerBound]) }
                if value.hasPrefix("Zoom, "), value.contains(", In a Zoom Meeting") {
                    me = value.dropFirst(6).components(separatedBy: ", In a Zoom Meeting").first
                }
            }
        }

        private mutating func add(name: String) {
            // Zoom tiles can read "<name> (Host, me), Computer audio muted"; the role is not part of the name.
            let name = name.replacingOccurrences(of: "\\s\\((Host|Co-host|Guest|me|Host, me|Co-host, me)\\)$", with: "",
                                                 options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count < 80, !names.contains(name) else { return }
            names.append(name)
        }

        /// Everyone seen so far, this Mac's person first when the call never said who they were.
        public var participants: MeetingParticipants {
            var names = names
            let me = me ?? names.first { $0.caseInsensitiveCompare(NSFullUserName()) == .orderedSame }
            if let me, !names.contains(where: { $0.caseInsensitiveCompare(me) == .orderedSame }) { names.insert(me, at: 0) }
            return MeetingParticipants(all: names, me: me)
        }
    }
}
