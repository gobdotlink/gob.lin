import Foundation
import Testing
@testable import GoblinCore

@Test func projectScopesCombineWithAppScopes() {
    let everywhere = DictionaryEntry(spelling: "Postgres")
    let t3 = DictionaryEntry(spelling: "Kalikin", apps: ["com.t3tools.t3code"])
    let project = DictionaryEntry(spelling: "Luna", projects: ["gob.lin"])
    let both = DictionaryEntry(spelling: "PostHog", apps: ["com.t3tools.t3code"], projects: ["akalikin/gob.lin"])
    let entries = [everywhere, t3, project, both]
    let spellings = { (scope: DictionaryScope) in entries.active(in: scope).map(\.spelling) }
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin")) == ["Postgres", "Kalikin", "Luna", "PostHog"])
    #expect(spellings(DictionaryScope(application: "dev.zed.Zed", project: "/Users/me/Projects/GOB.LIN")) == ["Postgres", "Luna"])
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code", project: "harbor")) == ["Postgres", "Kalikin"])
    // Without a detected project, project terms stay out: a missed detection costs recall, never a wrong term.
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code")) == ["Postgres", "Kalikin"])
    #expect(spellings(DictionaryScope(application: "", project: "")) == ["Postgres"])
    #expect(DictionaryScope.projectKey(" akalikin/Gob.lin/ ") == "gob.lin")
}

@Test func projectScopesPersistAndValidate() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-projects-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let repository = DictionaryRepository(url: url)
    try repository.save([DictionaryEntry(spelling: "Luna", projects: [" gob.lin ", "akalikin/gob.lin", "harbor"])])
    let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    // Version 3: the app-scoped release reads version 2 but would ignore projects and widen these terms.
    #expect(saved.contains(#""version" : 3"#) && saved.contains(#""projects""#) && !saved.contains(#""apps""#))
    #expect(try repository.load()[0].projects == ["gob.lin", "harbor"])
    #expect(throws: DictionaryError.self) { try DictionaryRepository.validated([DictionaryEntry(spelling: "Luna", projects: ["a\nb"])]) }
    #expect(throws: DictionaryError.self) { try DictionaryRepository.validated([DictionaryEntry(spelling: "Luna", projects: ["///"])]) }

    // History keeps the detected project for reprocessing; entries saved before it decode without one.
    let history = HistoryEntry(rawText: "a", finalText: "a", dictionaryBundleIdentifier: "com.t3tools.t3code", dictionaryProject: "gob.lin")
    #expect(history.dictionaryContext == DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin"))
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as! [String: Any]
    legacy.removeValue(forKey: "dictionaryProject")
    let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.dictionaryContext.project == nil)
}

@Test func filesResolveToTheirRepository() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-repo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("gob.lin")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
    let file = repo.appendingPathComponent("Sources/App/Main.swift")
    try Data().write(to: file)
    #expect(ProjectResolution.repositoryName(containing: file) == "gob.lin")
    #expect(ProjectResolution.repositoryName(containing: repo.appendingPathComponent("Sources")) == "gob.lin")
    #expect(ProjectResolution.repositoryName(containing: root) == nil)
    #expect(ProjectResolution.repositoryName(containing: URL(string: "https://example.com/gob.lin")!) == nil)
}

