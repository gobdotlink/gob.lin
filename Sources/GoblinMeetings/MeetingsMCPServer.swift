import Foundation
import GoblinCore

/// gob.lin's MCP server: lets Claude, Codex and ChatGPT search and read your meetings. It speaks JSON-RPC over stdin
/// and stdout, one message per line, and only reads: it lists meetings, searches transcripts and notes, pages through a
/// transcript and reads notes. The app starts it as `GoblinApp mcp`, the CLI as `goblin mcp`.
public actor MeetingsMCPServer {
    public static let serverName = "goblin"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let resourceScheme = "goblin-meeting"

    let query: MeetingQuery
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    /// Why meetings can't be read right now (Meetings is off in the app), asked on every call; nil when they can.
    private let unavailable: @Sendable () -> String?

    public init(root: URL = MeetingStorage.root, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init,
                unavailable: @escaping @Sendable () -> String? = { nil }) {
        query = MeetingQuery(root: root, timeZone: timeZone)
        self.timeZone = timeZone
        self.now = now
        self.unavailable = unavailable
    }

    // MARK: Standard IO

    /// Serves on stdin and stdout until stdin closes, then exits. Anything else that writes to stdout (a stray print, a
    /// framework's log) is sent to stderr instead, since one stray line would break the protocol.
    public static func serveStandardIO(root: URL = MeetingStorage.root, unavailable: @escaping @Sendable () -> String? = { nil }) -> Never {
        let protocolOutput = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: false)
        let server = MeetingsMCPServer(root: root, unavailable: unavailable)
        Task.detached {
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    // The throwing write: the client closing its end mid-reply just ends the session.
                    if let reply = await server.handle(line: line) { try output.write(contentsOf: Data((reply + "\n").utf8)) }
                }
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("gob.lin MCP: \(error.localizedDescription)\n".utf8))
            }
            exit(0)
        }
        dispatchMain()
    }

    /// One line in, at most one line out: nil for a notification, which gets no answer.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.encode(Self.error(id: .null, code: -32700, message: "That isn't JSON."))
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for item in batch { if let reply = await handle(item) { replies.append(reply) } }
            return replies.isEmpty ? nil : Self.encode(.array(replies))
        }
        return await handle(message).map(Self.encode)
    }

    func handle(_ message: JSONValue) async -> JSONValue? {
        guard case .object = message, let method = message["method"]?.string else {
            // A response to something we never asked: nothing to say back.
            if message["id"] != nil, message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Expected a JSON-RPC request with a method.")
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] ?? .object([:])
        do {
            return ["jsonrpc": "2.0", "id": id, "result": try await result(method: method, params: params)]
        } catch let failure as RPCFailure {
            return Self.error(id: id, code: failure.code, message: failure.message)
        } catch {
            return Self.error(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    struct RPCFailure: Error {
        var code: Int
        var message: String
    }

    private func result(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            // Clients usually take a moment before their first call; reading the meetings meanwhile keeps it quick.
            if unavailable() == nil { Task.detached(priority: .utility) { [query] in await query.warm() } }
            let asked = params["protocolVersion"]?.string ?? ""
            return ["protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
                    "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false]],
                    "serverInfo": ["name": .string(Self.serverName), "title": "gob.lin meetings", "version": .string(GoblinMetadata.version)],
                    "instructions": .string(instructions)]
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(Self.tools)]
        case "tools/call":
            guard let name = params["name"]?.string else { throw RPCFailure(code: -32602, message: "tools/call needs a tool name.") }
            guard Self.tools.contains(where: { $0["name"]?.string == name }) else {
                throw RPCFailure(code: -32602, message: "There's no tool called \(name).")
            }
            if let reason = unavailable() { return Self.textResult(reason, isError: true) }
            do {
                return Self.textResult(try await call(name, params["arguments"] ?? .object([:])), isError: false)
            } catch {
                // A tool's own failure goes back as its result, so the model reads it and can try again.
                return Self.textResult(error.localizedDescription, isError: true)
            }
        case "resources/list":
            let meetings = unavailable() == nil ? await query.meetingList() : []
            return ["resources": .array(meetings.map { meeting in
                ["uri": .string(Self.resourceURI(meeting.id)), "name": .string(meeting.id), "title": .string(meeting.title),
                 "description": .string("Notes and transcript of \(meeting.title)"), "mimeType": "text/markdown"]
            })]
        case "resources/templates/list":
            return ["resourceTemplates": [["uriTemplate": .string("\(Self.resourceScheme)://{meeting_id}"), "name": "meeting",
                                           "title": "A meeting's notes and transcript", "mimeType": "text/markdown"]]]
        case "resources/read":
            guard let uri = params["uri"]?.string, let id = Self.meetingID(fromResource: uri) else {
                throw RPCFailure(code: -32602, message: "Expected a \(Self.resourceScheme):// URI.")
            }
            if let reason = unavailable() { throw RPCFailure(code: -32002, message: reason) }
            do {
                let text = try await query.document(id)
                return ["contents": [["uri": .string(uri), "mimeType": "text/markdown", "text": .string(text)]]]
            } catch {
                throw RPCFailure(code: -32002, message: error.localizedDescription)
            }
        default:
            throw RPCFailure(code: -32601, message: "gob.lin doesn't handle \(method).")
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ arguments: JSONValue) async throws -> String {
        let reader = Arguments(arguments, now: now(), timeZone: timeZone)
        try reader.check(against: Self.tools.first { $0["name"]?.string == name }?["inputSchema"])
        switch name {
        case "list_meetings":
            var options = MeetingQuery.ListOptions()
            options.since = try reader.date("since")
            options.until = try reader.date("until", endOfDay: true)
            options.query = reader.string("query")
            options.person = reader.string("person")
            options.limit = try reader.integer("limit", default: 20, range: 1...200)
            options.includeInProgress = reader.bool("include_in_progress") ?? true
            return await query.listMeetings(options)
        case "search_meetings":
            guard let text = reader.string("query") else { throw MeetingQuery.Failure.badArgument("search_meetings needs a query.") }
            var options = MeetingQuery.SearchOptions(query: text)
            options.since = try reader.date("since")
            options.until = try reader.date("until", endOfDay: true)
            options.meetingID = try reader.meetingID(required: false)
            options.speaker = reader.string("speaker")
            options.limit = try reader.integer("limit", default: 10, range: 1...50)
            options.fuzzy = reader.bool("fuzzy") ?? true
            options.includeInProgress = reader.bool("include_in_progress") ?? true
            return try await query.search(options)
        case "get_transcript":
            guard let id = try reader.meetingID(required: true) else { throw MeetingQuery.Failure.badArgument("get_transcript needs a meeting_id.") }
            var options = MeetingQuery.TranscriptOptions(meetingID: id)
            options.from = try reader.offset("from")
            options.to = try reader.offset("to")
            options.speaker = reader.string("speaker")
            options.maxCharacters = try reader.integer("max_chars", default: 20_000, range: 1_000...200_000)
            options.cursor = try reader.integer("cursor", default: 0, range: 0...Int.max)
            return try await query.transcript(options)
        case "get_notes":
            guard let id = try reader.meetingID(required: true) else { throw MeetingQuery.Failure.badArgument("get_notes needs a meeting_id.") }
            return try await query.notes(id)
        default:
            throw MeetingQuery.Failure.badArgument("There's no tool called \(name).")
        }
    }

    struct Arguments {
        let values: JSONValue
        let now: Date
        let timeZone: TimeZone

        init(_ values: JSONValue, now: Date, timeZone: TimeZone) {
            self.values = values
            self.now = now
            self.timeZone = timeZone
        }

        /// A misspelled filter or a value of the wrong kind is an error, not silently dropped: the model would read
        /// results it didn't ask for as an answer.
        func check(against schema: JSONValue?) throws {
            guard case .object(let given) = values else {
                if values == .null { return }
                throw MeetingQuery.Failure.badArgument("Arguments must be an object.")
            }
            guard case .object(let properties)? = schema?["properties"] else { return }
            for (key, value) in given {
                guard let type = properties[key]?["type"]?.string else {
                    throw MeetingQuery.Failure.badArgument("Unknown argument \(key). This tool takes \(properties.keys.sorted().joined(separator: ", ")).")
                }
                if value == .null { continue }
                let fits: Bool = switch (type, value) {
                case ("string", .string), ("string", .number): true
                case ("integer", .number), ("integer", .string): value.number.map { $0.rounded() == $0 } ?? false
                case ("boolean", .bool): true
                case ("boolean", .string): bool(key) != nil
                default: false
                }
                if !fits { throw MeetingQuery.Failure.badArgument("\(key) must be a \(type == "integer" ? "whole number" : type).") }
            }
        }

        /// meeting_id as given, not trimmed (an ID can end in a space); a blank one is an error, not "every meeting".
        func meetingID(required: Bool) throws -> String? {
            guard let value = values["meeting_id"], value != .null else { return nil }
            guard let id = value.string, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MeetingQuery.Failure.badArgument("meeting_id is empty. Use an id from list_meetings or search_meetings.")
            }
            return id
        }

        func string(_ key: String) -> String? {
            let text: String? = switch values[key] {
            case .string(let value): value
            case .number(let value): Int(exactly: value).map(String.init) ?? String(value)
            default: nil
            }
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return text.trimmingCharacters(in: .whitespaces)
        }

        func bool(_ key: String) -> Bool? {
            if let value = values[key]?.bool { return value }
            switch values[key]?.string?.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }

        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = values[key], value != .null else { return fallback }
            guard let number = value.number, number.isFinite else {
                throw MeetingQuery.Failure.badArgument("\(key) must be a whole number.")
            }
            // Clamped as a Double first, so no value can trap on the way to Int.
            let clamped = min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound))
            return Int(exactly: clamped) ?? (clamped > 0 ? range.upperBound : range.lowerBound)
        }

        func date(_ key: String, endOfDay: Bool = false) throws -> Date? {
            guard let text = string(key) else { return nil }
            guard let date = MeetingQuery.parseDate(text, endOfDay: endOfDay, now: now, timeZone: timeZone) else {
                throw MeetingQuery.Failure.badArgument("\(key): I can't read “\(text)” as a time. Use a date like 2026-11-20, a date and time like 2026-11-20T14:00, today, yesterday, or an age like 7d or 36h.")
            }
            return date
        }

        func offset(_ key: String) throws -> Double? {
            guard let text = string(key) else { return nil }
            guard let seconds = MeetingQuery.parseOffset(text) else {
                throw MeetingQuery.Failure.badArgument("\(key): I can't read “\(text)” as a time in the meeting. Use 12:30, 1:02:03 or seconds.")
            }
            return seconds
        }
    }

    private var instructions: String {
        """
        gob.lin records meetings on this Mac and transcribes them locally. These tools read them; nothing here records, \
        changes or deletes anything.

        - In a call, "You" is the person who recorded it, on their microphone. Other voices carry the names given in \
        gob.lin, or "Speaker 2" and so on until someone names them. A call still recording only knows You and Them; a \
        conversation in the room still recording is all "Room". The speaker filter takes a name, You, or Them for \
        everyone else.
        - Transcripts come from speech recognition, so names and rare words can be misheard. search_meetings matches \
        near-misses and word forms; try a different spelling if a name turns up nothing.
        - Start with search_meetings for a topic, or list_meetings for a time or a person. Then read around a hit with \
        get_transcript using from/to (a few minutes either side), or read get_notes for the summary, decisions and \
        action items. Long transcripts come in pages: pass the cursor it gives you.
        - Times inside a meeting are from its start (00:12:34). Dates are in \(timeZone.identifier); now is \
        \(ISO8601DateFormatter.string(from: now(), timeZone: timeZone, formatOptions: [.withInternetDateTime])).
        - Quote a meeting's time when you use what was said, so the person can find it in gob.lin.
        """
    }

    static let readOnly: JSONValue = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]

    static let sinceProperty: JSONValue = ["type": "string",
                                           "description": "Only meetings from this time on: an ISO date (2026-11-20) or date-time, today, yesterday, or an age like 7d, 36h, 2w."]
    static let untilProperty: JSONValue = ["type": "string",
                                           "description": "Only meetings before this time. A bare date includes that whole day."]

    static let tools: [JSONValue] = [
        ["name": "list_meetings",
         "title": "List meetings",
         "description": "Lists recorded meetings, newest first: title, meeting_id, date, length, the call app, who spoke and whether notes exist. Filter by time, by words in the title or names, or by a person.",
         "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
            "since": sinceProperty,
            "until": untilProperty,
            "query": ["type": "string", "description": "Words that must all appear in the title, the call app or a name."],
            "person": ["type": "string", "description": "Only meetings where this person spoke or was on the call."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20],
            "include_in_progress": ["type": "boolean", "default": true, "description": "Include meetings still recording or processing."],
         ]],
         "annotations": readOnly],
        ["name": "search_meetings",
         "title": "Search meetings",
         "description": "Searches what was said in meetings, and their notes, for words or \"quoted phrases\". Returns the best passages with the meeting, the time, the speaker and the lines either side. Tolerates misheard spellings and word forms.",
         "inputSchema": ["type": "object", "additionalProperties": false, "required": ["query"], "properties": [
            "query": ["type": "string", "description": "Words to find; any may match, and passages with more of them rank higher. Put a phrase in double quotes to require it as written."],
            "since": sinceProperty,
            "until": untilProperty,
            "meeting_id": ["type": "string", "description": "Search only this meeting."],
            "speaker": ["type": "string", "description": "Only lines this speaker said: a name, You, or Them for everyone but you."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
            "fuzzy": ["type": "boolean", "default": true, "description": "Also match words a letter or two off."],
            "include_in_progress": ["type": "boolean", "default": true],
         ]],
         "annotations": readOnly],
        ["name": "get_transcript",
         "title": "Read a transcript",
         "description": "Reads a meeting's transcript as timed, named lines, optionally for a time range or one speaker. Long transcripts come in pages: when more remains, the answer ends with the cursor to pass next.",
         "inputSchema": ["type": "object", "additionalProperties": false, "required": ["meeting_id"], "properties": [
            "meeting_id": ["type": "string", "description": "From list_meetings or search_meetings."],
            "from": ["type": "string", "description": "Start time in the meeting: 12:30, 1:02:03 or seconds."],
            "to": ["type": "string", "description": "End time in the meeting."],
            "speaker": ["type": "string", "description": "Only this speaker's lines: a name, You, or Them."],
            "max_chars": ["type": "integer", "minimum": 1000, "maximum": 200000, "default": 20000],
            "cursor": ["type": "integer", "minimum": 0, "description": "The cursor a previous page gave."],
         ]],
         "annotations": readOnly],
        ["name": "get_notes",
         "title": "Read meeting notes",
         "description": "Reads a meeting's notes as gob.lin stored them: the summary, decisions, action items with owners, the template's sections, anything typed during the meeting, and marked moments, each with its time. Never writes notes; says so when there are none.",
         "inputSchema": ["type": "object", "additionalProperties": false, "required": ["meeting_id"], "properties": [
            "meeting_id": ["type": "string", "description": "From list_meetings or search_meetings."],
         ]],
         "annotations": readOnly],
    ]

    // MARK: Encoding

    static func textResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Never pretty-printed: each message must be one line.
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Couldn't encode the answer."}}"#
    }

    static let resourceAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func resourceURI(_ id: String) -> String {
        "\(resourceScheme)://" + (id.addingPercentEncoding(withAllowedCharacters: resourceAllowed) ?? id)
    }

    static func meetingID(fromResource uri: String) -> String? {
        let prefix = "\(resourceScheme)://"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count)).removingPercentEncoding ?? ""
        return id.isEmpty ? nil : id
    }
}
