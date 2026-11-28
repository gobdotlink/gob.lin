import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A decision model's pick of profile for an app or a browser window, and how sure it was.
public struct ProfileGuess: Equatable, Sendable {
    public enum Certainty: Sendable { case sure, unsure, lost }

    public let profile: String
    /// 0 to 1, as the model reports it.
    public let confidence: Double

    public init(profile: String, confidence: Double) { self.profile = profile; self.confidence = confidence }

    // ponytail: fixed thresholds on the models' own confidence; tune them here if guesses ask too often or too rarely.
    public var certainty: Certainty { confidence >= 0.85 ? .sure : confidence >= 0.5 ? .unsure : .lost }
}

/// Asks a decision model which profile text dictated into an app belongs in. Sends only the app's name, its bundle
/// identifier and, for a browser tab, the window title: never what was said or what's on screen.
public actor ProfileDecisionClient {
    public static let timeout: TimeInterval = 3
    /// The on-device model gives no probability: its picks are always worth a question.
    static let onDeviceConfidence = 0.7
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRewriteRedirects(), delegateQueue: nil)
        }
    }

    /// Nil when the model can't be asked, fails, or refuses. `model` is the one OpenRouter routes to.
    public func guess(application: String, bundleIdentifier: String, windowTitle: String? = nil, profiles: [CleanupProfile],
                      sorter: ProfileSorter, model: String = ProfileSorter.openRouterModels[0].id, apiKey: String) async -> ProfileGuess? {
        let options = Self.options(profiles)
        guard options.count > 1 else { return nil }
        let state = Self.state(application: application, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
        let answer: (choice: String, confidence: Double)?
        switch sorter {
        case .automatic: return nil
        case .appleIntelligence:
            answer = await Self.onDevice(state: state, options: options).map { ($0, Self.onDeviceConfidence) }
        case .openAI, .openRouter, .typeSafe:
            guard !apiKey.isEmpty, let request = try? Self.request(sorter: sorter, model: model, state: state, options: options, apiKey: apiKey),
                  let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            answer = Self.answer(data)
        }
        guard let answer, let option = options.first(where: { $0.key == answer.choice }) else { return nil }
        return ProfileGuess(profile: option.id, confidence: answer.confidence)
    }

    static let instructions = "Which writing profile fits text the user dictates into this app? Each option says where it belongs. Choose Everywhere when no other profile clearly fits."

    /// Each profile under a unique name, with its purpose as the description the model reads.
    static func options(_ profiles: [CleanupProfile]) -> [(key: String, id: String, purpose: String)] {
        var used: Set<String> = []
        return profiles.map { profile in
            let base = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Profile" : profile.name
            var key = base, number = 2
            while !used.insert(key).inserted { key = "\(base) \(number)"; number += 1 }
            return (key, profile.id, profile.purpose)
        }
    }

    static func state(application: String, bundleIdentifier: String, windowTitle: String?) -> String {
        var lines = ["App: " + String(application.prefix(DictationContext.titleLimit)), "Bundle identifier: " + bundleIdentifier]
        if let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines.append("Window title: " + String(title.prefix(DictationContext.titleLimit)))
        }
        return lines.joined(separator: "\n")
    }

    /// OpenAI's Decisions API takes a list of questions with choices; TypeSafe's System One, and OpenRouter's Decisions
    /// API for every decision model it routes to, take them by name with criteria.
    static func request(sorter: ProfileSorter, model: String = ProfileSorter.openRouterModels[0].id, state: String,
                        options: [(key: String, id: String, purpose: String)], apiKey: String) throws -> URLRequest {
        let url: URL, body: [String: Any]
        switch sorter {
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/decisions")!
            body = ["model": "gpt-6-luna", "input": state, "questions": [[
                "type": "choice", "name": "profile", "instructions": instructions,
                "choices": options.map { ["value": $0.key, "description": $0.purpose] },
            ]]]
        case .typeSafe, .openRouter:
            // ponytail: OpenRouter documents its decision models, Perplexity's among them, only on its alpha Decisions
            // endpoint; move to a stable path when it has one.
            url = URL(string: sorter == .typeSafe ? "https://api.typesafe.ai/v1/systemone" : "https://openrouter.ai/api/alpha/decisions")!
            body = ["model": sorter == .typeSafe ? "jev-latest" : model, "state": state, "questions": ["profile": [
                "type": "choice", "instructions": instructions,
                "criteria": Dictionary(options.map { ($0.key, $0.purpose) }, uniquingKeysWith: { first, _ in first }),
            ]]]
        case .automatic, .appleIntelligence:
            throw RewriteFailure.configuration("This sorter doesn't use the network.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GoblinMetadata.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The chosen option and its confidence, from either shape: `answers` as a list (OpenAI) or keyed by question
    /// (TypeSafe). Without a confidence, the chosen option's probability stands in.
    static func answer(_ data: Data) -> (choice: String, confidence: Double)? {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let answer: [String: Any]?
        if let list = reply["answers"] as? [[String: Any]] { answer = list.first { $0["name"] as? String == "profile" } ?? list.first }
        else { answer = (reply["answers"] as? [String: Any])?["profile"] as? [String: Any] }
        guard let answer, answer["type"] as? String != "refusal", let choice = answer["choice"] as? String else { return nil }
        var probability: Double?
        if let probabilities = answer["probabilities"] as? [String: Any] { probability = (probabilities[choice] as? NSNumber)?.doubleValue }
        else if let probabilities = answer["probabilities"] as? [[String: Any]] {
            probability = (probabilities.first { $0["value"] as? String == choice }?["probability"] as? NSNumber)?.doubleValue
        }
        guard let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? probability else { return nil }
        return (choice, min(max(confidence, 0), 1))
    }

    private static func onDevice(state: String, options: [(key: String, id: String, purpose: String)]) async -> String? {
        #if canImport(FoundationModels)
        guard OnDeviceCleanup.availability == .available else { return nil }
        let list = options.map { "- \($0.key): \($0.purpose)" }.joined(separator: "\n")
        let keys = options.map(\.key)
        return try? await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Profile", anyOf: keys), dependencies: [])
                let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                                   instructions: instructions + "\nOptions:\n" + list)
                let reply = try await session.respond(to: state, schema: schema, options: GenerationOptions(sampling: .greedy))
                return try reply.content.value(String.self)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        #else
        return nil
        #endif
    }
}
