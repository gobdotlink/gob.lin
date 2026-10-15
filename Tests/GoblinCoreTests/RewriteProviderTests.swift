import Foundation
import Testing
@testable import GoblinCore

private final class MessagesStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
            stream.close()
            captured.httpBody = body
        }
        Self.requests.append(captured)
        let (status, body) = Self.replies.isEmpty ? (500, "{}") : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct RewriteProviderTests {
    private func rewrite(_ raw: String, _ settings: RewriteSettings, replies: [(Int, String)]) async throws -> (RewriteResult, [[String: Any]]) {
        MessagesStub.replies = replies
        MessagesStub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MessagesStub.self]
        let result = await RewriteClient(session: URLSession(configuration: config)).rewrite(raw, settings: settings, apiKey: "fixture-key")
        return (result, try MessagesStub.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] })
    }

    @Test func anthropicUsesMessagesAPIBodyAndDecode() async throws {
        var settings = RewriteSettings(enabled: true, cleanup: .light)
        settings.selectProvider(.anthropic)
        let reply = #"{"content":[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"Cleaned "},{"type":"text","text":"text."}],"stop_reason":"end_turn"}"#
        let (result, bodies) = try await rewrite("cleaned text", settings, replies: [(200, reply)])
        #expect(result.outputText == "Cleaned text." && result.failure == nil)
        let request = MessagesStub.requests[0]
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key" && request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = bodies[0]
        #expect(body["model"] as? String == "claude-haiku-5-5" && body["max_tokens"] as? Int == 4096)
        #expect(body["temperature"] == nil && body["output_config"] == nil)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["system"] as? String)?.hasPrefix("Clean a speech-to-text transcript") == true)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.count == 1 && messages[0]["role"] == "user" && messages[0]["content"]?.contains("cleaned text") == true)

        for stop in ["max_tokens", "refusal"] {
            let (cut, _) = try await rewrite("send it", settings, replies: [(200, #"{"content":[{"type":"text","text":"Send"}],"stop_reason":"\#(stop)"}"#)])
            #expect(cut.failure == .invalidResponse && cut.outputText == "send it")
        }
        let (empty, _) = try await rewrite("uh", settings, replies: [(200, #"{"content":[],"stop_reason":"end_turn"}"#)])
        #expect(empty.failure == nil && empty.outputText.isEmpty)

        // Automatic falls back from thinking off to low effort when a model always thinks.
        settings.reasoning = .automatic
        settings.extraRequestJSON = #"{"max_tokens":1024}"#
        let reject = #"{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.disabled\" is not supported for this model."}}"#
        let (retried, retryBodies) = try await rewrite("send it", settings, replies: [(400, reject), (200, reply)])
        #expect(retried.failure == nil && retryBodies.count == 2 && retryBodies[1]["max_tokens"] as? Int == 1024)
        #expect(retryBodies[1]["thinking"] == nil && (retryBodies[1]["output_config"] as? [String: String])?["effort"] == "low")
    }

    @Test func newProvidersSendTheirOwnReasoningFields() {
        func fields(_ provider: RewriteProvider, _ reasoning: RewriteReasoning) -> NSDictionary { NSDictionary(dictionary: reasoning.parameters(provider: provider)) }
        let expected: [(RewriteProvider, RewriteReasoning, [String: Any])] = [
            (.anthropic, .off, ["thinking": ["type": "disabled"]]), (.anthropic, .medium, ["output_config": ["effort": "medium"]]),
            (.vercel, .off, ["reasoning": ["enabled": false]]), (.vercel, .low, ["reasoning": ["effort": "low"]]),
            (.gemini, .off, ["reasoning_effort": "minimal"]), (.gemini, .high, ["reasoning_effort": "high"]),
            (.xai, .off, ["reasoning_effort": "low"]), (.mistral, .off, ["reasoning_effort": "none"]), (.mistral, .low, ["reasoning_effort": "high"]),
            (.sambaNova, .off, [:]), (.sambaNova, .low, ["reasoning_effort": "low"]), (.requesty, .off, ["reasoning_effort": "none"]),
        ]
        for (provider, reasoning, value) in expected { #expect(fields(provider, reasoning) == NSDictionary(dictionary: value), "\(provider) \(reasoning)") }
    }

    @Test func requestyLunaNeverKeepsSamplingBecauseOffRunsAsLow() throws {
        var settings = RewriteSettings(enabled: true, provider: .requesty)
        settings.configuration = RewriteProvider.requesty.configuration
        settings.temperature = 0
        let body = try settings.requestParameters(automaticEffort: nil)
        #expect(body["reasoning_effort"] as? String == "none" && body["temperature"] == nil)
    }
}
