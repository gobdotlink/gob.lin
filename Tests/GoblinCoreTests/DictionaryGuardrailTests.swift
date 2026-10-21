import Foundation
import Testing
@testable import GoblinCore

@Test func aliasesMatchWholePhrasesAndPreservePunctuation() {
    let entries = [DictionaryEntry(spelling: "Dev review", aliases: ["day review"])]
    #expect(DictionaryCorrector.correct("day review, then DAY REVIEW.", entries: entries).text == "Dev review, then DEV REVIEW.")
    #expect(DictionaryCorrector.correct("day, review; someday review", entries: entries).text == "day, review; someday review")
    #expect(DictionaryCorrector.correct("day\nreview", entries: entries).text == "Dev review")
    #expect(DictionaryCorrector.correct("a swift linear reply; go ahead", entries: [DictionaryEntry(spelling: "Swift"), DictionaryEntry(spelling: "Linear"), DictionaryEntry(spelling: "Go")]).text == "a swift linear reply; go ahead")
    let protected = "`let x = day review` and ```swift\nlet x = day review\n``` and https://postgre.example/day/review dev@postgre.io src/postgre.txt postgre_value postgre-based C:\\tmp\\postgre.txt"
    #expect(DictionaryCorrector.correct(protected, entries: entries + [DictionaryEntry(spelling: "Postgres", aliases: ["postgre"])], allowFuzzy: true).text == protected)
    #expect(DictionaryCorrector.correct("(day review), then postgre!", entries: entries + [DictionaryEntry(spelling: "Postgres", aliases: ["postgre"])]).text == "(Dev review), then Postgres!")
    #expect(DictionaryCorrector.correct("Eye phone", entries: [DictionaryEntry(spelling: "iPhone", aliases: ["eye phone"])]).text == "iPhone")
    #expect(DictionaryCorrector.correct("Node package manager", entries: [DictionaryEntry(spelling: "npm", aliases: ["node package manager"])]).text == "Npm")
    #expect(DictionaryCorrector.correct("Acme cloud sync", entries: [DictionaryEntry(spelling: "Acme cloud"), DictionaryEntry(spelling: "CloudSync", aliases: ["cloud sync"])]).text == "Acme CloudSync")
}

@Test func fuzzyNeverChangesCommonOrShortWordsAndIsOffByDefault() {
    let entries = [DictionaryEntry(spelling: "Lisa"), DictionaryEntry(spelling: "auth"), DictionaryEntry(spelling: "Scould"), DictionaryEntry(spelling: "Postgres")]
    let prose = "I like that at all and could see the house."
    #expect(DictionaryCorrector.correct(prose, entries: entries, allowFuzzy: true).text == prose)
    #expect(DictionaryCorrector.correct("postgre", entries: entries).text == "postgre")
    #expect(DictionaryCorrector.correct("postgre", entries: entries, allowFuzzy: true).text == "postgres")
    #expect(DictionaryCorrector.correct("POSTGRE", entries: entries, allowFuzzy: true).text == "POSTGRES")
    #expect(DictionaryCorrector.correct("Postgre", entries: entries, allowFuzzy: true).text == "Postgres")
    #expect(DictionaryCorrector.correct("Groß", entries: [DictionaryEntry(spelling: "Große")], allowFuzzy: true).text == "Groß")
    #expect(DictionaryCorrector.correct("Große", entries: [DictionaryEntry(spelling: "Groß")], allowFuzzy: true).text == "Große")
    #expect(DictionaryCorrector.correct("iphonee", entries: [DictionaryEntry(spelling: "iPhone")], allowFuzzy: true).text == "iPhone")
}

