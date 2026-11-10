import CSQLite
import Foundation

/// A project detected where dictation started, and how it was found.
public struct DetectedProject: Equatable, Sendable {
    public enum Source: String, Sendable {
        case repository, t3Database, t3Interface, paseoWorkspaces, paseoInterface, slackWindow, codexDatabase, claudeSession
    }

    public let name: String
    public let source: Source
    /// The project's folder on this Mac, when known, for term suggestions. Projects read from the interface have none.
    public let root: URL?

    public init(name: String, source: Source, root: URL? = nil) { self.name = name; self.source = source; self.root = root }
}

/// Turns what other apps expose (file paths, page addresses, sidebar text) into project names.
/// Everything here only reads; other apps' data stores are opened read-only.
public enum ProjectResolution {
    public static let t3CodeBundlePrefix = "com.t3tools.t3code"
    public static let paseoBundle = "sh.paseo.desktop"
    public static let slackBundle = "com.tinyspeck.slackmacgap"
    public static let codexBundle = "com.openai.codex"
    public static let claudeBundle = "com.anthropic.claudefordesktop"

    public static var t3Database: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".t3/userdata/statev2.sqlite")
    }

    public static var paseoProjects: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".paseo/projects")
    }

    // MARK: Files and folders

    /// The name of the git repository containing `url` (a file or folder), if any.
    public static func repositoryName(containing url: URL, fileManager: FileManager = .default) -> String? {
        repositoryRoot(containing: url, fileManager: fileManager)?.lastPathComponent
    }

    /// The folder of the git repository containing `url` (a file or folder), if any.
    public static func repositoryRoot(containing url: URL, fileManager: FileManager = .default) -> URL? {
        guard url.isFileURL else { return nil }
        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            directory.deleteLastPathComponent()
        }
        for _ in 0..<40 {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }

    // MARK: T3 Code

    /// The thread in a T3 Code page address: `t3code://app/#/<environment>/<thread>`.
    public static func t3ThreadID(fromAddress address: String) -> String? {
        guard let fragment = URL(string: address)?.fragment ?? address.components(separatedBy: "#").dropFirst().first else { return nil }
        let parts = fragment.split(separator: "/").map(String.init)
        guard parts.count >= 2, UUID(uuidString: parts[1]) != nil else { return nil }
        return parts[1]
    }

    /// The project title of a thread in T3 Code's local database. Remote environments' threads are not stored there.
    public static func t3ProjectTitle(threadID: String, database: URL = t3Database) -> String? {
        query(database, """
            SELECT p.title FROM orchestration_v2_projection_threads t
            JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.thread_id = ? AND p.deleted_at IS NULL AND p.title != 'No project' LIMIT 1
            """, binding: threadID).first
    }

    /// The folder of a thread's project in T3 Code's local database.
    public static func t3ProjectRoot(threadID: String, database: URL = t3Database) -> URL? {
        query(database, """
            SELECT p.workspace_root FROM orchestration_v2_projection_threads t
            JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.thread_id = ? AND p.deleted_at IS NULL AND p.title != 'No project' LIMIT 1
            """, binding: threadID).first.map { URL(fileURLWithPath: $0) }
    }

    /// Local T3 Code project titles, for suggestions.
    public static func t3ProjectTitles(database: URL = t3Database) -> [String] {
        query(database, "SELECT title FROM projection_projects WHERE deleted_at IS NULL AND title != 'No project' ORDER BY title", binding: nil)
    }

    /// The main panel's "New thread in <project>" button names the open thread's project, local or remote.
    public static func t3ProjectFromLabels<S: Sequence>(_ labels: S) -> String? where S.Element == String {
        for label in labels where label.hasPrefix("New thread in ") {
            let project = label.dropFirst("New thread in ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty { return project }
        }
        return nil
    }

    // MARK: Paseo

    /// The workspace in a Paseo page address: `paseo://app/h/<host>/workspace/<workspace>`.
    public static func paseoWorkspaceID(fromAddress address: String) -> String? {
        let parts = address.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "workspace"), index + 1 < parts.count else { return nil }
        let id = parts[index + 1].split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }

    private struct PaseoWorkspace: Decodable { let workspaceId: String; let projectId: String?; let mainRepoRoot: String? }
    private struct PaseoProject: Decodable {
        let projectId: String; let displayName: String?; let customName: String?; let rootPath: String?; let archivedAt: String?
        var name: String? { [customName, displayName, rootPath.map { URL(fileURLWithPath: $0).lastPathComponent }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } }
    }

    /// A local Paseo workspace's project name. Workspaces on other hosts are not stored on this Mac.
    public static func paseoProjectName(workspaceID: String, directory: URL = paseoProjects) -> String? {
        paseoProject(workspaceID: workspaceID, directory: directory)?.name
    }

    /// A local Paseo workspace's project name and folder.
    public static func paseoProject(workspaceID: String, directory: URL = paseoProjects) -> (name: String, root: URL?)? {
        guard let workspaces: [PaseoWorkspace] = decodeList(directory.appendingPathComponent("workspaces.json")),
              let workspace = workspaces.first(where: { $0.workspaceId == workspaceID }) else { return nil }
        let projects: [PaseoProject] = decodeList(directory.appendingPathComponent("projects.json")) ?? []
        let project = projects.first { $0.projectId == workspace.projectId }
        let root = (project?.rootPath ?? workspace.mainRepoRoot).map { URL(fileURLWithPath: $0) }
        guard let name = project?.name ?? root?.lastPathComponent else { return nil }
        return (name, root)
    }

    /// Local Paseo project names, for suggestions.
    public static func paseoProjectNames(directory: URL = paseoProjects) -> [String] {
        let projects: [PaseoProject] = decodeList(directory.appendingPathComponent("projects.json")) ?? []
        return projects.filter { $0.archivedAt == nil }.compactMap(\.name)
    }

    /// One workspace row in Paseo's sidebar: the project it is listed under and an opaque style key.
    public struct SidebarRow: Equatable, Sendable {
        public let project: String
        public let style: String
        public init(project: String, style: String) { self.project = project; self.style = style }
    }

    /// Paseo marks the open workspace only by styling it differently from every other workspace row. Best effort: the
    /// answer is the project of the single row whose style no other row shares, provided most rows share one style.
    public static func paseoActiveProject(_ rows: [SidebarRow]) -> String? {
        let counts = Dictionary(rows.map { ($0.style, 1) }, uniquingKeysWith: +)
        guard rows.count >= 3, let common = counts.values.max(), common >= 2 else { return nil }
        let unique = rows.filter { counts[$0.style] == 1 }
        return unique.count == 1 ? unique[0].project : nil
    }

    // MARK: Slack

    /// Slack's list of signed-in workspaces. The App Store build keeps its own in a container, which macOS asks
    /// permission to read, so that build relies on the window title alone.
    public static var slackState: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")
    }

    private struct SlackState: Decodable {
        struct Workspace: Decodable { let name: String }
        let workspaces: [String: Workspace]
    }

    /// Signed-in Slack workspace names, for scoping terms and reading window titles.
    public static func slackWorkspaceNames(state: URL = slackState) -> [String] {
        guard let data = try? Data(contentsOf: state), let decoded = try? JSONDecoder().decode(SlackState.self, from: data) else { return [] }
        return decoded.workspaces.values.map(\.name).filter { !$0.isEmpty }.sorted()
    }

    /// The workspace in a Slack window title: "general (Channel) - Acme - 2 new items - Slack". With `known` names, the
    /// rightmost one that fills whole parts of the title, so a channel or workspace name may itself contain " - ".
    public static func slackWorkspace(fromTitle title: String, known: [String]) -> String? {
        let suffix = " - Slack"
        guard title.hasSuffix(suffix) else { return nil }
        let body = String(title.dropLast(suffix.count))
        guard known.isEmpty else {
            let padded = " - " + body + " - "
            var best: (name: String, start: String.Index)?
            for name in known {
                guard let range = padded.range(of: " - " + name + " - ", options: .backwards) else { continue }
                if best == nil || range.lowerBound > best!.start || (range.lowerBound == best!.start && name.count > best!.name.count) {
                    best = (name, range.lowerBound)
                }
            }
            return best?.name
        }
        var parts = body.components(separatedBy: " - ")
        if parts.last?.range(of: #"^\d+ new items?$"#, options: .regularExpression) != nil { parts.removeLast() }
        guard parts.count >= 2, let workspace = parts.last, !workspace.isEmpty else { return nil }
        return workspace
    }

    // MARK: Codex

    public static var codexDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex") }

    private struct CodexState: Decodable {
        struct Project: Decodable { let name: String?; let rootPaths: [String]? }
        let projects: [String: Project]?
        enum CodingKeys: String, CodingKey { case projects = "local-projects" }
    }

    /// The thread database; its file name carries a schema version.
    private static func codexDatabase(directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let newest = names.compactMap { name -> (version: Int, name: String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, name)
        }.max { $0.version < $1.version }
        return newest.map { directory.appendingPathComponent($0.name) }
    }

    private static func codexNamedProjects(directory: URL) -> [CodexState.Project] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".codex-global-state.json")),
              let state = try? JSONDecoder().decode(CodexState.self, from: data) else { return [] }
        return Array((state.projects ?? [:]).values)
    }

    /// The repository name in a git remote, so every worktree of one repository is the same project.
    static func repositoryName(fromRemote remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? nil : name
    }

    /// The project of the thread a Codex window is titled after: Codex's page address doesn't name the thread. Threads
    /// can share a title, so an answer needs all of them to be in one project.
    public static func codexProject(threadTitle: String, directory: URL = codexDirectory) -> (name: String, root: URL?)? {
        guard let database = codexDatabase(directory: directory) else { return nil }
        let rows = query(database, """
            SELECT DISTINCT cwd || char(10) || coalesce(git_origin_url, '') FROM threads
            WHERE archived = 0 AND ? IN (name, title)
            """, binding: threadTitle)
        let named = codexNamedProjects(directory: directory)
        var found: (name: String, root: URL?)?
        for row in rows {
            let parts = row.components(separatedBy: "\n")
            guard parts.count == 2 else { return nil }
            let folder = URL(fileURLWithPath: parts[0])
            let root = repositoryRoot(containing: folder)
            guard let name = repositoryName(fromRemote: parts[1])
                ?? named.first(where: { $0.rootPaths?.contains(parts[0]) == true })?.name ?? root?.lastPathComponent else { return nil }
            if let found, DictionaryScope.projectKey(found.name) != DictionaryScope.projectKey(name) { return nil }
            found = found ?? (name, root)
        }
        return found
    }

    /// Codex's named projects and the repositories of its threads, for suggestions.
    public static func codexProjectNames(directory: URL = codexDirectory) -> [String] {
        let remotes = codexDatabase(directory: directory).map {
            query($0, "SELECT DISTINCT git_origin_url FROM threads WHERE archived = 0 AND git_origin_url IS NOT NULL", binding: nil)
        } ?? []
        return remotes.compactMap(repositoryName(fromRemote:)) + codexNamedProjects(directory: directory).compactMap(\.name)
    }

    // MARK: Claude

    public static var claudeSessions: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// The local Code session in a Claude page address: a path component `local_<uuid>`. Chats have none.
    public static func claudeSessionID(fromAddress address: String) -> String? {
        (URL(string: address)?.path ?? address).split(separator: "/").map(String.init)
            .first { $0.hasPrefix("local_") && UUID(uuidString: String($0.dropFirst(6))) != nil }
    }

    private struct ClaudeSession: Decodable { let cwd: String?; let originCwd: String? }

    /// The project of a local Claude Code session, from `<account>/<organization>/<session>.json`. The folder a session
    /// started in comes first, because `cwd` can be a worktree. A session in the home folder has no project.
    public static func claudeProject(sessionID: String, directory: URL = claudeSessions, home: String = NSHomeDirectory()) -> (name: String, root: URL?)? {
        guard !sessionID.contains("/") else { return nil }
        let fileManager = FileManager.default
        let children = { (url: URL) in (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] }
        for organization in children(directory).flatMap(children) {
            guard let data = try? Data(contentsOf: organization.appendingPathComponent(sessionID + ".json")) else { continue }
            guard let session = try? JSONDecoder().decode(ClaudeSession.self, from: data),
                  let path = [session.originCwd, session.cwd].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            if let root = repositoryRoot(containing: folder) { return (root.lastPathComponent, root) }
            return folder.path == URL(fileURLWithPath: home).standardizedFileURL.path ? nil : (folder.lastPathComponent, nil)
        }
        return nil
    }

    // MARK: Interface text

    /// One element of another app's accessibility tree, in document order.
    public struct InterfaceNode: Equatable, Sendable {
        public let role: String
        public let depth: Int
        public let label: String
        /// Web content's class list, which Paseo uses to style the open workspace.
        public let classes: String
        public init(role: String, depth: Int, label: String, classes: String = "") {
            self.role = role; self.depth = depth; self.label = label; self.classes = classes
        }
    }

    public static func t3Project(fromInterface nodes: [InterfaceNode]) -> String? {
        t3ProjectFromLabels(nodes.lazy.filter { $0.role == "AXButton" }.map(\.label))
    }

    /// Paseo's sidebar lists each project as a button labelled "… Create a new workspace for <project> Project actions",
    /// followed by its workspaces as deeper buttons.
    public static func paseoSidebarRows(_ nodes: [InterfaceNode]) -> [SidebarRow] {
        let marker = "Create a new workspace for "
        var rows: [SidebarRow] = []
        var current: (project: String, depth: Int)?
        for node in nodes where node.role == "AXButton" {
            if let range = node.label.range(of: marker) {
                let name = node.label[range.upperBound...].replacingOccurrences(of: " Project actions", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                current = name.isEmpty ? nil : (name, node.depth)
            } else if let project = current {
                if node.depth > project.depth { rows.append(SidebarRow(project: project.project, style: node.classes)) }
                else { current = nil }
            }
        }
        return rows
    }

    public static func paseoProject(fromInterface nodes: [InterfaceNode]) -> String? {
        paseoActiveProject(paseoSidebarRows(nodes))
    }

    // MARK: Storage

    private static func decodeList<T: Decodable>(_ url: URL) -> [T]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let list = try? JSONDecoder().decode([T].self, from: data) { return list }
        return (try? JSONDecoder().decode([String: T].self, from: data)).map { Array($0.values) }
    }

    /// Read-only query returning the first column as strings. Any failure returns no rows.
    private static func query(_ database: URL, _ sql: String, binding: String?) -> [String] {
        guard FileManager.default.isReadableFile(atPath: database.path) else { return [] }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(handle, 50)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        if let binding {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, binding, -1, transient) == SQLITE_OK else { return [] }
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, rows.count < 500 {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }
}
