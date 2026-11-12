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
    /// Words the term is said with, which limit its aliases (`DictionaryEntry.context`). Before review, the words
    /// around one fix; after it, the words around two or more.
    public let context: [String]
    /// How many fixes this suggestion comes from.
    public let timesFixed: Int

    public init(spelling: String, aliases: [String] = [], apps: [String] = [], projects: [String] = [], reason: Reason,
                context: [String] = [], timesFixed: Int = 1) {
        self.spelling = spelling
        self.aliases = aliases
        self.apps = apps
        self.projects = projects
        self.reason = reason
        self.context = context
        self.timesFixed = timesFixed
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
    /// suggestion applies in the detected project, or in the app when there is none, and carries the words around the
    /// fix that could be context. Splits on whitespace only, so a term like "gob.lin" stays whole.
    public static func fromCorrection(dictated: String, edited: String, scope: DictionaryScope) -> [TermSuggestion] {
        let apps: [String], projects: [String]
        if let project = scope.project { apps = []; projects = [project] }
        else if let app = scope.application, !app.isEmpty { apps = [app]; projects = [] }
        else { return [] }
        let split = { (text: String) in text.split(whereSeparator: \.isWhitespace).map(String.init) }
        let changes = TextDiff.changes(from: dictated, to: edited, split: split)
        // The edited text's words, and where each replacement sits in them.
        var words: [String] = []
        var fixes: [(heard: String, spelling: String, at: Int)] = []
        for (index, change) in changes.enumerated() {
            switch change {
            case .kept(let text): words += split(text)
            case .removed: break
            case .added(let added):
                if index > 0, case .removed(let removed) = changes[index - 1] {
                    fixes.append((trimmed(removed), trimmed(added), words.count))
                }
                words += split(added)
            }
        }
        var result: [TermSuggestion] = []
        for fix in fixes {
            let heard = fix.heard, spelling = fix.spelling
            let count = { (text: String) in split(text).count }
            guard (1...3).contains(count(heard)), (1...3).contains(count(spelling)), heard != spelling else { continue }
            let squashed = { (text: String) in dictionaryKey(text).filter { !$0.isWhitespace } }
            // "post hog" → "PostHog" only re-spaces or recases: the spelling alone fixes it.
            let aliases = squashed(heard) == squashed(spelling) ? [] : [heard]
            // The corrector's window: three words either side, within the sentence.
            let window = DictionaryCorrector.contextWindow, end = min(words.count, fix.at + count(spelling))
            var lower = fix.at
            while lower > max(0, fix.at - window), !endsSentence(words[lower - 1]) { lower -= 1 }
            var upper = end
            if end > fix.at, !endsSentence(words[end - 1]) {
                while upper < min(words.count, end + window) {
                    upper += 1
                    if endsSentence(words[upper - 1]) { break }
                }
            }
            let nearby = words[lower..<fix.at] + words[end..<upper]
            result.append(TermSuggestion(spelling: spelling, aliases: aliases, apps: apps, projects: projects, reason: .correction(heard: heard),
                                         context: contextWords(Array(nearby))))
        }
        return result
    }

    /// Whether a whitespace-separated chunk ends its sentence, as the corrector judges it: "agent." does, "6.1" doesn't.
    private static func endsSentence(_ chunk: String) -> Bool {
        chunk.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}")).last.map { ".!?;…".contains($0) } ?? false
    }

    /// The words of `chunks` that say what a term is about: a number or version ("6.1"), or a word of three or more
    /// letters that isn't a function word, filler or spoken number. "GPT-6.1" gives "GPT" and "6.1".
    static func contextWords(_ chunks: [String]) -> [String] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols)
        var seen: Set<String> = []
        return chunks.flatMap { $0.split(whereSeparator: { "-/–—".contains($0) }) }
            .map { String($0).trimmingCharacters(in: edges) }
            .filter { word in
                let key = dictionaryKey(word)
                guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return false }
                if key.contains(where: \.isNumber) { return key.allSatisfy { $0.isNumber || $0 == "." || $0.isLetter } }
                return key.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" } && key.filter(\.isLetter).count >= 3 && !contextStopWords.contains(key)
            }
            .filter { seen.insert(dictionaryKey($0)).inserted }
    }

    /// Words too common to say what is being talked about.
    static let contextStopWords = Set("""
    the and for with you your yours are was were that this these those have has had from but not can will just like all
    any get got our out its it's also then than them they their there here what when where which who whom how why use
    using used into onto about some very really would could should been being did does doing done make made want need
    okay yeah yes sure hmm let lets let's she her hers his him one two three four five six seven eight nine ten eleven
    twelve zero now well see say said thing things way bit lot kind sort actually basically maybe because thats that's
    what's i'm i've i'll i'd don't doesn't didn't can't won't isn't aren't wasn't over under more most much many other
    another each every same such only even still again back off down too try going gonna wanna gotta take put give
    look know think mean tell keep come came went via per ask point dot something anything everything nothing
    """.split(whereSeparator: \.isWhitespace).map(String.init))

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
        for candidate in combiningFixes(candidates, isKnownWord: isKnownWord) {
            guard (try? DictionaryRepository.validated([DictionaryEntry(spelling: candidate.spelling, aliases: candidate.aliases)])) != nil,
                  candidate.spelling.filter(\.isLetter).count >= 3,
                  !dismissed.contains(candidate.id) else { continue }
            let key = dictionaryKey(candidate.spelling)
            let existing = entries.first { dictionaryKey($0.spelling) == key }
            // A known single word as an alias would replace that word everywhere ("cloud" → "Claude"), unless context
            // limits it. An entry's context applies to all its aliases, so it never changes on an entry that has
            // aliases: context can't limit aliases that apply everywhere, and new context would widen restricted ones.
            // A restricted entry takes an ordinary word only when the fixes were heard near its own context.
            func ordinary(_ alias: String) -> Bool { !alias.contains(where: \.isWhitespace) && isKnownWord(alias) }
            let canLimit: Bool
            if let existing, !existing.context.isEmpty {
                let current = Set(existing.context.map(dictionaryKey))
                canLimit = candidate.context.contains { current.contains(dictionaryKey($0)) }
            } else {
                canLimit = !candidate.context.isEmpty && (existing?.aliases.isEmpty ?? true)
            }
            let aliases = candidate.aliases.filter { alias in
                let aliasKey = dictionaryKey(alias)
                return aliasKey != key && !owned.contains(aliasKey) && (!ordinary(alias) || canLimit)
            }
            let context = aliases.contains(where: ordinary) && existing.map({ $0.context.isEmpty }) ?? true ? candidate.context : []
            var suggestion = TermSuggestion(spelling: candidate.spelling, aliases: aliases, apps: candidate.apps,
                                            projects: candidate.projects, reason: candidate.reason, context: context,
                                            timesFixed: candidate.timesFixed)
            if let existing {
                if existing.applies(in: suggestion.place) {
                    // Already used here; only a new "sounds like" alias is worth offering, in the entry's own place.
                    guard !aliases.isEmpty else { continue }
                    suggestion = TermSuggestion(spelling: existing.spelling, aliases: aliases, apps: existing.apps,
                                                projects: existing.projects, reason: candidate.reason, context: context,
                                                timesFixed: candidate.timesFixed)
                } else if kind(existing) != kind(suggestion) || kind(existing) == .mixed {
                    // Apps and projects combine with AND, so adding an app to a project term would narrow it.
                    suggestion = TermSuggestion(spelling: existing.spelling, aliases: aliases, reason: .everywhere, context: context,
                                                timesFixed: candidate.timesFixed)
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

    /// Most context words a suggestion learns.
    static let contextLimit = 4

    /// One suggestion per fixed spelling, newest fix first, keeping only spellings that look like a term or fix a
    /// mishearing. Its aliases are what those fixes heard, its context the words seen around two or more fixes of it,
    /// and fixes in two or more places make it a suggestion for everywhere. Other candidates pass through unchanged.
    static func combiningFixes(_ candidates: [TermSuggestion], isKnownWord: (String) -> Bool) -> [TermSuggestion] {
        var groups: [String: [TermSuggestion]] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard case .correction = candidate.reason else { continue }
            let key = dictionaryKey(candidate.spelling)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(candidate)
        }
        var combined: [String: TermSuggestion] = [:]
        for key in order {
            let fixes = groups[key] ?? []
            let isTerm = fixes.first.map { looksLikeTerm($0.spelling, isKnownWord: isKnownWord) } ?? false
            let heard = fixes.filter { isTerm || fixesMishearing($0, isKnownWord: isKnownWord) }
            guard let newest = heard.first else { continue }
            // The spelling written most often; ties go to the newest.
            let spellings = fixes.map(\.spelling)
            let spelling = spellings.max { lhs, rhs in
                let (a, b) = (spellings.filter { $0 == lhs }.count, spellings.filter { $0 == rhs }.count)
                return a != b ? a < b : spellings.firstIndex(of: lhs)! > spellings.firstIndex(of: rhs)!
            } ?? newest.spelling
            var aliasKeys: Set<String> = []
            let aliases = heard.flatMap(\.aliases).filter { aliasKeys.insert(dictionaryKey($0)).inserted }
            var counts: [String: Int] = [:], surfaces: [String: String] = [:], seen: [String] = []
            for fix in fixes {
                for word in Set(fix.context.map(dictionaryKey)) { counts[word, default: 0] += 1 }
                for word in fix.context where surfaces[dictionaryKey(word)] == nil {
                    surfaces[dictionaryKey(word)] = word
                    seen.append(dictionaryKey(word))
                }
            }
            let context = seen.filter { (counts[$0] ?? 0) >= 2 && $0 != key && !aliasKeys.contains($0) }
                .enumerated().sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
                .prefix(contextLimit).compactMap { surfaces[$0.element] }
            let places = Set(fixes.map { $0.id.split(separator: "|", omittingEmptySubsequences: false).dropFirst().joined(separator: "|") })
            combined[key] = TermSuggestion(spelling: spelling, aliases: aliases, apps: places.count > 1 ? [] : newest.apps,
                                           projects: places.count > 1 ? [] : newest.projects, reason: newest.reason,
                                           context: Array(context), timesFixed: fixes.count)
        }
        var emitted: Set<String> = []
        return candidates.compactMap { candidate in
            guard case .correction = candidate.reason else {
                return looksLikeTerm(candidate.spelling, isKnownWord: isKnownWord) ? candidate : nil
            }
            let key = dictionaryKey(candidate.spelling)
            guard emitted.insert(key).inserted else { return nil }
            return combined[key]
        }
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

    /// A correction to a different single word that the recognizer got wrong: from a word the spell checker doesn't
    /// know ("anasia" → "panacea"), or from a real word that sounds like an uncommon one ("clawed" → "claude"). A known
    /// word fixed into an unrelated or everyday one ("the" → "a", "then" → "than"), a phrase ("wanna" → "going to"),
    /// another form of the word ("candidate" → "candidates") or a punctuation fix ("dont" → "don't") isn't.
    static func fixesMishearing(_ candidate: TermSuggestion, isKnownWord: (String) -> Bool) -> Bool {
        guard case .correction(let heard) = candidate.reason, !candidate.spelling.contains(where: \.isWhitespace) else { return false }
        let letters = { (text: String) in dictionaryKey(text).filter { $0.isLetter || $0.isNumber } }
        let from = letters(heard), to = letters(candidate.spelling)
        guard from != to else { return false }
        let words = heard.split(whereSeparator: \.isWhitespace)
        if words.contains(where: { word in word.contains(where: \.isLetter) && !isKnownWord(String(word)) }) { return true }
        return words.count == 1 && candidate.spelling.allSatisfy(\.isLetter) && !DictionaryCorrector.commonEnglish.contains(to)
            && soundsAlike(from, to)
    }

    private static let wordEndings: Set<String> = ["", "e", "s", "es", "d", "ed", "ing", "er", "ly", "y", "ies", "ied", "ion"]

    /// Two lowercased words close enough to be misheard for each other: the same first letter, at most half the letters
    /// changed, and not two forms of one word.
    static func soundsAlike(_ first: String, _ second: String) -> Bool {
        guard first.first == second.first, let distance = EditObservation.graphemeDistance(first, second),
              distance * 2 <= max(first.count, second.count) else { return false }
        let stem = first.commonPrefix(with: second).count
        let endings: Set<String> = [String(first.dropFirst(stem)), String(second.dropFirst(stem))]
        // A dropped final "e" makes another word, not another form: "sole" and "sol", "hope" and "hop".
        return endings == ["", "e"] || !wordEndings.isSuperset(of: endings)
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
                                           projects: suggestion.projects, context: suggestion.context)]
        }
        var entries = self
        var entry = entries.remove(at: index)
        entry.aliases += suggestion.aliases.filter { alias in !entry.aliases.contains { dictionaryKey($0) == dictionaryKey(alias) } }
        entry.context += suggestion.context.filter { word in !entry.context.contains { dictionaryKey($0) == dictionaryKey(word) } }
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
