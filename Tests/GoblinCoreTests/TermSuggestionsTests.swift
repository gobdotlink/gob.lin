import Foundation
import Testing
@testable import GoblinCore

private let known: Set<String> = ["window", "sources", "tests", "docs", "app", "the", "go", "post", "hog", "use", "we", "it", "daily", "feedback", "media", "panacea", "going", "to", "don't", "a", "codec", "codex", "clawed", "claude", "soul", "sol", "candidate", "candidates", "sourcing", "sourced", "there", "they're", "then", "than", "want", "wanted"]
private func isKnown(_ word: String) -> Bool { known.contains(word.lowercased()) }
private func review(_ candidates: [TermSuggestion], _ entries: [DictionaryEntry] = [], dismissed: Set<String> = []) -> [TermSuggestion] {
    TermSuggestions.review(candidates, entries: entries, dismissed: dismissed, isKnownWord: isKnown)
}

@Test func repositoriesSuggestTheirNamesManifestsAndFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-suggest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in ["Sources", "GoblinCore", "node_modules", ".build", "Goblin.xcodeproj"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try #"let package = Package(name: "Goblin", targets: [.target(name: "GoblinCore")])"#.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"{"name": "@akalikin/feedback-media", "version": "1.0.0"}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let candidates = TermSuggestions.fromRepository(root: root, project: "akalikin/gob.lin")
    // No .git in the fixture, so no authors.
    #expect(candidates.map(\.spelling) == ["gob.lin", "Goblin", "feedback-media", "GoblinCore", "Sources"])
    #expect(candidates.map(\.reason) == [.projectName, .manifest("Package.swift"), .manifest("package.json"), .folder, .folder])
    #expect(candidates.allSatisfy { $0.projects == ["akalikin/gob.lin"] && $0.apps.isEmpty })
    // "Sources" is a known word, and "feedback-media" is made of them.
    #expect(review(candidates).map(\.spelling) == ["gob.lin", "Goblin", "GoblinCore"])
}

@Test func correctionsSuggestTheFixedSpellingInTheProjectOrApp() {
    let project = TermSuggestions.fromCorrection(dictated: "we use go blin daily.", edited: "we use gob.lin daily.",
                                                 scope: DictionaryScope(application: "dev.zed.Zed", project: "gob.lin"))
    #expect(project.count == 1)
    #expect(project.first.map { ($0.spelling, $0.aliases, $0.apps, $0.projects) } ?? ("", [], [], []) == ("gob.lin", ["go blin"], [], ["gob.lin"]))
    #expect(project.first?.reason == .correction(heard: "go blin"))
    // Re-spacing or recasing needs no alias; without a project the app is the place.
    let app = TermSuggestions.fromCorrection(dictated: "it's post hog,", edited: "it's PostHog,", scope: DictionaryScope(application: "com.tinyspeck.slackmacgap"))
    #expect(app.map(\.spelling) == ["PostHog"] && app[0].aliases.isEmpty && app[0].apps == ["com.tinyspeck.slackmacgap"])
    #expect(TermSuggestions.fromCorrection(dictated: "go blin", edited: "gob.lin", scope: DictionaryScope(application: "")).isEmpty)
    // Long rewrites aren't term fixes.
    #expect(TermSuggestions.fromCorrection(dictated: "one two three four", edited: "five six", scope: DictionaryScope(application: "a")).isEmpty)
}

@Test func reviewKeepsOnlyNewTermLikeSpellings() {
    let place = ["gob.lin"]
    let candidates = [
        TermSuggestion(spelling: "window", projects: place, reason: .folder),
        TermSuggestion(spelling: "Luna", projects: place, reason: .folder),
        TermSuggestion(spelling: "PostHog", projects: place, reason: .author),
        TermSuggestion(spelling: "Neo4j", projects: place, reason: .folder),
        TermSuggestion(spelling: "ab", projects: place, reason: .folder),
        TermSuggestion(spelling: "Kalikin", projects: place, reason: .author),
        TermSuggestion(spelling: "Daubney", aliases: ["window", "dawb knee"], projects: place, reason: .correction(heard: "window")),
    ]
    let entries = [DictionaryEntry(spelling: "Luna", projects: ["akalikin/gob.lin"]), DictionaryEntry(spelling: "Zed", aliases: ["dawb knee"])]
    let kept = review(candidates, entries, dismissed: [candidates[5].id])
    // Known words, short and existing terms, dismissed ones and aliases another entry owns are dropped.
    #expect(kept.map(\.spelling) == ["Daubney", "PostHog", "Neo4j"])
    #expect(kept[0].aliases.isEmpty)
}

