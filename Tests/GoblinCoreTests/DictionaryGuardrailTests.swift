import Foundation
import Testing
@testable import GoblinCore

@Test func aliasesMatchWholePhrasesAndPreservePunctuation() {
    let entries = [DictionaryEntry(spelling: "Dev review", aliases: ["day review"])]
    #expect(DictionaryCorrector.correct("day review, then DAY REVIEW.", entries: entries).text == "Dev review, then DEV REVIEW.")
    #expect(DictionaryCorrector.correct("day, review; someday review", entries: entries).text == "day, review; someday review")
    #expect(DictionaryCorrector.correct("day\nreview", entries: entries).text == "Dev review")
    #expect(DictionaryCorrector.correct("postgres and POSTGRES", entries: [DictionaryEntry(spelling: "Postgres")]).text == "Postgres and POSTGRES")
}

@Test func fuzzyNeverChangesCommonOrShortWordsAndIsOffByDefault() {
    let entries = [DictionaryEntry(spelling: "Lisa"), DictionaryEntry(spelling: "auth"), DictionaryEntry(spelling: "Scould"), DictionaryEntry(spelling: "Postgres")]
    let prose = "I like that at all and could see the house."
    #expect(DictionaryCorrector.correct(prose, entries: entries, allowFuzzy: true).text == prose)
    #expect(DictionaryCorrector.correct("postgre", entries: entries).text == "postgre")
    #expect(DictionaryCorrector.correct("postgre", entries: entries, allowFuzzy: true).text == "postgres")
    #expect(DictionaryCorrector.correct("POSTGRE", entries: entries, allowFuzzy: true).text == "POSTGRES")
    #expect(DictionaryCorrector.correct("Postgre", entries: entries, allowFuzzy: true).text == "Postgres")
}

@Test func unicodeAndAmbiguousMatchesStaySafe() throws {
    let entries = [DictionaryEntry(spelling: "Éclair", aliases: ["éclaire"])]
    #expect(DictionaryCorrector.correct("e\u{301}claire", entries: entries).text == "Éclair")
    #expect(DictionaryCorrector.correct("postgre", entries: [DictionaryEntry(spelling: "Postgres"), DictionaryEntry(spelling: "Postgrex")], allowFuzzy: true).text == "postgre")
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
