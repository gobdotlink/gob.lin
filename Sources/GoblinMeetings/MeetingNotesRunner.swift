import Foundation

/// One request to a notes model: gob.lin's instructions, the meeting as input, and the JSON schema the answer must
/// match.
public struct NotesModelRequest: Sendable {
    public var instructions: String
    public var input: String
    public var schema: Data
    /// Nil: the tool's own default model.
    public var model: String?
    /// Nil: the model's own default thinking level.
    public var effort: String?
    public var timeout: TimeInterval
    /// Asked right before the meeting is handed to the tool, after everything slow before it (finding MCP servers,
    /// starting the tool). False stops there with `CancellationError`: the person turned notes off meanwhile.
    public var proceed: @Sendable () async -> Bool = { true }

    public init(instructions: String, input: String, schema: Data = MeetingNotesPrompt.schemaData, model: String? = nil,
                effort: String? = nil, timeout: TimeInterval = 600) {
        self.instructions = instructions
        self.input = input
        self.schema = schema
        self.model = model
        self.effort = effort
        self.timeout = timeout
    }
}

/// Runs a notes request and returns the answer's JSON object.
public typealias NotesModelRunner = @Sendable (NotesModelRequest) async throws -> Data

/// A model a tool offers for notes, with the thinking levels it takes.
public struct NotesModelOption: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var efforts: [String]
    public var defaultEffort: String?
    /// The tool's own default model.
    public var isDefault: Bool

    public init(id: String, title: String, efforts: [String], defaultEffort: String?, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }
}

/// A tool found on this Mac.
public struct NotesToolInstall: Sendable, Equatable {
    public var tool: NotesTool
    public var executable: URL
    public var version: String?
    public var signedIn: Bool
    /// How it's signed in, in words for Settings ("ChatGPT", "your Claude plan", "an API key"). Never an account name.
    public var signIn: String?

    public init(tool: NotesTool, executable: URL, version: String?, signedIn: Bool, signIn: String?) {
        self.tool = tool
        self.executable = executable
        self.version = version
        self.signedIn = signedIn
        self.signIn = signIn
    }
}

/// Finds Codex and Claude Code where people install them, and the PATH they need to run: both are scripts that find
/// their runtime on PATH, which an app started from the Dock doesn't have.
public enum NotesTools {
    /// The login shell's PATH, read once.
    public static func searchPath() async -> String {
        await PathCache.shared.path()
    }

