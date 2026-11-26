import CoreServices
import Foundation

/// The AI apps gob.lin can add its meetings server to, and adding or removing it. Claude Code and Codex are set up
/// with their own `mcp add` and `mcp remove` commands; the Claude app reads a JSON file, which is edited in place,
/// keeping everything else in it. Codex, the Codex app and ChatGPT for Mac share one Codex setting.
public enum AIApp: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case claudeDesktop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex and ChatGPT"
        case .claudeDesktop: "Claude"
        }
    }

    /// Where what the app reads goes.
    public var company: String {
        switch self {
        case .claudeCode, .claudeDesktop: "Anthropic"
        case .codex: "OpenAI"
        }
    }

    /// The app's icon, for Settings; nil for a command-line tool.
    public var bundleIdentifier: String? {
        switch self {
        case .claudeCode: nil
        case .codex: "com.openai.chat"
        case .claudeDesktop: "com.anthropic.claudefordesktop"
        }
    }
}

public enum AIAppConnectionState: Equatable, Sendable {
    case notInstalled
    case notConnected
    case connected
    /// Set up for another copy of gob.lin (a moved app or a development build); connecting again points it here.
    case connectedElsewhere(String)
    /// Set up, but switched off in the app's own settings (Codex keeps an `enabled` flag).
    case disabled

    public var isConnected: Bool {
        switch self {
        case .connected, .connectedElsewhere: true
        default: false
        }
    }

    /// There's an entry to take out.
    public var isRegistered: Bool { isConnected || self == .disabled }
}

public enum AIAppConnectionError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case commandFailed(String, String)
    case unreadableConfig(String)
    case unexpectedConfig(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app) isn't installed on this Mac."
        case .commandFailed(let command, let message): message.isEmpty ? "\(command) failed." : "\(command) said: \(message)"
        case .unreadableConfig(let path): "\(path) isn't valid JSON, so I left it alone."
        case .unexpectedConfig(let path): "mcpServers in \(path) isn't a list of servers, so I left it alone."
        }
    }
}

public enum AIAppConnections {
    /// The name gob.lin's server goes by in each app; tool names come out as `goblin` plus the tool.
    public static let serverName = MeetingsMCPServer.serverName

    /// The command an app runs to start the server: this app's own executable with `mcp`.
    public static func serverCommand(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()) -> [String] {
        [executable.path, "mcp"]
    }

