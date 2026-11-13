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
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRewriteRedirects(), delegateQueue: nil)
        }
    }

    /// Throws `RewriteFailure`: `.configuration` for an unusable address,
    /// `.httpStatus` when the provider refuses, `.timeout`, `.transport`, or `.invalidResponse`.
    /// A missing key is sent as no key: some lists are public and local servers need none.
    public func models(for settings: RewriteSettings, apiKey: String) async throws -> [RewriteModelOption] {
        let endpoint = try settings.modelsEndpoint()
        var pages: [Data] = []
        var after: String?
        // Anthropic pages its list; other providers return it whole.
        for _ in 0..<(settings.provider == .anthropic ? 5 : 1) {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            if settings.provider == .anthropic {
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            }
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(GoblinMetadata.userAgent, forHTTPHeaderField: "User-Agent")
            for (field, value) in settings.provider.authorizationHeaders(apiKey: apiKey) { request.setValue(value, forHTTPHeaderField: field) }
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError { throw error.code == .timedOut ? RewriteFailure.timeout : .transport }
            guard let response = response as? HTTPURLResponse else { throw RewriteFailure.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw RewriteFailure.httpStatus(response.statusCode) }
            pages.append(data)
            struct Cursor: Decodable { var has_more: Bool?; var last_id: String? }
            guard let cursor = try? JSONDecoder().decode(Cursor.self, from: data), cursor.has_more == true, let last = cursor.last_id else { break }
            after = last
        }
        return try Self.parse(pages)
    }

    /// Accepts `{"data": [...]}` or a bare array of model objects or id strings. Drops non-chat models, dedupes and sorts.
    static func parse(_ pages: [Data]) throws -> [RewriteModelOption] {
        var options: [String: RewriteModelOption] = [:]
        for page in pages {
            let json = try? JSONSerialization.jsonObject(with: page)
            guard let entries = (json as? [String: Any])?["data"] as? [Any] ?? json as? [Any] else { throw RewriteFailure.invalidResponse }
            for entry in entries {
                let fields = entry as? [String: Any] ?? [:]
                guard var id = (entry as? String ?? fields["id"] as? String ?? fields["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                if id.hasPrefix("models/") { id.removeFirst("models/".count) }
                guard !id.isEmpty, options[id] == nil, isChat(id, fields) else { continue }
                let name = (fields["display_name"] ?? fields["name"]) as? String
                options[id] = RewriteModelOption(id: id, name: name == id ? nil : name)
            }
        }
        return options.values.sorted { $0.id.caseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // Provider metadata decides when present; otherwise only clearly non-text ids are dropped. Unsure means keep:
    // the model field still accepts any typed id.
    private static func isChat(_ id: String, _ fields: [String: Any]) -> Bool {
        if fields["active"] as? Bool == false || fields["lifecycle"] as? String == "retired" { return false }
        if let output = (fields["architecture"] as? [String: Any])?["output_modalities"] as? [String] { return output.contains("text") }
        if let chat = (fields["capabilities"] as? [String: Any])?["completion_chat"] as? Bool { return chat }
        if let api = fields["api"] as? String { return api == "chat" }
        if let type = fields["type"] as? String {
            if type == "language" { return true }
            if ["embedding", "image", "video", "speech", "transcription", "realtime", "reranking", "evaluation"].contains(type) { return false }
        }
        let id = id.lowercased()
        let words = Set(id.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !["whisper", "embed", "rerank", "moderation", "transcri", "realtime", "dall-e", "imagen", "imagine"].contains { id.contains($0) }
            && words.isDisjoint(with: ["tts", "stt", "asr", "image", "video", "speech", "voice", "guard", "live", "veo", "sora", "babbage", "davinci"])
    }
}