    /// The tool, its version and whether it's signed in; nil when it isn't installed.
    public static func find(_ tool: NotesTool) async -> NotesToolInstall? {
        let path = await searchPath()
        guard let executable = locate(tool.command, path: path) else { return nil }
        let environment = environment(path: path, executable: executable)
        let version = try? await ToolProcess.run(executable, ["--version"], environment: environment, timeout: 15)
        let versionText = version.flatMap { String(data: $0.stdout, encoding: .utf8) }?
            .split(separator: "\n").first.map { String($0).replacingOccurrences(of: "codex-cli ", with: "")
                .replacingOccurrences(of: " (Claude Code)", with: "").trimmingCharacters(in: .whitespaces) }
        var signedIn = false
        var signIn: String?
        switch tool {
        case .codex:
            if let status = try? await ToolProcess.run(executable, ["login", "status"], environment: environment, timeout: 15) {
                // "Logged in using ChatGPT" / "Logged in using an API key" / "Not logged in", on stdout or stderr.
                let text = (String(data: status.stdout + status.stderr, encoding: .utf8) ?? "")
                signedIn = status.status == 0 && text.contains("Logged in")
                if text.contains("ChatGPT") { signIn = "ChatGPT" } else if text.localizedCaseInsensitiveContains("API key") { signIn = "an API key" }
            }
        case .claudeCode:
            if let status = try? await ToolProcess.run(executable, ["auth", "status"], environment: environment, timeout: 15),
               let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any] {
                signedIn = object["loggedIn"] as? Bool ?? false
                switch object["authMethod"] as? String {
                case "claude.ai": signIn = "your Claude plan"
                case .some(let method) where method.localizedCaseInsensitiveContains("key"): signIn = "an API key"
                default: break
                }
            }
        }
        return NotesToolInstall(tool: tool, executable: executable, version: versionText, signedIn: signedIn, signIn: signIn)
    }

    /// The models the tool offers: Codex lists its own; Claude Code takes the family names, which follow its latest
    /// models. Fable at low thinking is Claude Code's pick for notes, so choosing Claude Code starts there.
    public static func models(_ install: NotesToolInstall) async throws -> [NotesModelOption] {
        switch install.tool {
        case .codex:
            return try await CodexAppServer.models(install)
        case .claudeCode:
            let efforts = ["low", "medium", "high", "xhigh", "max"]
            return [NotesModelOption(id: "fable", title: "Fable", efforts: efforts, defaultEffort: "low", isDefault: true),
                    NotesModelOption(id: "opus", title: "Opus", efforts: efforts, defaultEffort: nil),
                    NotesModelOption(id: "sonnet", title: "Sonnet", efforts: efforts, defaultEffort: nil),
                    NotesModelOption(id: "haiku", title: "Haiku", efforts: efforts, defaultEffort: nil)]
        }
    }

    /// The runner for an installed tool.
    public static func runner(_ install: NotesToolInstall) -> NotesModelRunner {
        switch install.tool {
        case .codex: return { request in try await CodexAppServer.complete(request, install: install) }
        case .claudeCode: return { request in try await ClaudeCodeCLI.complete(request, install: install) }
        }
    }

    // MARK: Finding

    /// Where installers put these tools, searched after PATH.
    static func candidateDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [".local/bin", ".npm-global/bin", ".claude/local", ".bun/bin", ".volta/bin", ".yarn/bin", "Library/pnpm", ".cargo/bin"]
            .map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    static func locate(_ command: String, path: String) -> URL? {
        let directories = path.split(separator: ":").map(String.init) + candidateDirectories()
        for directory in directories where !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.resolvingSymlinksInPath() }
        }
        return nil
    }

    /// This process's environment with the login shell's PATH, the tool's own folder first.
    static func environment(path: String, executable: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let own = executable.deletingLastPathComponent().path
        var parts = [own] + path.split(separator: ":").map(String.init) + candidateDirectories() + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        parts = parts.filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = parts.joined(separator: ":")
        // A key in gob.lin's own environment (from a terminal launch) would bill that key instead of the person's
        // sign-in; the tools pick their own credentials.
        // Likewise a token or another endpoint: the notes go to the tool's maker under the person's own sign-in.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    actor PathCache {
        static let shared = PathCache()
        private var cached: String?

        func path() async -> String {
            if let cached { return cached }
            let found = await Self.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            cached = found
            return found
        }

        /// Asks the person's shell, as Terminal would start it, for PATH. Bounded: a slow or chatty shell profile
        /// can't hold notes up, it just leaves the fallback directories.
        static func loginShellPath() async -> String? {
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let marker = "__GOBLIN_PATH__"
            guard let result = try? await ToolProcess.run(URL(fileURLWithPath: shell), ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""],
                                                         environment: ProcessInfo.processInfo.environment, timeout: 5),
                  let text = String(data: result.stdout, encoding: .utf8),
                  let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
            let path = String(line.dropFirst(marker.count))
            return path.isEmpty ? nil : path
        }
    }

    /// A private, empty folder for one run: the tools work in it, so they see nothing of the person's files there.
    static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gob.lin-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// The last line of a tool's error output, trimmed, for a failure message. Only stderr: stdout can hold the notes
    /// and so the meeting.
    static func errorLine(_ stderr: Data) -> String? {
        let lines = (String(data: stderr, encoding: .utf8) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last.map { String($0.prefix(240)) }
    }
}

// MARK: Claude Code

