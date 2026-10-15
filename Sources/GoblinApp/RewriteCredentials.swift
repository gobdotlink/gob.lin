import Foundation
import GoblinCore

/// Load the key before dictation, then reuse the credential (or failure) for this launch.
/// Keeps voice submissions prompt-free once keys move back to Keychain (see RewriteKeyStore).
@MainActor
final class RewriteCredentials {
    private let load: (RewriteSettings) throws -> String
    private var endpoint: URL?
    private var credential: Result<String, Error>?

    init(load: @escaping (RewriteSettings) throws -> String = { try RewriteKeyStore.load(for: $0) }) {
        self.load = load
    }

    func prepare(for settings: RewriteSettings) throws {
        guard settings.enabled, settings.cleanup != .none else { reset(); return }
        let endpoint = try settings.endpoint()
        guard self.endpoint != endpoint else { return }
        self.endpoint = endpoint
        let result = Result { try load(settings) }
        credential = result
        _ = try result.get()
    }

    /// Never read the key store here: processing a transcript must not open an auth dialog.
    func key(for settings: RewriteSettings) throws -> String {
        guard endpoint == (try settings.endpoint()), let credential else {
            throw RewriteFailure.configuration("Save AI cleanup settings to authorize the provider key before dictating.")
        }
        return try credential.get()
    }

    func reset() { endpoint = nil; credential = nil }
}
