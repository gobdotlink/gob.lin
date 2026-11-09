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
    // Most specific first: project and app, project, app, then everywhere.
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin")) == ["PostHog", "Luna", "Kalikin", "Postgres"])
    #expect(spellings(DictionaryScope(application: "dev.zed.Zed", project: "/Users/me/Projects/GOB.LIN")) == ["Luna", "Postgres"])
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code", project: "harbor")) == ["Kalikin", "Postgres"])
    // Without a detected project, project terms stay out: a missed detection costs recall, never a wrong term.
    #expect(spellings(DictionaryScope(application: "com.t3tools.t3code")) == ["Kalikin", "Postgres"])
    #expect(spellings(DictionaryScope(application: "", project: "")) == ["Postgres"])
    #expect(DictionaryScope.projectKey(" akalikin/Gob.lin/ ") == "gob.lin")
}

@Test func vocabularyKeepsTheMostSpecificAndNewestTermsWithinTheLimit() {
    let everywhere = (0..<DictionaryScope.activeLimit).map { DictionaryEntry(spelling: "Term\($0)") }
    let entries = [DictionaryEntry(spelling: "Luna", projects: ["gob.lin"])] + everywhere
    let vocabulary = entries.vocabulary(in: DictionaryScope(application: "dev.zed.Zed", project: "gob.lin"))
    #expect(vocabulary.count == DictionaryScope.activeLimit)
    // The project term comes first; among terms used everywhere the oldest falls past the limit.
    #expect(vocabulary.first == "Luna" && vocabulary[1] == "Term\(DictionaryScope.activeLimit - 1)" && !vocabulary.contains("Term0"))
    #expect(entries.active(in: DictionaryScope(application: "dev.zed.Zed", project: "gob.lin")).count == DictionaryScope.activeLimit + 1)
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
    #expect(ProjectResolution.repositoryRoot(containing: file)?.standardizedFileURL == repo.standardizedFileURL)
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
    #expect(ProjectResolution.t3ProjectRoot(threadID: "c36b56f9-d964-495b-9259-066fbcfab418", database: database)?.path == "/Users/me/gob.lin")
    #expect(ProjectResolution.t3ProjectRoot(threadID: "t2", database: database) == nil)
    #expect(ProjectResolution.t3ProjectTitle(threadID: "x", database: database.appendingPathExtension("missing")) == nil)

    // Remote threads: the main panel's "New thread in <project>" button.
    let nodes = [ProjectResolution.InterfaceNode(role: "AXButton", depth: 3, label: "Add project"),
                 ProjectResolution.InterfaceNode(role: "AXStaticText", depth: 4, label: "New thread in decoy"),
                 ProjectResolution.InterfaceNode(role: "AXButton", depth: 9, label: "New thread in harbor")]
    #expect(ProjectResolution.t3Project(fromInterface: nodes) == "harbor")
}

@Test func dictionaryPlacesListProjectsUnderTheAppsTheyAreUsedIn() {
    let t3 = "com.t3tools.t3code", codex = "com.openai.codex"
    let everywhere = DictionaryEntry(spelling: "Postgres")
    let wholeApp = DictionaryEntry(spelling: "Zod", apps: [t3])
    let shared = DictionaryEntry(spelling: "Parakeet", projects: ["gob.lin"])
    let onlyCodex = DictionaryEntry(spelling: "AGENTS.md", apps: [codex], projects: ["acme/gob.lin"])
    let unseen = DictionaryEntry(spelling: "Tennis", projects: ["evals"])
    let entries = [everywhere, wholeApp, shared, onlyCodex, unseen]
    let uses = [DictionaryProjectUse(application: t3, project: "gob.lin"), DictionaryProjectUse(application: codex, project: "gob.lin"),
                DictionaryProjectUse(application: "", project: "evals"), DictionaryProjectUse(application: t3, project: "no-words")]
    let places = DictionaryPlaces(entries: entries, uses: uses)

    #expect(places.everywhereCount == 1 && places.apps.map(\.id) == [t3, codex].sorted())
    let t3Place = places.apps.first { $0.id == t3 }!, codexPlace = places.apps.first { $0.id == codex }!
    // A project word with no app is listed under each app using the project; a project with no words isn't listed.
    #expect(t3Place.projects.map(\.name) == ["gob.lin"] && t3Place.projects[0].wordCount == 1 && t3Place.wordCount == 2)
    #expect(codexPlace.projects[0].wordCount == 2 && codexPlace.wordCount == 2)
    #expect(places.unassigned.map(\.name) == ["evals"])
    #expect(places.otherApps(listing: "gob.lin", besides: t3) == [codex])

    // Whole-app and everywhere words stay out of project lists, and app-limited project words out of other apps.
    let t3Project = DictionaryPlace.project("gob.lin", app: t3)
    #expect(entries.filter(t3Project.holds).map(\.spelling) == ["Parakeet"])
    #expect(entries.filter(DictionaryPlace.app(t3).holds).map(\.spelling) == ["Zod"])
    #expect(entries.filter(DictionaryPlace.everywhere.holds).map(\.spelling) == ["Postgres"])

    // The last dictation's place is listed even before it has a word.
    let current = DictionaryPlaces(entries: entries, uses: [], current: DictionaryScope(application: "com.tinyspeck.slackmacgap", project: "Acme"))
    let slack = DictionaryPlace.project("Acme", app: "com.tinyspeck.slackmacgap")
    #expect(current.contains(slack) && !places.contains(slack) && current.apps.first { $0.id == "com.tinyspeck.slackmacgap" }?.wordCount == 0)
    #expect(DictionaryPlaces(entries: entries, uses: [], current: DictionaryScope(application: t3, project: "gob.lin")).unassigned.map(\.name) == ["evals"])
    #expect(places.contains(.everywhere) && places.contains(.project("evals", app: nil)) && !places.contains(.app("gone")))

    // A new term joins the selected place, and project terms stay shared between apps.
    #expect(t3Project.newEntry.projects == ["gob.lin"] && t3Project.newEntry.apps.isEmpty)
    #expect(DictionaryPlace.app(t3).newEntry.apps == [t3] && !DictionaryPlace.everywhere.newEntry.isScoped)
}