/// `claude -p` with no tools, no MCP servers, no settings, hooks or saved session, in an empty folder. The meeting
/// goes in on stdin; the answer comes back as `structured_output`. Uses the unmodified Claude Code the person
/// installed and signed in to.
enum ClaudeCodeCLI {
    static func arguments(_ request: NotesModelRequest) -> [String] {
        var arguments = ["-p", "--safe-mode", "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                         "--no-session-persistence", "--disable-slash-commands", "--output-format", "json",
                         "--json-schema", String(decoding: request.schema, as: UTF8.self),
                         "--system-prompt", request.instructions]
        if let model = request.model { arguments += ["--model", model] }
        if let effort = request.effort { arguments += ["--effort", effort] }
        return arguments
    }

    static func complete(_ request: NotesModelRequest, install: NotesToolInstall) async throws -> Data {
        let scratch = try NotesTools.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = await NotesTools.searchPath()
        let result: ToolProcess.Result
        do {
            guard await request.proceed() else { throw CancellationError() }
            result = try await ToolProcess.run(install.executable, arguments(request), stdin: Data(request.input.utf8),
                                               environment: NotesTools.environment(path: path, executable: install.executable),
                                               directory: scratch, timeout: request.timeout)
        } catch ToolProcess.Failure.timedOut {
            throw MeetingNotesError.timedOut(.claudeCode)
        }
        return try answer(result)
    }

    /// The structured answer from `--output-format json`'s result object.
    static func answer(_ result: ToolProcess.Result) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw MeetingNotesError.failed(.claudeCode, NotesTools.errorLine(result.stderr) ?? "it stopped without answering (exit \(result.status)).")
        }
        if object["is_error"] as? Bool == true || (object["subtype"] as? String).map({ $0 != "success" }) == true {
            // An error result's text is Claude Code's message (a usage limit, a sign-in problem), not the notes.
            let message = (object["result"] as? String).map { String($0.prefix(240)) }
                ?? (object["subtype"] as? String) ?? "it stopped without answering."
            if message.localizedCaseInsensitiveContains("log in") || message.localizedCaseInsensitiveContains("login") {
                throw MeetingNotesError.signedOut(.claudeCode)
            }
            throw MeetingNotesError.failed(.claudeCode, message)
        }
        if let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return data
        }
        // Older versions put the JSON in the result text.
        if let text = object["result"] as? String, let data = MeetingNotesJSON.object(in: text) { return data }
        throw MeetingNotesError.unreadableAnswer
    }
}

// MARK: Codex

/// `codex app-server` over stdio for one request: a throwaway thread in an empty folder, read-only, never asking for
/// approval, on OpenAI, with Codex's tools, the person's MCP servers and web search turned off, and the answer held to the schema. Uses the
/// Codex the person installed and signed in to.
enum CodexAppServer {
    /// Features that give the model tools or reach outside the conversation. Set to false by config key, which a
    /// Codex that doesn't know a name ignores (`--disable` would refuse to start).
    static let disabledFeatures = ["shell_tool", "unified_exec", "unified_exec_tty", "view_image", "apps", "plugins", "remote_plugin",
                                   "plugin_sharing", "multi_agent", "image_generation", "browser_use", "browser_use_external",
                                   "browser_use_full_cdp_access", "computer_use", "goals", "sleep_tool", "tool_suggest", "skill_search",
                                   "in_app_browser", "in_app_local_automation", "realtime_conversation", "hooks", "code_mode_host",
                                   "code_mode_interrupt", "shell_snapshot", "worktrees", "web_search_request"]

    /// `mcpServers` are the MCP servers the person's Codex config names. An empty `mcp_servers` table merges with
    /// theirs rather than replacing it, so each one is turned off by name; naming one that isn't configured would
    /// stop Codex from loading its config at all. The provider is pinned to OpenAI, whatever the config chooses,
    /// since that's where the person agreed to send transcripts.
    static func arguments(mcpServers: [String]) -> [String] {
        var arguments = ["app-server"]
        arguments += isolation(mcpServers: mcpServers)
        for setting in [#"web_search="disabled""#, "notify=[]", "include_environment_context=false",
                        "include_permissions_instructions=false", "include_apps_instructions=false"] {
            arguments += ["-c", setting]
        }
        return arguments
    }

