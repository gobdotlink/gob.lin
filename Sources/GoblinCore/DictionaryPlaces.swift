import Foundation

/// A place in the Dictionary page's sidebar: the words used everywhere, across one app, or in one project.
public enum DictionaryPlace: Hashable, Sendable {
    case everywhere
    case app(String)
    /// A project as listed under `app`; nil when the project has no app yet.
    case project(String, app: String?)

    /// Where a dictation here would happen, for working out which words it uses.
    public var scope: DictionaryScope {
        switch self {
        case .everywhere: DictionaryScope()
        case .app(let id): DictionaryScope(application: id)
        case .project(let name, let app): DictionaryScope(application: app, project: name)
        }
    }

    /// Whether `entry` is listed here. A project word with no app is listed under every app the project is used in.
    public func holds(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .everywhere: return !entry.isScoped
        case .app(let id): return entry.projects.isEmpty && entry.apps.contains(id)
        case .project(let name, let app):
            let key = DictionaryScope.projectKey(name)
            guard entry.projects.contains(where: { DictionaryScope.projectKey($0) == key }) else { return false }
            return entry.apps.isEmpty || app.map(entry.apps.contains) == true
        }
    }

    /// A blank term that belongs here. Project terms stay shared between apps.
    public var newEntry: DictionaryEntry {
        switch self {
        case .everywhere: DictionaryEntry(spelling: "")
        case .app(let id): DictionaryEntry(spelling: "", apps: [id])
        case .project(let name, _): DictionaryEntry(spelling: "", projects: [name])
        }
    }

    /// The words a dictation here uses, most specific and newest first, and those past `DictionaryScope.activeLimit`.
    public func activeWords(in entries: [DictionaryEntry]) -> (used: [DictionaryEntry], missed: [DictionaryEntry]) {
        let active = entries.active(in: scope)
        return (Array(active.prefix(DictionaryScope.activeLimit)), Array(active.dropFirst(DictionaryScope.activeLimit)))
    }
}

/// A project dictated into within an app, from History.
public struct DictionaryProjectUse: Hashable, Sendable {
    public let application: String
    public let project: String
    public init(application: String, project: String) { self.application = application; self.project = project }
}

/// The sidebar's contents: every place that holds a word, plus the place of the last dictation so a word can be added there.
public struct DictionaryPlaces: Equatable, Sendable {
    public struct Project: Equatable, Identifiable, Sendable {
        public let place: DictionaryPlace
        public let name: String
        public let wordCount: Int
        public var id: DictionaryPlace { place }
    }

    public struct App: Equatable, Identifiable, Sendable {
        public let id: String
        /// Different words anywhere under this app.
        public let wordCount: Int
        public let projects: [Project]
    }

    public let everywhereCount: Int
    public let apps: [App]
    /// Projects with words that no app has been seen using yet.
    public let unassigned: [Project]

    public init(entries: [DictionaryEntry], uses: [DictionaryProjectUse], current: DictionaryScope? = nil) {
        var usedIn: [String: Set<String>] = [:]
        for use in uses where !use.application.isEmpty { usedIn[DictionaryScope.projectKey(use.project), default: []].insert(use.application) }
        let currentApp = current?.application.flatMap { $0.isEmpty ? nil : $0 }
        if let currentApp, let project = current?.project { usedIn[DictionaryScope.projectKey(project), default: []].insert(currentApp) }

        var apps = Set(entries.flatMap(\.apps))
        var projectsByApp: [String: [String: String]] = [:]
        var unassignedNames: [String: String] = [:]
        for entry in entries {
            for project in entry.projects {
                let key = DictionaryScope.projectKey(project)
                let targets = entry.apps.isEmpty ? usedIn[key] ?? [] : Set(entry.apps)
                if targets.isEmpty { unassignedNames[key] = unassignedNames[key] ?? project }
                for app in targets { projectsByApp[app, default: [:]][key] = projectsByApp[app]?[key] ?? project }
            }
        }
        apps.formUnion(projectsByApp.keys)
        if let currentApp {
            apps.insert(currentApp)
            if let project = current?.project {
                let key = DictionaryScope.projectKey(project)
                projectsByApp[currentApp, default: [:]][key] = projectsByApp[currentApp]?[key] ?? project
            }
        }

        func projects(_ names: [String: String], app: String?) -> [Project] {
            names.values.map { name in
                let place = DictionaryPlace.project(name, app: app)
                return Project(place: place, name: name, wordCount: entries.filter(place.holds).count)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        everywhereCount = entries.filter(DictionaryPlace.everywhere.holds).count
        self.apps = apps.sorted().map { id in
            let listed = projects(projectsByApp[id] ?? [:], app: id)
            let count = entries.filter { entry in DictionaryPlace.app(id).holds(entry) || listed.contains { $0.place.holds(entry) } }.count
            return App(id: id, wordCount: count, projects: listed)
        }
        unassigned = projects(unassignedNames, app: nil)
    }

    public func contains(_ place: DictionaryPlace) -> Bool {
        switch place {
        case .everywhere: true
        case .app(let id): apps.contains { $0.id == id }
        case .project(_, let app?): apps.first { $0.id == app }?.projects.contains { $0.place == place } == true
        case .project(_, nil): unassigned.contains { $0.place == place }
        }
    }

    /// The other apps listing `project`, for "also in Codex".
    public func otherApps(listing project: String, besides app: String?) -> [String] {
        let key = DictionaryScope.projectKey(project)
        return apps.filter { $0.id != app && $0.projects.contains { DictionaryScope.projectKey($0.name) == key } }.map(\.id)
    }
}