    public static func state(_ app: AIApp, command: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> AIAppConnectionState {
        switch app {
        case .claudeCode:
            guard await claudeExecutable() != nil else { return .notInstalled }
            let file = home.appendingPathComponent(".claude.json")
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["mcpServers"] as? [String: Any], let entry = servers[serverName] as? [String: Any] else { return .notConnected }
            return compare(entry, command)
        case .codex:
            guard let codex = await codexExecutable() else { return .notInstalled }
            guard let result = try? await run(codex, ["mcp", "get", serverName, "--json"]), result.status == 0,
                  let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else { return .notConnected }
            if object["enabled"] as? Bool == false { return .disabled }
            return compare(object["transport"] as? [String: Any] ?? object, command)
        case .claudeDesktop:
            let file = claudeDesktopConfig(home: home)
            guard claudeDesktopInstalled(home: home) else { return .notInstalled }
            guard let object = try? readJSONObject(file), let servers = object["mcpServers"] as? [String: Any],
                  let entry = servers[serverName] as? [String: Any] else { return .notConnected }
            return compare(entry, command)
        }
    }

    /// Adds gob.lin to the app, replacing an entry of the same name.
    public static func connect(_ app: AIApp, command: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        switch app {
        case .claudeCode:
            guard let claude = await claudeExecutable() else { throw AIAppConnectionError.notInstalled(app.title) }
            _ = try? await run(claude, ["mcp", "remove", serverName, "--scope", "user"])
            try await check(run(claude, ["mcp", "add", "--scope", "user", serverName, "--"] + command), "claude mcp add")
        case .codex:
            guard let codex = await codexExecutable() else { throw AIAppConnectionError.notInstalled(app.title) }
            _ = try? await run(codex, ["mcp", "remove", serverName])
            try await check(run(codex, ["mcp", "add", serverName, "--"] + command), "codex mcp add")
        case .claudeDesktop:
            guard claudeDesktopInstalled(home: home) else { throw AIAppConnectionError.notInstalled(app.title) }
            try editClaudeDesktopConfig(home: home) { servers in
                servers[serverName] = ["command": command[0], "args": Array(command.dropFirst())]
            }
        }
    }

    public static func disconnect(_ app: AIApp, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        switch app {
        case .claudeCode:
            guard let claude = await claudeExecutable() else { return }
            try await check(run(claude, ["mcp", "remove", serverName, "--scope", "user"]), "claude mcp remove")
        case .codex:
            guard let codex = await codexExecutable() else { return }
            try await check(run(codex, ["mcp", "remove", serverName]), "codex mcp remove")
        case .claudeDesktop:
            guard FileManager.default.fileExists(atPath: claudeDesktopConfig(home: home).path) else { return }
            try editClaudeDesktopConfig(home: home) { servers in servers.removeValue(forKey: serverName) }
        }
    }

    /// The command line, quoted for a shell, for adding gob.lin to an app by hand.
    public static func shellCommand(_ command: [String]) -> String {
        command.map { argument in
            argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) } ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: Finding the apps

    static func claudeExecutable() async -> URL? {
        NotesTools.locate("claude", path: await NotesTools.searchPath())
    }

    /// Codex on PATH, else the copy inside ChatGPT for Mac or the Codex app, which read the same settings.
    static func codexExecutable() async -> URL? {
        if let found = NotesTools.locate("codex", path: await NotesTools.searchPath()) { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let apps = installed("com.openai.chat") + installed("com.openai.codex")
            + ["/Applications/ChatGPT.app", "/Applications/Codex.app", home.appendingPathComponent("ChatGPT.app").path,
               home.appendingPathComponent("Codex.app").path].map(URL.init(fileURLWithPath:))
        let inside = ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
        return apps.lazy.flatMap { app in inside.map { app.appendingPathComponent($0) } }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where Launch Services knows an app with this bundle identifier is installed.
    static func installed(_ bundleIdentifier: String) -> [URL] {
        (LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
    }

    static func claudeDesktopConfig(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static func claudeDesktopInstalled(home: URL) -> Bool {
        ["/Applications/Claude.app", home.appendingPathComponent("Applications/Claude.app").path,
         claudeDesktopConfig(home: home).deletingLastPathComponent().path].contains { FileManager.default.fileExists(atPath: $0) }
            || !installed(AIApp.claudeDesktop.bundleIdentifier ?? "").isEmpty
    }

    // MARK: Helpers

    static func compare(_ entry: [String: Any], _ command: [String]) -> AIAppConnectionState {
        let configured = [entry["command"] as? String ?? ""] + (entry["args"] as? [String] ?? [])
        if configured == command { return .connected }
        return .connectedElsewhere(configured.first ?? "")
    }

    static func readJSONObject(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAppConnectionError.unreadableConfig(file.lastPathComponent)
        }
        return object
    }

    /// Changes only `mcpServers` and writes the file back whole, atomically; the rest of the file is kept as it was read.
    static func editClaudeDesktopConfig(home: URL, _ change: (inout [String: Any]) -> Void) throws {
        let file = claudeDesktopConfig(home: home)
        var object = try readJSONObject(file)
        // Only a missing list starts empty; anything else that isn't one is the person's to fix, not to overwrite.
        guard object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
            throw AIAppConnectionError.unexpectedConfig(file.lastPathComponent)
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        object["mcpServers"] = servers
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Through a symlink to the file it points at (a dotfiles setup keeps it linked), keeping the file's permissions.
        let target = file.resolvingSymlinksInPath()
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> ToolProcess.Result {
        let path = await NotesTools.searchPath()
        // In the home folder, so a project's own MCP settings there can't come into it.
        return try await ToolProcess.run(executable, arguments, environment: NotesTools.environment(path: path, executable: executable),
                                         directory: FileManager.default.homeDirectoryForCurrentUser, timeout: 30)
    }

    static func check(_ result: ToolProcess.Result, _ command: String) throws {
        guard result.status != 0 else { return }
        let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            .split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        throw AIAppConnectionError.commandFailed(command, message)
    }
}
