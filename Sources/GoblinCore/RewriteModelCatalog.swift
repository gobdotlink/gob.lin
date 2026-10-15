import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A model a provider says the key can use.
public struct RewriteModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    /// A readable name when the provider supplies one.
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id; self.name = name
    }
}

/// Lists the chat models a provider offers for a key.
public actor RewriteModelCatalog {
    public init(session: URLSession? = nil) {}

    /// Throws `RewriteFailure`: `.configuration` for an unusable address or missing key,
    /// `.httpStatus` when the provider refuses, `.timeout`, `.transport`, or `.invalidResponse`.
    public func models(for settings: RewriteSettings, apiKey: String) async throws -> [RewriteModelOption] {
        throw RewriteFailure.invalidResponse
    }
}