@Test func placesReportWordsPastTheLimitInPriorityOrder() {
    let everywhere = (0..<DictionaryScope.activeLimit).map { DictionaryEntry(spelling: "Term\($0)") }
    let entries = everywhere + [DictionaryEntry(spelling: "Luna", projects: ["gob.lin"])]
    let words = DictionaryPlace.project("gob.lin", app: "dev.zed.Zed").activeWords(in: entries)
    #expect(words.used.count == DictionaryScope.activeLimit && words.used.first?.spelling == "Luna")
    #expect(words.missed.map(\.spelling) == ["Term0"])
}

@Test func historyListsTheProjectsDictatedIntoEachApp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-uses-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(directory: directory)
    for (app, project) in [("com.a", "one"), ("com.a", "one"), ("com.b", "one"), ("com.a", nil), (nil, "two")] as [(String?, String?)] {
        _ = try await store.insert(HistoryEntry(rawText: "a", finalText: "a", dictionaryBundleIdentifier: app, dictionaryProject: project))
    }
    #expect(Set(try await store.dictionaryProjectUses()) == [DictionaryProjectUse(application: "com.a", project: "one"),
                                                            DictionaryProjectUse(application: "com.b", project: "one")])
}

@Test func slackTitlesNameTheirWorkspace() throws {
    let known = ["Acme", "Acme - Labs", "Harbor"]
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Sam, Alex (DM) - Harbor - Slack", known: known) == "Harbor")
    #expect(ProjectResolution.slackWorkspace(fromTitle: "general (Channel) - Acme - 2 new items - Slack", known: known) == "Acme")
    #expect(ProjectResolution.slackWorkspace(fromTitle: "general (Channel) - Acme - Labs - Slack", known: known) == "Acme - Labs")
    // A channel that shares a workspace's name doesn't win over the workspace to its right.
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Harbor - Acme - Slack", known: known) == "Acme")
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Harbor - Slack", known: known) == "Harbor")
    #expect(ProjectResolution.slackWorkspace(fromTitle: "general - Elsewhere - Slack", known: known) == nil)
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Slack", known: known) == nil)
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Notes - Acme", known: known) == nil)
    // Without Slack's list, an unread count must not be taken for the workspace.
    #expect(ProjectResolution.slackWorkspace(fromTitle: "general (Channel) - Acme - 1 new item - Slack", known: []) == "Acme")
    #expect(ProjectResolution.slackWorkspace(fromTitle: "Acme - Slack", known: []) == nil)

    let state = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-slack-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: state) }
    try Data(#"{"workspaces":{"T2":{"id":"T2","name":"Harbor"},"T1":{"id":"T1","name":"Acme"}},"settings":{}}"#.utf8).write(to: state)
    #expect(ProjectResolution.slackWorkspaceNames(state: state) == ["Acme", "Harbor"])
    #expect(ProjectResolution.slackWorkspaceNames(state: state.appendingPathExtension("missing")) == [])
}