    static func isolation(mcpServers: [String]) -> [String] {
        var arguments = ["-c", #"model_provider="openai""#]
        for feature in disabledFeatures { arguments += ["-c", "features.\(feature)=false"] }
        for server in mcpServers { arguments += ["-c", "mcp_servers.\(tomlKey(server)).enabled=false"] }
        return arguments
    }

    /// The MCP servers Codex itself reads from the person's config (`codex mcp list --json`), every form of TOML
    /// included; then checks, with them turned off, that none is still enabled. Throws rather than run with one on.
    static func mcpServersTurnedOff(_ install: NotesToolInstall, directory: URL) async throws -> [String] {
        let environment = NotesTools.environment(path: await NotesTools.searchPath(), executable: install.executable)
        // Listed with plugins and apps already off, since servers they bring can't be turned off by name.
        func list(_ servers: [String]) async throws -> [(name: String, enabled: Bool)] {
            let extra = isolation(mcpServers: servers)
            let result = try await ToolProcess.run(install.executable, ["mcp", "list", "--json"] + extra, environment: environment,
                                                   directory: directory, timeout: 30)
            guard result.status == 0, let entries = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
                throw MeetingNotesError.failed(.codex, "I couldn't check which MCP servers it would load, so I didn't send anything.")
            }
            return entries.compactMap { entry in
                (entry["name"] as? String).map { ($0, entry["enabled"] as? Bool ?? true) }
            }
        }
        let names = try await list([]).map(\.name)
        guard try await list(names).allSatisfy({ !$0.enabled }) else {
            throw MeetingNotesError.failed(.codex, "one of its MCP servers wouldn't turn off, so I didn't send anything.")
        }
        return names
    }

    /// A bare TOML key, or a quoted one when it needs quoting.
    static func tomlKey(_ name: String) -> String {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? name
            : "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func models(_ install: NotesToolInstall) async throws -> [NotesModelOption] {
        let scratch = try NotesTools.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let server = try await Connection.start(install: install, directory: scratch)
        defer { server.stop() }
        let result = try await server.request("model/list", [:], timeout: 30)
        let data = (result["data"] as? [[String: Any]]) ?? []
        return data.compactMap { model in
            guard let id = model["id"] as? String ?? model["model"] as? String else { return nil }
            let efforts = ((model["supportedReasoningEfforts"] as? [[String: Any]]) ?? []).compactMap { $0["reasoningEffort"] as? String }
            return NotesModelOption(id: id, title: model["displayName"] as? String ?? id, efforts: efforts,
                                    defaultEffort: model["defaultReasoningEffort"] as? String, isDefault: model["isDefault"] as? Bool ?? false)
        }
    }