@Test func t3CodeThreadsResolveThroughItsDatabase() throws {
    let address = "t3code://app/#/a3d539ed-9197-4bad-bbdb-ed03b56f9fd5/c36b56f9-d964-495b-9259-066fbcfab418"
    #expect(ProjectResolution.t3ThreadID(fromAddress: address) == "c36b56f9-d964-495b-9259-066fbcfab418")
    #expect(ProjectResolution.t3ThreadID(fromAddress: "t3code://app/#/") == nil)

    let database = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-t3-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: database) }
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [database.path, """
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL, deleted_at TEXT);
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
        INSERT INTO projection_projects VALUES ('p1', 'gob.lin', '/Users/me/gob.lin', NULL), ('p2', 'old', '/old', '2026-01-01'),
            ('p3', 'No project', '/scratch', NULL);
        INSERT INTO orchestration_v2_projection_threads VALUES ('c36b56f9-d964-495b-9259-066fbcfab418', 'p1', 'Thread'),
            ('t2', 'p2', 'Deleted project'), ('t3', 'p3', 'Scratch');
        """]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(sqlite.terminationStatus == 0)
    #expect(ProjectResolution.t3ProjectTitle(threadID: "c36b56f9-d964-495b-9259-066fbcfab418", database: database) == "gob.lin")
    #expect(ProjectResolution.t3ProjectTitle(threadID: "t2", database: database) == nil)
    #expect(ProjectResolution.t3ProjectTitle(threadID: "t3", database: database) == nil)
    #expect(ProjectResolution.t3ProjectTitle(threadID: "remote", database: database) == nil)
    #expect(ProjectResolution.t3ProjectTitles(database: database) == ["gob.lin"])
    #expect(ProjectResolution.t3ProjectTitle(threadID: "x", database: database.appendingPathExtension("missing")) == nil)

    // Remote threads: the main panel's "New thread in <project>" button.
    let nodes = [ProjectResolution.InterfaceNode(role: "AXButton", depth: 3, label: "Add project"),
                 ProjectResolution.InterfaceNode(role: "AXStaticText", depth: 4, label: "New thread in decoy"),
                 ProjectResolution.InterfaceNode(role: "AXButton", depth: 9, label: "New thread in harbor")]
    #expect(ProjectResolution.t3Project(fromInterface: nodes) == "harbor")
}

@Test func paseoWorkspacesResolveLocallyOrFromTheSidebar() throws {
    #expect(ProjectResolution.paseoWorkspaceID(fromAddress: "paseo://app/h/srv_X/workspace/wks_1?tab=2") == "wks_1")
    #expect(ProjectResolution.paseoWorkspaceID(fromAddress: "paseo://app/h/srv_X") == nil)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-paseo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"[{"workspaceId":"wks_1","projectId":"prj_1","mainRepoRoot":"/Users/me/dash"},{"workspaceId":"wks_2","projectId":"prj_gone","mainRepoRoot":"/Users/me/fallback"}]"#.utf8)
        .write(to: directory.appendingPathComponent("workspaces.json"))
    try Data(#"[{"projectId":"prj_1","displayName":"dashboard","customName":"HARBOR","rootPath":"/Users/me/dash"},{"projectId":"prj_old","displayName":"old","archivedAt":"2026"}]"#.utf8)
        .write(to: directory.appendingPathComponent("projects.json"))
    #expect(ProjectResolution.paseoProjectName(workspaceID: "wks_1", directory: directory) == "HARBOR")
    #expect(ProjectResolution.paseoProjectName(workspaceID: "wks_2", directory: directory) == "fallback")
    #expect(ProjectResolution.paseoProjectName(workspaceID: "wks_remote", directory: directory) == nil)
    #expect(ProjectResolution.paseoProjectNames(directory: directory) == ["HARBOR"])

    // Remote workspaces: the only workspace row styled differently from the others is the open one.
    func header(_ name: String) -> ProjectResolution.InterfaceNode {
        .init(role: "AXButton", depth: 24, label: "\(name.prefix(1)) \(name) Create a new workspace for \(name) Project actions")
    }
    func row(_ style: String) -> ProjectResolution.InterfaceNode { .init(role: "AXButton", depth: 26, label: "Workspace", classes: style) }
    let sidebar = [header("harbor"), row("plain"), row("plain"), header("orchard"), row("plain"), row("active"),
                   .init(role: "AXButton", depth: 20, label: "Settings", classes: "other")]
    #expect(ProjectResolution.paseoSidebarRows(sidebar).count == 4)
    #expect(ProjectResolution.paseoProject(fromInterface: sidebar) == "orchard")
    // Ambiguous styling gives no answer rather than a guess.
    #expect(ProjectResolution.paseoProject(fromInterface: [header("a"), row("x"), row("y"), header("b"), row("z")]) == nil)
    #expect(ProjectResolution.paseoProject(fromInterface: [header("a"), row("plain"), row("plain"), row("plain")]) == nil)
}
