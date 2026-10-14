import Foundation
import GoblinCore

private enum FixtureFailure: Error { case denied }

@main
struct RewriteCredentialChecks {
    static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected unavailable credential") }
        catch { }
    }

    @MainActor
    static func main() throws {
        var settings = RewriteSettings(enabled: true)
        settings.selectProvider(.cerebras)
        var reads: [URL] = []
        var storedKey = "synthetic-key"
        var denied = false
        let credentials = RewriteCredentials { snapshot in
            reads.append(try snapshot.endpoint())
            if denied { throw FixtureFailure.denied }
            return storedKey
        }

        rejected { _ = try credentials.key(for: settings) }
        require(reads.isEmpty, "A submission before preparation must never access Keychain")
        try credentials.prepare(for: settings)
        require(reads == [try settings.endpoint()], "Authorize the active provider at launch")
        // Model, tone and unrelated preference changes must not reauthorize the same key.
        settings.model = "another-model"
        try credentials.prepare(for: settings)
        for _ in 0..<3 {
            require(try credentials.key(for: settings) == storedKey, "Reuse even a one-read grant")
        }
        require(reads.count == 1, "Voice submissions must not read Keychain again")

        settings.selectProvider(.groq)
        rejected { _ = try credentials.key(for: settings) }
        require(reads.count == 1, "An unprepared endpoint must not prompt during submission")
        try credentials.prepare(for: settings)
        require(reads.last == (try settings.endpoint()) && reads.count == 2, "Prepare a changed provider before use")

        storedKey = "replacement-key"
        credentials.reset()
        try credentials.prepare(for: settings)
        require(try credentials.key(for: settings) == storedKey, "Saving a replacement must invalidate the old key")
        storedKey = ""
        credentials.reset()
        try credentials.prepare(for: settings)
        require(try credentials.key(for: settings) == "", "Deleting a key must discard the cached credential")

        denied = true
        credentials.reset()
        rejected { try credentials.prepare(for: settings) }
        let readsAfterDenial = reads.count
        try credentials.prepare(for: settings)
        for _ in 0..<3 { rejected { _ = try credentials.key(for: settings) } }
        require(reads.count == readsAfterDenial, "Denied access must not cause repeated prompts")
        denied = false
        credentials.reset()
        try credentials.prepare(for: settings)
        require(reads.count == readsAfterDenial + 1, "Saving settings provides an explicit retry")

        settings.enabled = false
        try credentials.prepare(for: settings)
        rejected { _ = try credentials.key(for: settings) }
        settings.enabled = true
        settings.cleanup = .none
        try credentials.prepare(for: settings)
        require(reads.count == readsAfterDenial + 1, "Disabled cleanup must not access Keychain")

        settings.cleanup = .light
        var relaunchReads = 0
        let relaunched = RewriteCredentials { _ in relaunchReads += 1; return "relaunch-key" }
        try relaunched.prepare(for: settings)
        require(relaunchReads == 1, "An updated app must preflight again on relaunch")
        require(try relaunched.key(for: settings) == "relaunch-key", "Relaunched dictation uses the prepared key")
        print("PASS launch authorization, prompt-free submissions, denial, key changes and relaunch checks (synthetic credentials only)")
    }
}
