import Foundation

/// A dictionary term gob.lin offers for a project or app. Nothing is added until the user accepts it.
public struct TermSuggestion: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The user changed `heard` to this spelling after a dictation.
        case correction(heard: String)
        case projectName
        /// A package manifest's name, such as "Package.swift".
        case manifest(String)
        case author
        case folder
        /// The spelling is already used in two or more places, or in places that can't merge, so use it everywhere.
        case everywhere
    }

    public let spelling: String
    public let aliases: [String]
    /// Where it would apply. Both empty means everywhere.
    public let apps: [String]
    public let projects: [String]
    public let reason: Reason

    public init(spelling: String, aliases: [String] = [], apps: [String] = [], projects: [String] = [], reason: Reason) {
        self.spelling = spelling
        self.aliases = aliases
        self.apps = apps
        self.projects = projects
        self.reason = reason
    }

    /// The spelling and the place it would apply; dismissals are remembered by this.
    public var id: String {
        [dictionaryKey(spelling), apps.sorted().joined(separator: ","),
         projects.map(DictionaryScope.projectKey).sorted().joined(separator: ",")].joined(separator: "|")
    }

    /// The dictation place this suggestion is for.
    public var place: DictionaryScope { DictionaryScope(application: apps.first, project: projects.first) }

    public var isEverywhere: Bool { apps.isEmpty && projects.isEmpty }
}

public enum TermSuggestions {
    /// Most suggestions shown at once.
    public static let limit = 8

    // MARK: Repositories

    /// Names a repository is likely to be dictated with: the project, its package names, top-level folders and git
    /// authors. Reads a few files at the top level only, so it is cheap; everything stays on this Mac.
    public static func fromRepository(root: URL, project: String, fileManager: FileManager = .default) -> [TermSuggestion] {
        let scope = [project]
        var result: [TermSuggestion] = []
        let name = project.split(separator: "/").last.map(String.init) ?? project
        result.append(TermSuggestion(spelling: name, projects: scope, reason: .projectName))
        for (file, name) in manifestNames(root: root) {
            result.append(TermSuggestion(spelling: name, projects: scope, reason: .manifest(file)))
        }
        for author in authors(root: root) { result.append(TermSuggestion(spelling: author, projects: scope, reason: .author)) }
        for folder in folders(root: root, fileManager: fileManager) {
            result.append(TermSuggestion(spelling: folder, projects: scope, reason: .folder))
        }
        return result
    }