@Test func unicodeAndAmbiguousMatchesStaySafe() throws {
    let entries = [DictionaryEntry(spelling: "Éclair", aliases: ["éclaire"])]
    #expect(DictionaryCorrector.correct("e\u{301}claire", entries: entries).text == "Éclair")
    #expect(DictionaryCorrector.correct("postgre", entries: [DictionaryEntry(spelling: "Postgres"), DictionaryEntry(spelling: "Postgrex")], allowFuzzy: true).text == "postgre")
    #expect(DictionaryCorrector.correct("Postgres", entries: [DictionaryEntry(spelling: "Postgres"), DictionaryEntry(spelling: "Postgrex")], allowFuzzy: true).text == "Postgres")
    #expect(DictionaryCorrector.correct("アイフォン", entries: [DictionaryEntry(spelling: "iPhone", aliases: ["アイフォン"])]).text == "iPhone")
    #expect(throws: DictionaryError.self) {
        try DictionaryRepository.validated([DictionaryEntry(spelling: "One", aliases: ["same"]), DictionaryEntry(spelling: "Two", aliases: ["SAME"])])
    }
}

@Test func dictionarySaveLoadImportAndCorruptFileProtection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DictionaryRepository(url: directory.appendingPathComponent("dictionary.json"))
    let entries = try DictionaryRepository.importing("Postgres\n\nSwift\nPostgres", into: [])
    try repository.save(entries)
    #expect(try repository.load() == entries)
    try Data("bad json".utf8).write(to: repository.url)
    #expect(throws: (any Error).self) { try repository.load() }
    #expect(try String(contentsOf: repository.url, encoding: .utf8) == "bad json")
}

@Test func appScopesSelectEntriesAndKeepOlderFilesCompatible() throws {
    let everywhere = DictionaryEntry(spelling: "Postgres")
    let coding = DictionaryEntry(spelling: "PostHog", apps: ["com.t3tools.t3code", "sh.paseo.app"])
    let writing = DictionaryEntry(spelling: "Lisa", apps: ["com.microsoft.Word"])
    let entries = [everywhere, coding, writing]
    #expect(entries.active(in: "com.t3tools.t3code").map(\.spelling) == ["PostHog", "Postgres"])
    #expect(entries.active(in: "com.microsoft.Word").map(\.spelling) == ["Lisa", "Postgres"])
    #expect(entries.active(in: "com.apple.Notes").map(\.spelling) == ["Postgres"])
    #expect(entries.active(in: nil).map(\.spelling) == ["Postgres"])

    // Files written before app scopes have no `apps` key; unscoped entries are still written without one.
    let legacy = #"{"version":1,"entries":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","spelling":"Kalikin","aliases":["calican"]}]}"#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-scopes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(legacy.utf8).write(to: url)
    let repository = DictionaryRepository(url: url)
    let loaded = try repository.load()
    #expect(loaded.count == 1 && loaded[0].apps.isEmpty && loaded[0].applies(to: "any.app"))
    try repository.save(loaded)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("apps"))

    try repository.save([DictionaryEntry(id: loaded[0].id, spelling: "Kalikin", apps: [" sh.paseo.app ", "com.t3tools.t3code", "sh.paseo.app"])])
    #expect(try repository.load()[0].apps == ["com.t3tools.t3code", "sh.paseo.app"])
    // Scoped files are version 2 so earlier versions refuse them instead of silently dropping the scopes.
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""version" : 2"#))
    try repository.save([DictionaryEntry(id: loaded[0].id, spelling: "Kalikin")])
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""version" : 1"#))
    #expect(throws: DictionaryError.self) { try DictionaryRepository.validated([DictionaryEntry(spelling: "Luna", apps: ["not a bundle id"])]) }

    // History keeps the app dictation started in; entries saved before that field fall back to their target.
    var history = HistoryEntry(rawText: "a", finalText: "a", targetBundleIdentifier: "com.microsoft.Word",
                               dictionaryBundleIdentifier: "com.t3tools.t3code")
    #expect(history.dictionaryScope == "com.t3tools.t3code")
    history.dictionaryBundleIdentifier = ""
    #expect(entries.active(in: history.dictionaryScope).map(\.spelling) == ["Postgres"])
    history.dictionaryBundleIdentifier = nil
    #expect(history.dictionaryScope == "com.microsoft.Word")
    let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(history))
    #expect(decoded.dictionaryBundleIdentifier == nil && decoded.dictionaryScope == "com.microsoft.Word")
}
