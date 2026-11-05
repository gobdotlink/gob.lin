import Foundation

public struct DictionaryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var spelling: String
    public var aliases: [String]
    /// Bundle identifiers of the apps this entry is used in. Empty means every app.
    public var apps: [String]
    /// Project names this entry is used in, matched by `DictionaryScope.projectKey`. Empty means every project.
    public var projects: [String]

    public init(id: UUID = UUID(), spelling: String, aliases: [String] = [], apps: [String] = [], projects: [String] = []) {
        self.id = id
        self.spelling = spelling
        self.aliases = aliases
        self.apps = apps
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey { case id, spelling, aliases, apps, projects }

    // Entries saved before app scopes have no `apps` key and apply everywhere.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spelling = try container.decode(String.self, forKey: .spelling)
        aliases = try container.decode([String].self, forKey: .aliases)
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
        projects = try container.decodeIfPresent([String].self, forKey: .projects) ?? []
    }

    // Unscoped entries keep the original file shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(spelling, forKey: .spelling)
        try container.encode(aliases, forKey: .aliases)
        if !apps.isEmpty { try container.encode(apps, forKey: .apps) }
        if !projects.isEmpty { try container.encode(projects, forKey: .projects) }
    }

    /// Whether this entry is limited to particular apps or projects.
    public var isScoped: Bool { !apps.isEmpty || !projects.isEmpty }

    /// Whether dictation in `scope` uses this entry: its app must match (or none is set) and so must its project.
    public func applies(in scope: DictionaryScope) -> Bool {
        (apps.isEmpty || scope.application.map(apps.contains) == true)
            && (projects.isEmpty || scope.project.map { project in
                projects.contains { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(project) } } == true)
    }

    /// Whether dictation into `application` (a bundle identifier, nil when unknown) uses this entry, with no known project.
    public func applies(to application: String?) -> Bool { applies(in: DictionaryScope(application: application)) }

    /// Project and app (3), project (2), app (1), everywhere (0): the more specific, the more it matters where it applies.
    var specificity: Int { (projects.isEmpty ? 0 : 2) + (apps.isEmpty ? 0 : 1) }
}

/// Where a dictation happens: the app it started in and, when gob.lin can tell, the project open there.
public struct DictionaryScope: Codable, Equatable, Hashable, Sendable {
    /// Bundle identifier. "" matches no app (gob.lin itself); nil is unknown.
    public var application: String?
    /// Project name as the app shows it, such as "gob.lin" or "akalikin/gob.lin".
    public var project: String?

    /// Most terms one dictation sends to recognition and Cleanup. Longer lists cost names in the dictionary evaluation:
    /// Cleanup recovered 86/96 with the 16 relevant terms and 74/96 with all 120. Aliases still use every active term.
    // ponytail: measured only at 16 and 120 terms; rerun `dictionary-eval` at 16–64 to tune.
    public static let activeLimit = 32

    public init(application: String? = nil, project: String? = nil) {
        self.application = application
        self.project = project.flatMap { Self.projectKey($0).isEmpty ? nil : $0 }
    }

    /// Project names compare case-insensitively by their last path component, so "akalikin/gob.lin",
    /// "/Users/me/Projects/gob.lin" and "gob.lin" are the same project.
    public static func projectKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        return (trimmed.split(separator: "/").last.map(String.init) ?? trimmed)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension Array where Element == DictionaryEntry {
    /// Entries for every app and project, plus those scoped to `scope`: most specific first, then newest first, so a
    /// limit keeps the terms this app and project need.
    public func active(in scope: DictionaryScope) -> [DictionaryEntry] {
        enumerated().filter { $0.element.applies(in: scope) }
            .sorted { ($0.element.specificity, $0.offset) > ($1.element.specificity, $1.offset) }
            .map(\.element)
    }

    /// The preferred spellings recognition and Cleanup receive in `scope`, at most `DictionaryScope.activeLimit`.
    public func vocabulary(in scope: DictionaryScope) -> [String] {
        active(in: scope).prefix(DictionaryScope.activeLimit).map(\.spelling)
    }

    /// Entries for every app, plus those scoped to `application`, with no known project.
    public func active(in application: String?) -> [DictionaryEntry] { active(in: DictionaryScope(application: application)) }
}

public enum DictionaryError: LocalizedError {
    case invalidTerm, invalidApp, invalidProject, duplicate(String), unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidTerm: "Spellings and aliases must contain words on a single line."
        case .invalidApp: "An app scope must be an application bundle identifier."
        case .invalidProject: "A project scope must be a project name on a single line."
        case .duplicate(let term): "“\(term)” already belongs to a dictionary entry."
        case .unsupportedVersion: "This dictionary was written by a newer version of gob.lin."
        }
    }
}