@Test func codexWindowsResolveThroughTheirThread() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let worktree = directory.appendingPathComponent("worktrees/feature")
    try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    // An older schema's file sits beside the current one and must be ignored.
    try Data().write(to: directory.appendingPathComponent("state_4.sqlite"))
    sqlite.arguments = [directory.appendingPathComponent("state_5.sqlite").path, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL, name TEXT, archived INTEGER NOT NULL, git_origin_url TEXT);
        INSERT INTO threads VALUES
            ('a', '\(worktree.path)', 'Fix the build', NULL, 0, 'git@github.com:acme/gob.lin.git'),
            ('b', '/elsewhere/other', 'first message', 'Renamed thread', 0, 'https://github.com/acme/gob.lin/'),
            ('c', '/Users/me/Tennis evals', 'Evals', NULL, 0, NULL),
            ('d', '/Users/me/scratch', 'Scratch', NULL, 0, NULL),
            ('e', '/one', 'hmm', NULL, 0, 'https://github.com/acme/one.git'),
            ('f', '/two', 'hmm', NULL, 0, 'https://github.com/acme/two.git'),
            ('g', '/same/one', 'Same repo', NULL, 0, 'https://github.com/acme/three.git'),
            ('h', '/same/two', 'Same repo', NULL, 0, 'https://github.com/acme/three.git'),
            ('i', '/three', 'Gone', NULL, 1, 'https://github.com/acme/gone.git');
        """]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(sqlite.terminationStatus == 0)
    try Data(#"{"local-projects":{"p1":{"name":"Tennis evals","rootPaths":["/Users/me/Tennis evals"]}},"other":[1]}"#.utf8)
        .write(to: directory.appendingPathComponent(".codex-global-state.json"))

    // The remote names the project, not the worktree folder, which still supplies the root.
    let build = ProjectResolution.codexProject(threadTitle: "Fix the build", directory: directory)
    #expect(build?.name == "gob.lin" && build?.root?.lastPathComponent == "feature")
    #expect(ProjectResolution.codexProject(threadTitle: "Renamed thread", directory: directory)?.name == "gob.lin")
    #expect(ProjectResolution.codexProject(threadTitle: "Evals", directory: directory)?.name == "Tennis evals")
    #expect(ProjectResolution.codexProject(threadTitle: "Same repo", directory: directory)?.name == "three")
    // No project, a title shared between projects, an archived thread or an unknown title: no guess.
    #expect(ProjectResolution.codexProject(threadTitle: "Scratch", directory: directory) == nil)
    #expect(ProjectResolution.codexProject(threadTitle: "hmm", directory: directory) == nil)
    #expect(ProjectResolution.codexProject(threadTitle: "Gone", directory: directory) == nil)
    #expect(ProjectResolution.codexProject(threadTitle: "ChatGPT", directory: directory) == nil)
    #expect(ProjectResolution.codexProject(threadTitle: "x", directory: directory.appendingPathComponent("missing")) == nil)
    #expect(Set(ProjectResolution.codexProjectNames(directory: directory)) == ["gob.lin", "one", "two", "three", "Tennis evals"])
    #expect(ProjectResolution.repositoryName(fromRemote: "ssh://git@host:22/acme/tool.git") == "tool")
    #expect(ProjectResolution.repositoryName(fromRemote: "") == nil)
}

@Test func claudeCodeSessionsResolveThroughTheirFiles() throws {
    let id = "local_68375b12-2ae6-4f74-b289-230ffd379fef"
    #expect(ProjectResolution.claudeSessionID(fromAddress: "https://claude.ai/epitaxy/\(id)?tab=1") == id)
    #expect(ProjectResolution.claudeSessionID(fromAddress: "https://claude.ai/new") == nil)
    #expect(ProjectResolution.claudeSessionID(fromAddress: "https://claude.ai/epitaxy/local_nope") == nil)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-claude-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let organization = directory.appendingPathComponent("account/organization")
    let repo = directory.appendingPathComponent("gob.lin"), plain = directory.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: organization, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    func write(_ name: String, _ cwd: String, origin: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["sessionId": name, "cwd": cwd, "originCwd": origin])
        try json.write(to: organization.appendingPathComponent(name + ".json"))
    }
    try write(id, "/gone/worktree", origin: repo.path)
    try write("local_notes", plain.path, origin: "")
    try write("local_home", directory.path, origin: directory.path)
    let project = ProjectResolution.claudeProject(sessionID: id, directory: directory, home: "/nowhere")
    #expect(project?.name == "gob.lin" && project?.root != nil)
    let notes = ProjectResolution.claudeProject(sessionID: "local_notes", directory: directory, home: "/nowhere")
    #expect(notes?.name == "Notes" && notes?.root == nil)
    #expect(ProjectResolution.claudeProject(sessionID: "local_home", directory: directory, home: directory.path) == nil)
    #expect(ProjectResolution.claudeProject(sessionID: "local_missing", directory: directory) == nil)
    #expect(ProjectResolution.claudeProject(sessionID: "../\(id)", directory: directory) == nil)
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
    #expect(ProjectResolution.paseoProject(workspaceID: "wks_1", directory: directory)?.root?.path == "/Users/me/dash")
    #expect(ProjectResolution.paseoProject(workspaceID: "wks_2", directory: directory)?.root?.path == "/Users/me/fallback")

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
