import Foundation

public struct DictionaryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var spelling: String
    public var aliases: [String]

    public init(id: UUID = UUID(), spelling: String, aliases: [String] = []) {
        self.id = id
        self.spelling = spelling
        self.aliases = aliases
    }
}

public enum DictionaryError: LocalizedError {
    case invalidTerm, duplicate(String), unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidTerm: "Spellings and aliases must contain words on a single line."
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
        guard document.version == 1 else { throw DictionaryError.unsupportedVersion }
        return try Self.validated(document.entries)
    }

    public func save(_ entries: [DictionaryEntry]) throws {
        let entries = try Self.validated(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(entries: entries))
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
            return DictionaryEntry(id: entry.id, spelling: spelling, aliases: Array(Set(aliases)).sorted())
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

private func dictionaryKey(_ text: String) -> String {
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
        let phrases = entries.flatMap { entry in
            ([entry.spelling] + entry.aliases).map { (words: dictionaryKey($0).split(separator: " ").map(String.init), entry: entry) }
        }.sorted { $0.words.count > $1.words.count }
        var edits: [(Range<String.Index>, DictionaryCorrection)] = []
        var index = 0
        while index < tokens.count {
            var matched = false
            for phrase in phrases where !phrase.words.isEmpty && index + phrase.words.count <= tokens.count {
                let slice = Array(tokens[index..<(index + phrase.words.count)])
                guard slice.map(\.key) == phrase.words else { continue }
                guard zip(slice, slice.dropFirst()).allSatisfy({ left, right in
                    text[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace)
                }) else { continue }
                let range = slice[0].range.lowerBound..<slice[slice.count - 1].range.upperBound
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
            let token = tokens[index]
            if allowFuzzy, token.key.count >= 5, token.key.allSatisfy(\.isLetter), !commonEnglish.contains(token.key) {
                let candidates = entries.filter {
                    let key = dictionaryKey($0.spelling)
                    return key.count >= 5 && key.allSatisfy(\.isLetter) && key != token.key && oneEditApart(token.key, key)
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
        if !letters.isEmpty, letters == letters.uppercased() { return preferred.uppercased() }
        if original.first?.isUppercase == true { return uppercasingFirst(preferred) }
        return preferred
    }

    private static func fuzzyCapitalization(_ original: String, preferred: String) -> String {
        if original == original.uppercased() { return preferred.uppercased() }
        if original == original.lowercased() { return preferred.lowercased() }
        if original.first?.isUppercase == true, original.dropFirst() == original.dropFirst().lowercased() {
            return uppercasingFirst(preferred.lowercased())
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
    private static let commonEnglish = Set("""
    about above accept according across action actually add after again against age ago agree ahead air all allow almost alone along already also although always am among an and animal another answer any anyone anything appear apple apply approach are area around arrive as ask at author available away baby back bad ball bank base be bear beat beautiful because become bed been before began begin behind being believe below best better between beyond big bill bit black blood blue board body book born both box boy break bring brother brought build business but buy by call came can cannot car care carry case catch cause center certain change check child children choose city class clean clear close code cold color come common company complete consider contain continue control could country course cover create current cut dark data daughter day dead deal death decide deep describe design detail develop did difference different difficult dinner do doctor does dog doing done door down draw dream drive during each early earth east easy eat effect either else end enjoy enough enter entire especially even evening ever every everyone everything example expect experience explain eye face fact fall family far fast father fear feel feet fell few field fight figure fill final finally find fine finish fire first fish five floor flow fly focus follow food foot for force form former forward found four free friend from front full future game garden gave general get girl give given glass go goal god goes going gold good got government great green ground group grow growth guess guy had half hand happen happy hard has have having he head hear heard heart heat heavy help her here herself high him himself his history hit hold home hope hot hour house how however human hundred husband i idea if imagine important improve in include information inside instead interest into is issue it its itself job join just keep kept key kid kind king knew know known land language large last late later laugh law lead learn least leave left leg less let letter level life light like likely line list little live local long look lose lost lot love low machine made main major make man many mark market matter may maybe me mean measure meet member men mention might mind minute miss money month more morning most mother move mr much music must my myself name near nearly necessary need never new news next nice night no none nor north not note nothing notice now number of off offer often oh ok old on once one only open operation opinion or order other our out outside over own page paper parent part party pass past pay people per perhaps person pick place plan play please point poor possible power present pretty probably problem process product program project provide public pull put question quick quite race raise ran rather reach read ready real really reason receive record red remain remember report require rest result return right river road room round rule run said same saw say school science sea second see seem seen self send sense sent sentence serve service set several shall she short should show side sign similar simple since single sister sit site six size small smile so social some somebody someone something sometimes son soon sorry sound south space speak special spend stand start state stay step still stop story street strong student study such sure system table take taken talk task teach team technology tell ten term test than thank that the their them themselves then there these they thing think third this those though thought three through time title to today together told too took top total toward town tree true try turn two type under understand until up upon us use used user usually value very view voice wait walk want war warm was watch water way we week well went were west what when where whether which while white who whole whom whose why wide wife will win wind window wish with within without woman women won wonder word work world would write written wrong year yes yet you young your yourself
    ability above abroad absence absolute academic access accident account achieve active activity address advantage advice affect afternoon agency agent agreement aid aim amazing amount analysis angry announce annual anybody anyway apart appeal appearance argument army art article artist attention audience average avoid basic battle beauty became behavior benefit beside beyond birth blame blood bottom brain branch brave bread brief bright budget building burn busy capital captain careful career cash celebration chance chapter character charge cheap choice church citizen claim client clock clothing coffee collect college comfortable command comment community compare competition computer concept condition conference confidence connection consequence construction contact content context contract contribution conversation cooking correct cost council couple court crazy creative crime critical culture customer daily damage danger dark database daughter decision defense degree deliver department describe desire development device direction director discover discussion disease display distance district doubt downtown drink driver drug duty earn education effective effort eight election electric element empty energy engine environment equipment error escape event everybody evidence exactly excellent exchange exercise existence expert extra fair familiar fantastic fault favorite feature feeling female festival fifteen fifty film financial flight flower football foreign forget format forty freedom fresh friendly fruit funny garage gather gentle gift glad global grade gray grocery guide habit hair handle health healthy hello hire holiday honest honor huge ideal identity immediately impact impossible income increase individual industry influence initial injury institution instruction insurance international internet interview introduce investment invite involve island item jacket January July June kitchen lack lady lake launch lawyer leader learning length library license link listener living location machine manager manner material media medical meeting mental message method middle military million modern moment Monday movement movie museum natural nature nearby negative neighbor normal October office official opportunity option orange ordinary original owner package paint pair panel paragraph particular partner pattern peace perfect perform performance period personal phone physical picture piece plenty police policy political popular position positive potential practice prefer prepare president pressure previous private professional property prove purpose quality quickly radio range rate raw reality recent recipe recommend reduce reference region relationship release replace request research resource response responsible review rewrite rich role safety save scene schedule screen security select serious session seven share shopping shoulder silent skill sleep software solution speech spelling spring square standard station store strategy style subject success summer support suppose surface television temporary terrible text thirty thousand Thursday ticket tomorrow tonight tool topic touch training travel treatment trouble Tuesday twenty typical unit update useful usual version video visit vocabulary volume website Wednesday welcome whatever whoever winter wonderful worker worried yesterday zero
    """.split(whereSeparator: \.isWhitespace).map { dictionaryKey(String($0)) })
}
