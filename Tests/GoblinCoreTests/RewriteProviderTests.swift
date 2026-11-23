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
        // A minute's deadline: beside every other test on a small machine, the wait for a turn can pass the app's four seconds.
        let result = await RewriteClient(session: URLSession(configuration: config), hardTimeout: 60).rewrite(raw, settings: settings, apiKey: "fixture-key")
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

    @Test func openAIUsesResponsesAPIAndNeverDropsAChosenSpeed() async throws {
        var settings = RewriteSettings(enabled: true, cleanup: .light)
        settings.selectProvider(.openAI)
        settings.model = "gpt-6-astra"
        settings.serviceTier = .ultrafast
        let reply = #"{"status":"completed","service_tier":"ultrafast","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Cleaned "},{"type":"output_text","text":"text."}]}]}"#
        let (result, bodies) = try await rewrite("cleaned text", settings, replies: [(200, reply)])
        #expect(result.outputText == "Cleaned text." && result.failure == nil)
        #expect(MessagesStub.requests[0].url?.absoluteString == "https://api.openai.com/v1/responses")
        let body = bodies[0]
        #expect(body["service_tier"] as? String == "ultrafast" && body["store"] as? Bool == false && body["messages"] == nil)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "none" && body["reasoning_effort"] == nil)
        #expect((body["instructions"] as? String)?.hasPrefix("Clean a speech-to-text transcript") == true)
        let input = body["input"] as! [[String: String]]
        #expect(input.count == 1 && input[0]["role"] == "user" && input[0]["content"]?.contains("cleaned text") == true)

        // Cut off, or empty for words that weren't only hesitations: the dictation is typed as spoken.
        for cut in [#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"Send"}]}]}"#,
                    #"{"status":"completed","output":[]}"#] {
            let (failed, _) = try await rewrite("send it", settings, replies: [(200, cut)])
            #expect(failed.failure == .invalidResponse && failed.outputText == "send it")
        }
        // Hesitations alone may clean up to nothing, but a refusal never counts as that.
        let (empty, _) = try await rewrite("um uh", settings, replies: [(200, #"{"status":"completed","output":[]}"#)])
        #expect(empty.failure == nil && empty.outputText.isEmpty)
        let (refusal, _) = try await rewrite("um uh", settings, replies: [(200, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No."}]}]}"#)])
        #expect(refusal.failure == .invalidResponse && refusal.outputText == "um uh")

        // A turned-down speed fails once, by name, with no quiet retry at Standard.
        let refused = #"{"error":{"message":"Invalid 'service_tier' argument: The requested service tier is not allowed for this project.","type":"invalid_request_error","param":"service_tier","code":null}}"#
        let (rejected, attempts) = try await rewrite("send it", settings, replies: [(400, refused), (200, reply)])
        #expect(attempts.count == 1 && rejected.outputText == "send it")
        #expect(rejected.failure == .configuration("OpenAI won't run gpt-6-astra at Ultrafast speed for this key. Choose another speed."))

        // Astra can't turn reasoning off, and refuses temperature once it reasons: Automatic's retry at low drops it.
        settings.reasoning = .automatic
        let noNone = #"{"error":{"code":"unsupported_value","message":"Unsupported value: 'none' is not supported with the 'gpt-6-astra' model.","param":"reasoning.effort","type":"invalid_request_error"}}"#
        let (retried, retryBodies) = try await rewrite("cleaned text", settings, replies: [(400, noNone), (200, reply)])
        #expect(retried.failure == nil && retryBodies.count == 2 && retryBodies[1]["service_tier"] as? String == "ultrafast")
        #expect((retryBodies[1]["reasoning"] as? [String: String])?["effort"] == "low" && retryBodies[1]["temperature"] == nil)

        // Standard sends no tier, and options saved for Chat Completions still mean the same thing.
        settings.serviceTier = nil
        settings.reasoning = .providerDefault
        settings.extraRequestJSON = #"{"max_completion_tokens":512,"reasoning_effort":"low"}"#
        let standard = try settings.requestParameters(automaticEffort: nil)
        #expect(standard["service_tier"] == nil && standard["max_output_tokens"] as? Int == 512 && standard["max_completion_tokens"] == nil)
        #expect((standard["reasoning"] as? [String: String])?["effort"] == "low" && standard["reasoning_effort"] == nil)

        // The Speed picker is the only source of OpenAI's speed; typing one in Advanced options is refused.
        settings.extraRequestJSON = #"{"service_tier":"fast"}"#
        #expect(throws: RewriteFailure.self) { try settings.requestParameters(automaticEffort: nil) }

        // Only OpenAI's own API gets a tier or reserves its prompt fields: Custom starts from OpenAI's tuning
        // but speaks Chat Completions, where input and instructions are ordinary options.
        settings.extraRequestJSON = #"{"instructions":null,"input":null}"#
        settings.serviceTier = .fast
        settings.selectProvider(.custom)
        let custom = try settings.requestParameters(automaticEffort: nil)
        let customEndpoint = try settings.endpoint()
        #expect(custom["service_tier"] == nil && custom["store"] == nil && customEndpoint.path == "/v1/chat/completions")
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