    static func manifestNames(root: URL) -> [(file: String, name: String)] {
        func read(_ file: String) -> String? {
            let url = root.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        var names: [(String, String)] = []
        if let text = read("Package.swift"), let name = firstMatch(#"name:\s*"([^"]+)""#, in: text) { names.append(("Package.swift", name)) }
        if let data = read("package.json").map({ Data($0.utf8) }),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = object["name"] as? String {
            names.append(("package.json", name.split(separator: "/").last.map(String.init) ?? name))
        }
        if let text = read("Cargo.toml"), let name = tomlValue("name", section: "package", in: text) { names.append(("Cargo.toml", name)) }
        if let text = read("pyproject.toml"), let name = tomlValue("name", section: "project", in: text) { names.append(("pyproject.toml", name)) }
        if let text = read("go.mod"), let module = firstMatch(#"(?m)^module\s+(\S+)"#, in: text) {
            // "example.com/tool/v2" is the module "tool".
            let parts = module.split(separator: "/").map(String.init)
            if let name = parts.last(where: { $0.range(of: #"^v\d+$"#, options: .regularExpression) == nil }) { names.append(("go.mod", name)) }
        }
        return names.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func tomlValue(_ key: String, section: String, in text: String) -> String? {
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { current = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
            guard current == section, let value = firstMatch(#"^"# + key + #"\s*=\s*["']([^"']+)["']"#, in: trimmed) else { continue }
            return value
        }
        return nil
    }

    private static let ignoredFolders: Set<String> = [
        "node_modules", "build", "dist", "out", "target", "vendor", "venv", "env", "coverage", "tmp", "temp", "bin", "obj",
        "pods", "deriveddata", "__pycache__", "src", "lib", "pkg", "cmd", "internal", "deps", "ext", "res", "util", "utils",
    ]

    static func folders(root: URL, fileManager: FileManager = .default) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.prefix(200).filter { url in
            let name = url.lastPathComponent
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !name.hasPrefix(".") && !name.contains(".") && !ignoredFolders.contains(name.lowercased())
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Words of the names in the repository's last 300 commits, most frequent first. Without git, or outside a
    /// repository, there are none.
    static func authors(root: URL) -> [String] {
        guard let git = gitExecutable(),
              let output = run(git, ["-C", root.path, "log", "--format=%an", "-n", "300"]) else { return [] }
        var counts: [String: (word: String, count: Int, first: Int)] = [:]
        for line in output.components(separatedBy: .newlines) where !line.contains("[bot]") {
            for word in line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) {
                let key = dictionaryKey(word)
                let order = counts.count
                counts[key, default: (word, 0, order)].count += 1
            }
        }
        return counts.values.sorted { ($0.count, -$0.first) > ($1.count, -$1.first) }.map(\.word)
    }

    /// A git that runs without asking to install developer tools: Homebrew's, or the active developer directory's.
    /// `/usr/bin/git` is a shim that shows an install dialog when the tools are missing.
    private static func gitExecutable() -> String? {
        let fileManager = FileManager.default
        if let brew = ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: fileManager.isExecutableFile) { return brew }
        guard let developer = run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !developer.isEmpty else { return nil }
        let git = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git").path
        return fileManager.isExecutableFile(atPath: git) ? git : nil
    }

    /// The tool's standard output, or nil if it fails or takes longer than two seconds.
    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Corrections

    /// Terms the user fixed after a dictation: 1–3 words replaced by 1–3 words, such as "go blin" → "gob.lin". The
    /// suggestion applies in the detected project, or in the app when there is none. Splits on whitespace only, so a
    /// term like "gob.lin" stays whole.
    public static func fromCorrection(dictated: String, edited: String, scope: DictionaryScope) -> [TermSuggestion] {
        let apps: [String], projects: [String]
        if let project = scope.project { apps = []; projects = [project] }
        else if let app = scope.application, !app.isEmpty { apps = [app]; projects = [] }
        else { return [] }
        let changes = TextDiff.changes(from: dictated, to: edited) { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        var result: [TermSuggestion] = []
        for (change, next) in zip(changes, changes.dropFirst()) {
            guard case .removed(let removed) = change, case .added(let added) = next else { continue }
            let heard = trimmed(removed), spelling = trimmed(added)
            let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).count }
            guard (1...3).contains(words(heard)), (1...3).contains(words(spelling)), heard != spelling else { continue }
            let squashed = { (text: String) in dictionaryKey(text).filter { !$0.isWhitespace } }
            // "post hog" → "PostHog" only re-spaces or recases: the spelling alone fixes it.
            let aliases = squashed(heard) == squashed(spelling) ? [] : [heard]
            result.append(TermSuggestion(spelling: spelling, aliases: aliases, apps: apps, projects: projects, reason: .correction(heard: heard)))
        }
        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    // MARK: Review

    /// The suggestions worth showing, best first, at most `limit`. `isKnownWord` says whether the spell checker knows a
    /// word; a suggestion needs at least one word it doesn't, or the shape of a name (PostHog, gob.lin, k8s).
    public static func review(_ candidates: [TermSuggestion], entries: [DictionaryEntry], dismissed: Set<String>,
                              isKnownWord: (String) -> Bool) -> [TermSuggestion] {
        let owned = Set(entries.flatMap { [$0.spelling] + $0.aliases }.map(dictionaryKey))
        var result: [TermSuggestion] = []
        for candidate in candidates {
            guard (try? DictionaryRepository.validated([DictionaryEntry(spelling: candidate.spelling, aliases: candidate.aliases)])) != nil,
                  candidate.spelling.filter(\.isLetter).count >= 3,
                  looksLikeTerm(candidate.spelling, isKnownWord: isKnownWord) || fixesMishearing(candidate, isKnownWord: isKnownWord),
                  !dismissed.contains(candidate.id) else { continue }
            let key = dictionaryKey(candidate.spelling)
            // A known single word as an alias would replace that word everywhere ("cloud" → "Claude").
            let aliases = candidate.aliases.filter { alias in
                let aliasKey = dictionaryKey(alias)
                return aliasKey != key && !owned.contains(aliasKey) && (alias.contains(where: \.isWhitespace) || !isKnownWord(alias))
            }
            var suggestion = TermSuggestion(spelling: candidate.spelling, aliases: aliases, apps: candidate.apps,
                                            projects: candidate.projects, reason: candidate.reason)
            if let existing = entries.first(where: { dictionaryKey($0.spelling) == key }) {
                if existing.applies(in: suggestion.place) {
                    // Already used here; only a new "sounds like" alias is worth offering, in the entry's own place.
                    guard !aliases.isEmpty else { continue }
                    suggestion = TermSuggestion(spelling: existing.spelling, aliases: aliases, apps: existing.apps,
                                                projects: existing.projects, reason: candidate.reason)
                } else if kind(existing) != kind(suggestion) || kind(existing) == .mixed {
                    // Apps and projects combine with AND, so adding an app to a project term would narrow it.
                    suggestion = TermSuggestion(spelling: existing.spelling, aliases: aliases, reason: .everywhere)
                }
            }
            guard !dismissed.contains(suggestion.id) else { continue }
            result.append(suggestion)
        }
        for entry in entries where (entry.projects.count >= 2 && entry.apps.isEmpty) || (entry.apps.count >= 2 && entry.projects.isEmpty) {
            let suggestion = TermSuggestion(spelling: entry.spelling, reason: .everywhere)
            if !dismissed.contains(suggestion.id) { result.append(suggestion) }
        }
        var seen: Set<String> = []
        return result.filter { $0.isEverywhere || entries.active(in: $0.place).count < DictionaryScope.activeLimit }
            .enumerated().sorted { (rank($0.element.reason), $0.offset) < (rank($1.element.reason), $1.offset) }.map(\.element)
            .filter { seen.insert(dictionaryKey($0.spelling)).inserted }
            .prefix(limit).map { $0 }
    }

    private enum Kind { case everywhere, projectOnly, appOnly, mixed }

    private static func kind(_ entry: DictionaryEntry) -> Kind { kind(apps: entry.apps, projects: entry.projects) }
    private static func kind(_ suggestion: TermSuggestion) -> Kind { kind(apps: suggestion.apps, projects: suggestion.projects) }
    private static func kind(apps: [String], projects: [String]) -> Kind {
        switch (apps.isEmpty, projects.isEmpty) {
        case (true, true): .everywhere
        case (true, false): .projectOnly
        case (false, true): .appOnly
        case (false, false): .mixed
        }
    }

    private static func rank(_ reason: TermSuggestion.Reason) -> Int {
        switch reason {
        case .correction: 0
        case .everywhere: 1
        case .projectName: 2
        case .manifest: 3
        case .author: 4
        case .folder: 5
        }
    }

    /// A correction from a word the spell checker doesn't know to a different single word, such as "anasia" →
    /// "panacea": the recognizer missed a term, even one that is also an ordinary word. A known word fixed into
    /// another ("the" → "a"), a phrase ("wanna" → "going to") or a punctuation fix ("dont" → "don't") isn't.
    static func fixesMishearing(_ candidate: TermSuggestion, isKnownWord: (String) -> Bool) -> Bool {
        guard case .correction(let heard) = candidate.reason, !candidate.spelling.contains(where: \.isWhitespace) else { return false }
        let letters = { (text: String) in dictionaryKey(text).filter { $0.isLetter || $0.isNumber } }
        guard letters(heard) != letters(candidate.spelling) else { return false }
        return heard.split(whereSeparator: \.isWhitespace).contains { word in word.contains(where: \.isLetter) && !isKnownWord(String(word)) }
    }

    static func looksLikeTerm(_ spelling: String, isKnownWord: (String) -> Bool) -> Bool {
        let characters = Array(spelling)
        let innerDot = characters.indices.contains { index in
            characters[index] == "." && index > 0 && index < characters.count - 1
                && characters[index - 1].isLetter && (characters[index + 1].isLetter || characters[index + 1].isNumber)
        }
        if innerDot || spelling.contains(where: \.isNumber) { return true }
        let words = spelling.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).map(String.init)
        return words.contains { word in
            (word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)) || !isKnownWord(word)
        }
    }
}

extension Array where Element == DictionaryEntry {
    /// The dictionary after accepting `suggestion`: a new entry, or the entry with the same spelling widened to the
    /// suggestion's place and moved to the end, so it counts as newest.
    public func accepting(_ suggestion: TermSuggestion) -> [DictionaryEntry] {
        let key = dictionaryKey(suggestion.spelling)
        guard let index = firstIndex(where: { dictionaryKey($0.spelling) == key }) else {
            return self + [DictionaryEntry(spelling: suggestion.spelling, aliases: suggestion.aliases, apps: suggestion.apps,
                                           projects: suggestion.projects)]
        }
        var entries = self
        var entry = entries.remove(at: index)
        entry.aliases += suggestion.aliases.filter { alias in !entry.aliases.contains { dictionaryKey($0) == dictionaryKey(alias) } }
        if suggestion.isEverywhere {
            entry.apps = []
            entry.projects = []
        } else if entry.isScoped {
            // An entry used everywhere stays that way; a scope would narrow it.
            entry.apps += suggestion.apps.filter { !entry.apps.contains($0) }
            entry.projects += suggestion.projects.filter { project in
                !entry.projects.contains { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(project) } }
        }
        return entries + [entry]
    }
}