@Test func reviewWidensToEverywhereAndNeverNarrows() {
    let luna = DictionaryEntry(spelling: "Luna", projects: ["gob.lin"])
    // The same kind of place: offered for the second project, then for everywhere once it has two.
    let second = review([TermSuggestion(spelling: "Luna", projects: ["harbor"], reason: .projectName)], [luna])
    #expect(second.map(\.projects) == [["harbor"]])
    let widened = [luna].accepting(second[0])
    #expect(widened.map(\.projects) == [["gob.lin", "harbor"]])
    #expect(review([], widened).map(\.reason) == [.everywhere])
    #expect([luna].accepting(TermSuggestion(spelling: "luna", reason: .everywhere)).allSatisfy { !$0.isScoped })
    // A project term heard in an app becomes "everywhere?", never a project-and-app term.
    let app = review([TermSuggestion(spelling: "Luna", aliases: ["loona"], apps: ["com.tinyspeck.slackmacgap"], reason: .correction(heard: "loona"))], [luna])
    #expect(app.count == 1 && app[0].isEverywhere && app[0].reason == .everywhere && app[0].aliases == ["loona"])
    let accepted = [luna].accepting(app[0])
    #expect(accepted.count == 1 && !accepted[0].isScoped && accepted[0].aliases == ["loona"])
    // An alias for a term already used here stays in the term's own place.
    let alias = review([TermSuggestion(spelling: "Luna", aliases: ["loona"], projects: ["gob.lin"], reason: .correction(heard: "loona"))], [luna])
    #expect(alias.map(\.projects) == [["gob.lin"]] && [luna].accepting(alias[0])[0].projects == ["gob.lin"])
}

@Test func reviewRespectsTheBudgetAndTheLimit() {
    let full = (0..<DictionaryScope.activeLimit).map { DictionaryEntry(spelling: "Term\($0)", projects: ["gob.lin"]) }
    let candidates = (0..<12).map { TermSuggestion(spelling: "Name\($0)", projects: ["gob.lin"], reason: .author) }
    #expect(review(candidates, full).isEmpty)
    #expect(review(candidates, Array(full.dropFirst())).count == TermSuggestions.limit)
    // Corrections come first.
    let correction = TermSuggestion(spelling: "Kalikin", projects: ["gob.lin"], reason: .correction(heard: "calicut"))
    #expect(review(candidates + [correction]).first == correction)
}

@Test func correctionsOfUnknownWordsKeepOrdinarySpellings() {
    let scope = DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin")
    func corrected(_ dictated: String, _ edited: String) -> [TermSuggestion] {
        review(TermSuggestions.fromCorrection(dictated: dictated, edited: edited, scope: scope))
    }
    // "panacea" is a dictionary word, but the recognizer heard a non-word, so it is a missed term.
    let kept = corrected("with the anasia local review skill", "with the panacea local review skill")
    #expect(kept.map { ($0.spelling, $0.aliases, $0.projects) } .first ?? ("", [], []) == ("panacea", ["anasia"], ["gob.lin"]))
    // Known words fixed into known words, phrases and punctuation fixes stay out.
    #expect(corrected("use the window", "use the sources").isEmpty)
    #expect(corrected("we wanna go", "we going to go").isEmpty)
    #expect(corrected("we dont go", "we don't go").isEmpty)
    // Without a correction behind it, a known word is still not a term.
    #expect(review([TermSuggestion(spelling: "panacea", projects: ["gob.lin"], reason: .folder)]).isEmpty)
}

@Test func correctionsBetweenSoundAlikeWordsAreTerms() {
    let scope = DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin")
    func corrected(_ dictated: String, _ edited: String) -> [TermSuggestion] {
        review(TermSuggestions.fromCorrection(dictated: dictated, edited: edited, scope: scope))
    }
    // Both fixes in one edit are kept. A known word as an alias would rewrite it everywhere, so only the spelling is.
    let kept = corrected("like a codec sub but not a clawed sub", "like a codex sub but not a claude sub")
    #expect(kept.map(\.spelling) == ["codex", "claude"])
    #expect(kept.map(\.aliases) == [[], []])
    #expect(corrected("the soul model", "the sol model").map(\.spelling) == ["sol"])
    // Other forms of a word, everyday words, contractions and phrases are grammar, not mishearings.
    #expect(corrected("one candidate", "one candidates").isEmpty)
    #expect(corrected("we sourcing them", "we sourced them").isEmpty)
    #expect(corrected("better then that", "better than that").isEmpty)
    #expect(corrected("there going", "they're going").isEmpty)
    #expect(corrected("we want to go", "we wanted go").isEmpty)
}