    static func complete(_ request: NotesModelRequest, install: NotesToolInstall) async throws -> Data {
        let scratch = try NotesTools.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let server = try await Connection.start(install: install, directory: scratch)
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(request.timeout)
        var thread: [String: Any] = ["baseInstructions": request.instructions, "ephemeral": true, "cwd": scratch.path,
                                     "sandbox": "read-only", "approvalPolicy": "never"]
        if let model = request.model { thread["model"] = model }
        let started = try await server.request("thread/start", thread, timeout: 60)
        guard let threadID = (started["thread"] as? [String: Any])?["id"] as? String else { throw MeetingNotesError.failed(.codex, "it didn't start a conversation.") }
        var turn: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": request.input]],
                                   "outputSchema": (try? JSONSerialization.jsonObject(with: request.schema)) ?? [:]]
        if let effort = request.effort { turn["effort"] = effort }
        guard await request.proceed() else { throw CancellationError() }
        _ = try await server.request("turn/start", turn, timeout: 60)
        var texts: [String] = []
        while true {
            let event = try await server.next(until: deadline)
            let method = event["method"] as? String
            let params = event["params"] as? [String: Any] ?? [:]
            if let other = params["threadId"] as? String, other != threadID { continue }
            switch method {
            case "item/completed":
                if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                    texts.append(text)
                }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any] ?? [:]
                if turn["status"] as? String != "completed" {
                    let error = turn["error"] as? [String: Any]
                    throw failure(error?["message"] as? String ?? "the turn ended as \(turn["status"] as? String ?? "unknown").")
                }
                // The last message is the answer; earlier ones are commentary.
                guard let last = texts.last, let data = MeetingNotesJSON.object(in: last) else { throw MeetingNotesError.unreadableAnswer }
                return data
            case "error":
                // Retries Codex makes itself arrive as errors with willRetry.
                if params["willRetry"] as? Bool == true { continue }
                let error = params["error"] as? [String: Any]
                throw failure(error?["message"] as? String ?? "it reported an error.")
            default:
                continue
            }
        }
    }

    static func failure(_ message: String) -> MeetingNotesError {
        let short = String(message.prefix(240))
        if short.localizedCaseInsensitiveContains("log in") || short.localizedCaseInsensitiveContains("not logged") {
            return .signedOut(.codex)
        }
        return .failed(.codex, short)
    }

    /// One app-server process: newline-delimited JSON-RPC both ways. Requests from the server (approvals, input) are
    /// refused: notes never need them.
    final class Connection: @unchecked Sendable {
        private let process: Process
        private let input: FileHandle
        private let lines: LineQueue
        private var nextID = 0
        private let stderr = LockedData()
        /// Notifications that arrived while waiting for a response, handed out by `next` first.
        private var held: [[String: Any]] = []

        private init(process: Process, input: FileHandle, lines: LineQueue) {
            self.process = process
            self.input = input
            self.lines = lines
        }

        static func start(install: NotesToolInstall, directory: URL) async throws -> Connection {
            let process = Process()
            process.executableURL = install.executable
            process.arguments = CodexAppServer.arguments(mcpServers: try await CodexAppServer.mcpServersTurnedOff(install, directory: directory))
            process.currentDirectoryURL = directory
            process.environment = NotesTools.environment(path: await NotesTools.searchPath(), executable: install.executable)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            let queue = LineQueue()
            let buffer = LockedData()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    queue.finish()
                    return
                }
                for line in buffer.appendLines(chunk) { queue.push(line) }
            }
            let connection = Connection(process: process, input: stdin.fileHandleForWriting, lines: queue)
            stderr.fileHandleForReading.readabilityHandler = { [weak connection] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { connection?.stderr.append(chunk) }
            }
            do { try process.run() } catch { throw MeetingNotesError.failed(.codex, "it wouldn't start: \(error.localizedDescription)") }
            do {
                _ = try await connection.request("initialize", ["clientInfo": ["name": "gob_lin", "title": "gob.lin", "version": "1"]], timeout: 30)
                try connection.send(["method": "initialized"])
            } catch {
                // The callers' cleanup isn't in place yet, so a server that won't initialise is stopped here.
                connection.stop()
                throw error
            }
            return connection
        }

        func stop() {
            try? input.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.write(contentsOf: data)
        }

        /// Sends a request and waits for its result, answering anything the server asks along the way.
        func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try send(["id": id, "method": method, "params": params])
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let event = try await read(until: deadline)
                guard (event["id"] as? Int) == id, event["method"] == nil else {
                    // A turn's items can arrive before turn/start's own response; they're kept for `next`.
                    if event["method"] != nil { held.append(event) }
                    continue
                }
                if let error = event["error"] as? [String: Any] {
                    throw CodexAppServer.failure(error["message"] as? String ?? "\(method) failed.")
                }
                return event["result"] as? [String: Any] ?? [:]
            }
        }

        /// The next message that isn't a server request, notifications held during a request first.
        func next(until deadline: Date) async throws -> [String: Any] {
            if !held.isEmpty { return held.removeFirst() }
            return try await read(until: deadline)
        }

        /// The next message from the server; server requests are refused on the way.
        private func read(until deadline: Date) async throws -> [String: Any] {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MeetingNotesError.timedOut(.codex) }
                let line = try await lines.next(timeout: remaining)
                guard let line else {
                    throw MeetingNotesError.failed(.codex, NotesTools.errorLine(stderr.value) ?? "it stopped without answering.")
                }
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if event["method"] != nil, let id = event["id"] {
                    try send(["id": id, "error": ["code": -32601, "message": "gob.lin doesn't allow this while writing notes."]])
                    continue
                }
                return event
            }
        }
    }
}

