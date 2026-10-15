import Foundation
import Synchronization
import Testing
@testable import GoblinCore

private final class CatalogStub: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let url = request.url!
        let body = url.query?.contains("after_id=claude-sonnet-5") == true
            ? #"{"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","lifecycle":"active"}],"has_more":false,"first_id":"claude-haiku-5-5","last_id":"claude-haiku-5-5"}"#
            : #"{"data":[{"type":"model","id":"claude-sonnet-5","display_name":"Claude Sonnet 5","lifecycle":"deprecated"}],"has_more":true,"first_id":"claude-sonnet-5","last_id":"claude-sonnet-5"}"#
        let status = url.host == "denied.invalid" ? 401 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct RewriteModelCatalogTests {
    private func ids(_ json: String) throws -> [String] { try RewriteModelCatalog.parse([Data(json.utf8)]).map(\.id) }

    @Test func listsOnlyChatModelsFromRealProviderShapes() throws {
        // OpenAI/Groq style: ids only, so non-chat models are recognised by id.
        #expect(try ids(#"""
        {"object":"list","data":[
         {"id":"gpt-6-luna","object":"model","created":1,"owned_by":"system"},{"id":"whisper-1","object":"model"},
         {"id":"tts-1-hd","object":"model"},{"id":"text-embedding-3-small","object":"model"},{"id":"omni-moderation-latest","object":"model"},
         {"id":"dall-e-3","object":"model"},{"id":"gpt-image-1","object":"model"},{"id":"gpt-4o-realtime-preview","object":"model"},
         {"id":"gpt-4o-mini-transcribe","object":"model"},{"id":"o4-mini","object":"model"},{"id":"gpt-6-luna","object":"model"},
         {"id":"Llama-Guard-4-12B","object":"model"},{"id":"llama-3.1-8b-instant","active":false},{"id":"GPT-OSS-20B","active":true}]}
        """#) == ["gpt-6-luna", "GPT-OSS-20B", "o4-mini"])

        // OpenRouter: output modalities decide, and the readable name is kept.
        let router = try RewriteModelCatalog.parse([Data(#"""
        {"data":[{"id":"openai/gpt-6-luna","name":"OpenAI: GPT-6 Luna","architecture":{"modality":"text+image->text","output_modalities":["text"]}},
         {"id":"google/gemini-2.5-flash-image","name":"Google: Nano Banana","architecture":{"output_modalities":["image","text"]}},
         {"id":"openai/gpt-image-1","name":"OpenAI: GPT Image 1","architecture":{"output_modalities":["image"]}},
         {"id":"voyageai/rerank-2.5","name":"Voyage: Rerank 2.5","architecture":{"output_modalities":["rerank"]}}],"total_count":4,"links":{"next":null}}
        """#.utf8)])
        #expect(router == [RewriteModelOption(id: "google/gemini-2.5-flash-image", name: "Google: Nano Banana"),
                           RewriteModelOption(id: "openai/gpt-6-luna", name: "OpenAI: GPT-6 Luna")])

        // Anthropic display names; retired models go.
        #expect(try RewriteModelCatalog.parse([Data(#"""
        {"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","lifecycle":"active"},
         {"type":"model","id":"claude-2.1","display_name":"Claude 2.1","lifecycle":"retired"}],"has_more":false}
        """#.utf8)]) == [RewriteModelOption(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")])

        // Gemini may prefix ids; Vercel types and Requesty api decide.
        #expect(try ids(#"""
        {"object":"list","data":[{"id":"models/gemini-3.8-flash","object":"model","owned_by":"google"},
         {"id":"models/gemini-embedding-001","object":"model"},{"id":"models/imagen-4.0-generate-001","object":"model"},
         {"id":"alibaba/qwen-3-14b","name":"Qwen3-14B","type":"language"},{"id":"cohere/rerank-v3.5","name":"Cohere Rerank 3.5","type":"reranking"},
         {"id":"fireworks/muse-spark-open","api":"chat"}]}
        """#) == ["alibaba/qwen-3-14b", "fireworks/muse-spark-open", "gemini-3.8-flash"])

        // A bare array of strings (local servers) or Mistral cards.
        #expect(try ids(#"""
        ["llama3.2:latest","nomic-embed-text:latest",{"id":"mistral-small-latest","type":"base","capabilities":{"completion_chat":true}},
         {"id":"mistral-ocr-latest","capabilities":{"completion_chat":false}}]
        """#) == ["llama3.2:latest", "mistral-small-latest"])

        #expect(throws: RewriteFailure.invalidResponse) { try ids(#"{"error":{"message":"nope"}}"#) }
    }

    @Test func modelsEndpointFollowsTheCompletionAddress() throws {
        #expect(try RewriteSettings(baseURL: "https://api.groq.com/openai/v1/").modelsEndpoint().absoluteString == "https://api.groq.com/openai/v1/models")
        #expect(try RewriteSettings(baseURL: "http://localhost:1234/v1/chat/completions").modelsEndpoint().absoluteString == "http://localhost:1234/v1/models")
        let anthropic = RewriteSettings(baseURL: RewriteProvider.anthropic.baseURL)
        #expect(anthropic.provider == .anthropic)
        #expect(try anthropic.endpoint().absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(try anthropic.modelsEndpoint().absoluteString == "https://api.anthropic.com/v1/models")
        #expect(throws: RewriteFailure.self) { try RewriteSettings(baseURL: "http://example.com/v1").modelsEndpoint() }
    }

    @Test func keysFollowTheProvider() throws {
        let suite = "rewrite-key-store-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var groq = RewriteSettings(provider: .groq); groq.configuration = RewriteProvider.groq.configuration
        let custom = RewriteSettings(baseURL: "https://proxy.example.com/v1", provider: .custom)
        // Custom at a named provider's address never shares that provider's key.
        let customAtGroq = RewriteSettings(baseURL: RewriteProvider.groq.baseURL, provider: .custom)

        try RewriteKeyStore.save("groq-new", for: groq, defaults: defaults)
        groq.baseURL = "https://groq-proxy.example.com/v1"
        #expect(try RewriteKeyStore.load(for: groq, defaults: defaults) == "groq-new")
        #expect(try RewriteKeyStore.load(for: customAtGroq, defaults: defaults) == "")
        try RewriteKeyStore.save("proxy-new", for: custom, defaults: defaults)
        #expect(defaults.dictionary(forKey: RewriteKeyStore.preferenceKey) as? [String: String]
                == ["groq": "groq-new", "custom https://proxy.example.com/v1/chat/completions": "proxy-new"])
        try RewriteKeyStore.save("", for: custom, defaults: defaults)
        #expect(try RewriteKeyStore.load(for: custom, defaults: defaults) == "")
        #expect(try RewriteKeyStore.load(for: groq, defaults: defaults) == "groq-new")
    }

    @Test func anthropicListIsPagedWithItsOwnHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStub.self]
        let catalog = RewriteModelCatalog(session: URLSession(configuration: configuration))
        let settings = RewriteSettings(baseURL: RewriteProvider.anthropic.baseURL, provider: .anthropic)
        let models = try await catalog.models(for: settings, apiKey: "fixture-key")
        #expect(models.map(\.id) == ["claude-haiku-5-5", "claude-sonnet-5"])
        let requests = CatalogStub.requests.withLock { $0 }
        #expect(requests.map { $0.url!.absoluteString } == ["https://api.anthropic.com/v1/models?limit=1000",
                                                            "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-sonnet-5"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "fixture-key" && $0.value(forHTTPHeaderField: "Authorization") == nil
            && $0.value(forHTTPHeaderField: "anthropic-version") != nil && $0.value(forHTTPHeaderField: "Accept") == "application/json" })

        await #expect(throws: RewriteFailure.httpStatus(401)) {
            try await catalog.models(for: RewriteSettings(baseURL: "https://denied.invalid/v1"), apiKey: "")
        }
    }
}
