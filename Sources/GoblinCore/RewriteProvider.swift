import Foundation

public enum RewriteProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    // Keep the fast inference providers at the top of the selector.
    case cerebras, groq, sambaNova, openAI, anthropic, gemini, mistral, xai, zai, openRouter, requesty, vercel, local, custom
    public var id: String { rawValue }

    public var group: RewriteProviderGroup {
        switch self {
        case .cerebras, .groq, .sambaNova: .fast
        case .openAI, .anthropic, .gemini, .mistral, .xai, .zai: .labs
        case .openRouter, .requesty, .vercel: .routers
        case .local: .local
        case .custom: .custom
        }
    }

    public var title: String {
        switch self {
        case .cerebras: "Cerebras"
        case .groq: "Groq"
        case .sambaNova: "SambaNova"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .mistral: "Mistral"
        case .xai: "xAI"
        case .requesty: "Requesty"
        case .vercel: "Vercel AI Gateway"
        case .openRouter: "OpenRouter"
        case .zai: "Z.AI"
        case .local: "Local"
        case .custom: "Custom"
        }
    }

    public var baseURL: String {
        switch self {
        case .cerebras: "https://api.cerebras.ai/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .sambaNova: "https://api.sambanova.ai/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: "https://api.mistral.ai/v1"
        case .xai: "https://api.x.ai/v1"
        case .requesty: "https://router.requesty.ai/v1"
        case .vercel: "https://ai-gateway.vercel.sh/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .zai: "https://api.z.ai/api/paas/v4"
        case .local: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    public var models: [RewriteModelPreset] {
        switch self {
        case .cerebras: [RewriteModelPreset(id: "qwen-3.8-27b", title: "Qwen 3.8 27B", reasoning: .off)]
        case .groq: [RewriteModelPreset(id: "openai/gpt-oss-20b", title: "GPT-OSS 20B", reasoning: .low,
                                       extraRequestJSON: #"{"include_reasoning":false}"#),
                     RewriteModelPreset(id: "qwen/qwen3.8-27b", title: "Qwen 3.8 27B", reasoning: .off,
                                        extraRequestJSON: #"{"reasoning_format":"hidden"}"#)]
        case .openAI: [RewriteModelPreset(id: "gpt-6-luna", title: "GPT-6 Luna", reasoning: .off)]
        case .openRouter: [RewriteModelPreset(id: "openai/gpt-6-luna", title: "GPT-6 Luna", reasoning: .off),
                           RewriteModelPreset(id: "anthropic/claude-haiku-5.5", title: "Claude Haiku 5.5", reasoning: .off, temperature: nil)]
        case .zai: [RewriteModelPreset(id: "glm-4.7-flash", title: "GLM 4.7 Flash", reasoning: .off)]
        case .sambaNova: [RewriteModelPreset(id: "Meta-Llama-3.3-70B-Instruct", title: "Llama 3.3 70B", reasoning: .off),
                          RewriteModelPreset(id: "gpt-oss-120b", title: "GPT-OSS 120B", reasoning: .low)]
        case .anthropic: [RewriteModelPreset(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", reasoning: .off, temperature: nil)]
        case .gemini: [RewriteModelPreset(id: "gemini-3.5-flash-lite", title: "Gemini 3.5 Flash-Lite", reasoning: .off, temperature: nil)]
        case .mistral: [RewriteModelPreset(id: "mistral-small-2603", title: "Mistral Small 4", reasoning: .off),
                        RewriteModelPreset(id: "ministral-8b-2512", title: "Ministral 8B", reasoning: .providerDefault)]
        case .xai: [RewriteModelPreset(id: "grok-4.20-0309-non-reasoning", title: "Grok 4.20 Non-Reasoning", reasoning: .providerDefault)]
        case .requesty: [RewriteModelPreset(id: "openai/gpt-6-luna", title: "GPT-6 Luna", reasoning: .off, temperature: nil)]
        case .vercel: [RewriteModelPreset(id: "openai/gpt-6-luna", title: "GPT-6 Luna", reasoning: .off),
                       RewriteModelPreset(id: "anthropic/claude-haiku-5.5", title: "Claude Haiku 5.5", reasoning: .off, temperature: nil)]
        case .local, .custom: []
        }
    }

    public var detail: String {
        switch self {
        case .cerebras: "Fast inference. The Qwen preset requests reasoning off for quick cleanup."
        case .groq: "Fast inference. GPT-OSS 20B uses Low reasoning for low cost; Qwen supports reasoning Off."
        case .openAI: "GPT-6 Luna is a small, cost-efficient model. The preset requests reasoning off."
        case .openRouter: "Access GPT-6 Luna and Claude Haiku with one OpenAI-compatible endpoint."
        case .zai: "The Flash preset requests thinking off. Other GLM models may require thinking."
        case .local: "An OpenAI-compatible server on this Mac. A local server may not need an API key."
        case .custom: "Use any OpenAI-compatible chat completions endpoint."
        case .sambaNova: "Fast inference. Llama 3.3 does not reason; GPT-OSS 120B uses Low reasoning."
        case .anthropic: "Claude Haiku 5.5 is the fastest Claude model. The preset turns thinking off."
        case .gemini: "Flash-Lite is fast and low cost. Gemini 3 thinking cannot be turned off, so Off requests the minimum."
        case .mistral: "Mistral Small 4 requests reasoning off; Ministral 8B is a small model without reasoning."
        case .xai: "The non-reasoning Grok model answers without thinking. Other Grok models cannot turn reasoning off."
        case .requesty: "A router with one OpenAI-compatible endpoint. Requesty may map reasoning Off to its lowest level."
        case .vercel: "Access GPT-6 Luna and Claude Haiku with one OpenAI-compatible endpoint."
        }
    }

    /// Request headers that carry the API key. Anthropic's own API uses its key header and a version.
    public func authorizationHeaders(apiKey: String) -> [String: String] {
        guard !apiKey.isEmpty else { return [:] }
        if self == .anthropic { return ["x-api-key": apiKey, "anthropic-version": "2023-06-01"] }
        return ["Authorization": "Bearer " + apiKey]
    }

    public static func matching(baseURL: String) -> Self {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return allCases.first { $0 != .custom && ($0.baseURL == normalized || $0.baseURL + "/chat/completions" == normalized) } ?? .custom
    }

    public var configuration: RewriteProviderConfiguration {
        RewriteProviderConfiguration(baseURL: baseURL, model: models.first?.id ?? "",
                                     reasoning: models.first?.reasoning ?? .providerDefault,
                                     temperature: models.first.map { $0.temperature } ?? 0,
                                     extraRequestJSON: models.first?.extraRequestJSON ?? "")
    }
}

public enum RewriteProviderGroup: String, CaseIterable, Sendable, Identifiable {
    case fast, labs, routers, local, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fast: "Fast inference"
        case .labs: "Model makers"
        case .routers: "Routers"
        case .local: "On this Mac"
        case .custom: "Custom"
        }
    }
}

public struct RewriteModelPreset: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let reasoning: RewriteReasoning
    public var temperature: Double? = 0
    public var extraRequestJSON: String = ""
}

public enum RewriteReasoning: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, low, medium, high, providerDefault, automatic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .providerDefault: "Provider default"
        case .automatic: "Automatic (lowest supported)"
        default: rawValue.capitalized
        }
    }

    public func parameters(provider: RewriteProvider, automaticEffort: String? = nil) -> [String: Any] {
        guard self != .providerDefault else { return [:] }
        let effort = self == .automatic ? automaticEffort : (self == .off ? "none" : rawValue)
        guard let effort else { return [:] }
        switch provider {
        case .openRouter, .vercel:
            return ["reasoning": effort == "none" ? ["enabled": false] : ["effort": effort]]
        case .zai:
            return effort == "none" ? ["thinking": ["type": "disabled"]] : ["thinking": ["type": "enabled"], "reasoning_effort": effort]
        case .anthropic:
            return effort == "none" ? ["thinking": ["type": "disabled"]] : ["output_config": ["effort": effort]]
        // These accept no "none": Gemini 3 and Grok cannot stop thinking, Mistral has only none/high,
        // and SambaNova's hybrid models already default to thinking off.
        case .gemini:
            return ["reasoning_effort": effort == "none" ? "minimal" : effort]
        case .xai:
            return ["reasoning_effort": effort == "none" ? "low" : effort]
        case .mistral:
            return ["reasoning_effort": effort == "none" ? "none" : "high"]
        case .sambaNova:
            return effort == "none" ? [:] : ["reasoning_effort": effort]
        default:
            return ["reasoning_effort": effort]
        }
    }
}

/// Non-secret settings are remembered per provider; RewriteKeyStore keeps one key per provider (Custom per endpoint).
public struct RewriteProviderConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var reasoning: RewriteReasoning
    public var temperature: Double?
    public var extraRequestJSON: String

    public init(baseURL: String, model: String, reasoning: RewriteReasoning, temperature: Double? = 0, extraRequestJSON: String = "") {
        self.baseURL = baseURL; self.model = model; self.reasoning = reasoning
        self.temperature = temperature; self.extraRequestJSON = extraRequestJSON
    }
}