/// Lines from a pipe, handed to one reader at a time, with a deadline.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var finished = false
    private var waiting: (id: UUID, continuation: CheckedContinuation<Data?, Error>)?

    func push(_ line: Data) {
        let waiter: CheckedContinuation<Data?, Error>? = lock.withLock {
            if let waiting { self.waiting = nil; return waiting.continuation }
            lines.append(line)
            return nil
        }
        waiter?.resume(returning: line)
    }

    func finish() {
        let waiter: CheckedContinuation<Data?, Error>? = lock.withLock {
            finished = true
            defer { waiting = nil }
            return waiting?.continuation
        }
        waiter?.resume(returning: nil)
    }

    /// The next line; nil once the pipe closed. Throws `MeetingNotesError.timedOut` after `timeout` seconds.
    func next(timeout: TimeInterval) async throws -> Data? {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Data?, Error>? = lock.withLock {
                if !lines.isEmpty { return .success(lines.removeFirst()) }
                if finished { return .success(nil) }
                waiting = (id, continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let expired: CheckedContinuation<Data?, Error>? = self.lock.withLock {
                    guard let waiting = self.waiting, waiting.id == id else { return nil }
                    self.waiting = nil
                    return waiting.continuation
                }
                expired?.resume(throwing: MeetingNotesError.timedOut(.codex))
            }
        }
    }
}

/// Bytes collected from a pipe across threads.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data { lock.withLock { data } }

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }

    /// Appends and returns every complete line, keeping the rest for next time.
    func appendLines(_ chunk: Data) -> [Data] {
        lock.withLock {
            data.append(chunk)
            var lines: [Data] = []
            while let newline = data.firstIndex(of: 0x0A) {
                let line = data[data.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                data.removeSubrange(data.startIndex...newline)
            }
            return lines
        }
    }
}

/// Finding the JSON object in a model's text, which may come wrapped in a code fence or a sentence.
enum MeetingNotesJSON {
    static func object(in text: String) -> Data? {
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: slice)) is [String: Any] ? slice : nil
    }
}

/// Runs a command to the end with a deadline, collecting its output.
enum ToolProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    enum Failure: Error { case timedOut }

    static func run(_ executable: URL, _ arguments: [String], stdin: Data? = nil, environment: [String: String],
                    directory: URL? = nil, timeout: TimeInterval) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Each pipe is read to its end on its own thread, and both reads finish before the result is taken, so no
        // late chunk can land after it.
        let stdout = LockedData(), stderr = LockedData()
        let drained = DispatchGroup()
        for (pipe, sink) in [(output, stdout), (errors, stderr)] {
            drained.enter()
            let handle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                // Chunk by chunk, so what arrived before a drain deadline is kept even if the end never comes.
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    sink.append(chunk)
                }
                drained.leave()
            }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let finished = LockedFlag()
                process.terminationHandler = { process in
                    if finished.set() { continuation.resume(returning: process.terminationStatus) }
                }
                do { try process.run() } catch {
                    try? output.fileHandleForWriting.close()
                    try? errors.fileHandleForWriting.close()
                    if finished.set() { continuation.resume(throwing: error) }
                    return
                }
                // Only the child writes to these now; the reads end when it (and anything it started) is done.
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                let writer = input.fileHandleForWriting
                DispatchQueue.global(qos: .utility).async {
                    if let stdin { try? writer.write(contentsOf: stdin) }
                    try? writer.close()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard finished.set() else { return }
                    process.terminate()
                    continuation.resume(throwing: Failure.timedOut)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // Exit closes the child's ends; a grandchild still holding one is given a moment, not forever.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = drained.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        return Result(status: status, stdout: stdout.value, stderr: stderr.value)
    }
}

/// Set once, from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// True the first time only.
    func set() -> Bool { lock.withLock { if isSet { return false }; isSet = true; return true } }
}