public struct DictionaryRepository: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var applicationDefault: Self {
        Self(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/dictionary.json"))
    }

    private struct Document: Codable {
        var version = 1
        var entries: [DictionaryEntry]
    }

    public func load() throws -> [DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard [1, 2, 3].contains(document.version) else { throw DictionaryError.unsupportedVersion }
        return try Self.validated(document.entries)
    }

    public func save(_ entries: [DictionaryEntry]) throws {
        let entries = try Self.validated(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Each scope kind raises the version (2: apps, 3: projects), so earlier versions refuse files whose scopes they
        // would drop, and leave them intact, rather than widening the terms to every app or project.
        let version = entries.contains { !$0.projects.isEmpty } ? 3 : entries.contains(where: \.isScoped) ? 2 : 1
        let data = try encoder.encode(Document(version: version, entries: entries))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func validated(_ entries: [DictionaryEntry]) throws -> [DictionaryEntry] {
        var owners: [String: UUID] = [:]
        var ids: Set<UUID> = []
        return try entries.map { entry in
            guard ids.insert(entry.id).inserted else { throw DictionaryError.duplicate(entry.spelling) }
            let spelling = entry.spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for value in [spelling] + aliases {
                guard !value.isEmpty, !value.contains(where: \.isNewline), value.contains(where: { $0.isLetter || $0.isNumber }) else {
                    throw DictionaryError.invalidTerm
                }
                let key = dictionaryKey(value)
                if let owner = owners[key], owner != entry.id { throw DictionaryError.duplicate(value) }
                owners[key] = entry.id
            }
            let apps = entry.apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard apps.allSatisfy({ !$0.contains(where: \.isWhitespace) }) else { throw DictionaryError.invalidApp }
            var projects: [String] = []
            for project in entry.projects.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !project.isEmpty {
                guard !project.contains(where: \.isNewline), !DictionaryScope.projectKey(project).isEmpty else { throw DictionaryError.invalidProject }
                if !projects.contains(where: { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(project) }) { projects.append(project) }
            }
            return DictionaryEntry(id: entry.id, spelling: spelling, aliases: Array(Set(aliases)).sorted(), apps: Array(Set(apps)).sorted(),
                                   projects: projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    public static func importing(_ text: String, into existing: [DictionaryEntry]) throws -> [DictionaryEntry] {
        var entries = existing
        var spellings = Set(existing.map { dictionaryKey($0.spelling) })
        for line in text.components(separatedBy: .newlines) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, spellings.insert(dictionaryKey(term)).inserted else { continue }
            entries.append(DictionaryEntry(spelling: term))
        }
        return try validated(entries)
    }
}

/// Case- and spacing-insensitive identity of a spelling or alias.
func dictionaryKey(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

public struct DictionaryCorrection: Equatable, Sendable {
    public var original: String
    public var replacement: String
    public var entryID: UUID
}

public struct DictionaryCorrectionResult: Equatable, Sendable {
    public var text: String
    public var corrections: [DictionaryCorrection]
}

public enum DictionaryCorrector {
    private struct Token {
        var range: Range<String.Index>
        var key: String
    }

    // Fuzzy correction stays opt-in until the real replay establishes zero ordinary-word regressions.
    public static func correct(_ text: String, entries: [DictionaryEntry], allowFuzzy: Bool = false) -> DictionaryCorrectionResult {
        let tokens = tokenize(text)
        let protected = DictationTextProtection.ranges(in: text)
        let phrases = entries.flatMap { entry in
            entry.aliases.map { (words: dictionaryKey($0).split(separator: " ").map(String.init), entry: entry) }
        }.sorted { $0.words.count > $1.words.count }
        let canonicalPhrases = entries.map { dictionaryKey($0.spelling).split(separator: " ").map(String.init) }
            .sorted { $0.count > $1.count }
        var edits: [(Range<String.Index>, DictionaryCorrection)] = []
        var index = 0
        var fuzzyLockedUntil = 0
        while index < tokens.count {
            if DictationTextProtection.contains(tokens[index].range, in: text, ranges: protected) {
                index += 1
                continue
            }
            var matched = false
            for phrase in phrases where !phrase.words.isEmpty && index + phrase.words.count <= tokens.count {
                let slice = Array(tokens[index..<(index + phrase.words.count)])
                guard slice.map(\.key) == phrase.words else { continue }
                guard zip(slice, slice.dropFirst()).allSatisfy({ left, right in
                    text[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace)
                }) else { continue }
                let range = slice[0].range.lowerBound..<slice[slice.count - 1].range.upperBound
                guard !DictationTextProtection.contains(range, in: text, ranges: protected) else { continue }
                let original = String(text[range])
                let replacement = aliasCapitalization(original, preferred: phrase.entry.spelling)
                if original != replacement {
                    edits.append((range, DictionaryCorrection(original: original, replacement: replacement, entryID: phrase.entry.id)))
                }
                index += slice.count
                matched = true
                break
            }
            if matched { continue }
            // Preferred spellings block fuzzy changes; explicit aliases still take precedence.
            for words in canonicalPhrases where !words.isEmpty && index + words.count <= tokens.count {
                let slice = Array(tokens[index..<(index + words.count)])
                guard slice.map(\.key) == words,
                      zip(slice, slice.dropFirst()).allSatisfy({ left, right in
                          text[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace)
                      }) else { continue }
                let range = slice[0].range.lowerBound..<slice[slice.count - 1].range.upperBound
                guard !DictationTextProtection.contains(range, in: text, ranges: protected) else { continue }
                fuzzyLockedUntil = max(fuzzyLockedUntil, index + words.count)
                break
            }
            let token = tokens[index]
            if allowFuzzy, index >= fuzzyLockedUntil, text[token.range].count >= 5, token.key.allSatisfy(\.isLetter), !commonEnglish.contains(token.key) {
                let candidates = entries.filter {
                    let key = dictionaryKey($0.spelling)
                    return $0.spelling.count >= 5 && key.allSatisfy(\.isLetter) && key != token.key && oneEditApart(token.key, key)
                }
                if candidates.count == 1, let entry = candidates.first {
                    let original = String(text[token.range])
                    let replacement = fuzzyCapitalization(original, preferred: entry.spelling)
                    if replacement != original {
                        edits.append((token.range, DictionaryCorrection(original: original, replacement: replacement, entryID: entry.id)))
                    }
                }
            }
            index += 1
        }
        var result = text
        for (range, correction) in edits.reversed() { result.replaceSubrange(range, with: correction.replacement) }
        return DictionaryCorrectionResult(text: result, corrections: edits.map(\.1))
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor].isLetter || text[cursor].isNumber else { cursor = text.index(after: cursor); continue }
            let start = cursor
            cursor = text.index(after: cursor)
            while cursor < text.endIndex {
                let char = text[cursor]
                if char.isLetter || char.isNumber || char.unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) {
                    cursor = text.index(after: cursor)
                } else if char == "'" || char == "’" {
                    let next = text.index(after: cursor)
                    guard next < text.endIndex, text[next].isLetter else { break }
                    cursor = next
                } else { break }
            }
            let range = start..<cursor
            result.append(Token(range: range, key: dictionaryKey(String(text[range]))))
        }
        return result
    }

    private static func aliasCapitalization(_ original: String, preferred: String) -> String {
        let letters = original.filter(\.isLetter)
        if letters.contains(where: \.isUppercase), letters == letters.uppercased() { return preferred.uppercased() }
        if original.first?.isUppercase == true, preferred == preferred.lowercased() { return uppercasingFirst(preferred) }
        return preferred
    }

    private static func fuzzyCapitalization(_ original: String, preferred: String) -> String {
        if original.contains(where: \.isUppercase), original == original.uppercased() { return preferred.uppercased() }
        if preferred.contains(where: \.isLowercase), preferred.dropFirst().contains(where: \.isUppercase) { return preferred }
        if original == original.lowercased() { return preferred.lowercased() }
        if original.first?.isUppercase == true, original.dropFirst() == original.dropFirst().lowercased() {
            return preferred == preferred.lowercased() ? uppercasingFirst(preferred) : preferred
        }
        return original // Mixed case carries information that a guess must not erase.
    }

    private static func uppercasingFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }

    // Broad protection for common prose; aliases remain the user's explicit override.
    static let commonEnglish = Set("""
    about above accept according across action actually add after again against age ago agree ahead air all allow almost alone along already also although always am among an and animal another answer any anyone anything appear apple apply approach are area around arrive as ask at author available away baby back bad ball bank base be bear beat beautiful because become bed been before began begin behind being believe below best better between beyond big bill bit black blood blue board body book born both box boy break bring brother brought build business but buy by call came can cannot car care carry case catch cause center certain change check child children choose city class clean clear close code cold color come common company complete consider contain continue control could country course cover create current cut dark data daughter day dead deal death decide deep describe design detail develop did difference different difficult dinner do doctor does dog doing done door down draw dream drive during each early earth east easy eat effect either else end enjoy enough enter entire especially even evening ever every everyone everything example expect experience explain eye face fact fall family far fast father fear feel feet fell few field fight figure fill final finally find fine finish fire first fish five floor flow fly focus follow food foot for force form former forward found four free friend from front full future game garden gave general get girl give given glass go goal god goes going gold good got government great green ground group grow growth guess guy had half hand happen happy hard has have having he head hear heard heart heat heavy help her here herself high him himself his history hit hold home hope hot hour house how however human hundred husband i idea if imagine important improve in include information inside instead interest into is issue it its itself job join just keep kept key kid kind king knew know known land language large last late later laugh law lead learn least leave left leg less let letter level life light like likely line list little live local long look lose lost lot love low machine made main major make man many mark market matter may maybe me mean measure meet member men mention might mind minute miss money month more morning most mother move mr much music must my myself name near nearly necessary need never new news next nice night no none nor north not note nothing notice now number of off offer often oh ok old on once one only open operation opinion or order other our out outside over own page paper parent part party pass past pay people per perhaps person pick place plan play please point poor possible power present pretty probably problem process product program project provide public pull put question quick quite race raise ran rather reach read ready real really reason receive record red remain remember report require rest result return right river road room round rule run said same saw say school science sea second see seem seen self send sense sent sentence serve service set several shall she short should show side sign similar simple since single sister sit site six size small smile so social some somebody someone something sometimes son soon sorry sound south space speak special spend stand start state stay step still stop story street strong student study such sure system table take taken talk task teach team technology tell ten term test than thank that the their them themselves then there these they thing think third this those though thought three through time title to today together told too took top total toward town tree true try turn two type under understand until up upon us use used user usually value very view voice wait walk want war warm was watch water way we week well went were west what when where whether which while white who whole whom whose why wide wife will win wind window wish with within without woman women won wonder word work world would write written wrong year yes yet you young your yourself
    ability above abroad absence absolute academic access accident account achieve active activity address advantage advice affect afternoon agency agent agreement aid aim amazing amount analysis angry announce annual anybody anyway apart appeal appearance argument army art article artist attention audience average avoid basic battle beauty became behavior benefit beside beyond birth blame blood bottom brain branch brave bread brief bright budget building burn busy capital captain careful career cash celebration chance chapter character charge cheap choice church citizen claim client clock clothing coffee collect college comfortable command comment community compare competition computer concept condition conference confidence connection consequence construction contact content context contract contribution conversation cooking correct cost council couple court crazy creative crime critical culture customer daily damage danger dark database daughter decision defense degree deliver department describe desire development device direction director discover discussion disease display distance district doubt downtown drink driver drug duty earn education effective effort eight election electric element empty energy engine environment equipment error escape event everybody evidence exactly excellent exchange exercise existence expert extra fair familiar fantastic fault favorite feature feeling female festival fifteen fifty film financial flight flower football foreign forget format forty freedom fresh friendly fruit funny garage gather gentle gift glad global grade gray grocery guide habit hair handle health healthy hello hire holiday honest honor huge ideal identity immediately impact impossible income increase individual industry influence initial injury institution instruction insurance international internet interview introduce investment invite involve island item jacket January July June kitchen lack lady lake launch lawyer leader learning length library license link listener living location machine manager manner material media medical meeting mental message method middle military million modern moment Monday movement movie museum natural nature nearby negative neighbor normal October office official opportunity option orange ordinary original owner package paint pair panel paragraph particular partner pattern peace perfect perform performance period personal phone physical picture piece plenty police policy political popular position positive potential practice prefer prepare president pressure previous private professional property prove purpose quality quickly radio range rate raw reality recent recipe recommend reduce reference region relationship release replace request research resource response responsible review rewrite rich role safety save scene schedule screen security select serious session seven share shopping shoulder silent skill sleep software solution speech spelling spring square standard station store strategy style subject success summer support suppose surface television temporary terrible text thirty thousand Thursday ticket tomorrow tonight tool topic touch training travel treatment trouble Tuesday twenty typical unit update useful usual version video visit vocabulary volume website Wednesday welcome whatever whoever winter wonderful worker worried yesterday zero
    """.split(whereSeparator: \.isWhitespace).map { dictionaryKey(String($0)) })
}
