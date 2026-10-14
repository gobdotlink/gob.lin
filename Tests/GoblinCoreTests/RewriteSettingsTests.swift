import Foundation
import Testing
@testable import GoblinCore

struct RewriteSettingsTests {
    @Test func oldSettingsKeepTheirEndpointModelAndAutomaticFallback() throws {
        let data = Data(#"{"enabled":true,"baseURL":"https://api.groq.com/openai/v1/","model":"my-model","cleanup":"medium"}"#.utf8)
        let settings = try JSONDecoder().decode(RewriteSettings.self, from: data)
        #expect(settings.enabled && settings.model == "my-model" && settings.cleanup == .medium)
        #expect(settings.baseURL == "https://api.groq.com/openai/v1/" && settings.provider == .groq)
        #expect(settings.reasoning == .automatic && settings.temperature == 0 && settings.extraRequestJSON.isEmpty)
    }

    @Test func providerSwitchesRememberTuningAndPersistOmittedTemperature() throws {
        var settings = RewriteSettings(enabled: true, cleanup: .medium)
        settings.selectProvider(.groq)
        settings.baseURL = "https://proxy.invalid/v1"
        settings.model = "tuned-model"
        settings.reasoning = .providerDefault
        settings.temperature = nil
        settings.extraRequestJSON = #"{"top_p":0.8,"enable_thinking":false}"#
        let tuned = settings.configuration
        settings.selectProvider(.cerebras)
        #expect(settings.model == "qwen-3.8-27b" && settings.reasoning == .off)
        #expect(settings.enabled && settings.cleanup == .medium)
        settings = try JSONDecoder().decode(RewriteSettings.self, from: JSONEncoder().encode(settings))
        settings.selectProvider(.groq)
        #expect(settings.configuration == tuned)
        settings = try JSONDecoder().decode(RewriteSettings.self, from: JSONEncoder().encode(settings))
        #expect(settings.temperature == nil)
        settings.selectProvider(.custom)
        #expect(settings.configuration == tuned)
    }

    @Test func newInstallStartsDisabledWithFastProviderAndCredentialsStayOutOfPreferences() throws {
        let suite = "rewrite-settings-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RewriteSettingsStore.load(defaults: defaults)
        #expect(!settings.enabled && settings.provider == .cerebras && settings.reasoning == .off)
        try RewriteSettingsStore.save(settings, defaults: defaults)
        #expect(RewriteSettingsStore.load(defaults: defaults) == settings)
        let json = try JSONSerialization.jsonObject(with: defaults.data(forKey: RewriteSettingsStore.preferenceKey)!) as! [String: Any]
        #expect(json["apiKey"] == nil)
    }

    @Test func advancedOptionsValidateBeforeSave() throws {
        var settings = RewriteSettings(reasoning: .off)
        for invalid in ["not JSON", "[]", #"{"messages":[]}"#, #"{"model":"other"}"#, #"{"stream":true}"#, #"{"reasoning_effort":"high"}"#] {
            settings.extraRequestJSON = invalid
            #expect(throws: RewriteFailure.self) { try settings.extraRequestParameters() }
        }
        settings.reasoning = .providerDefault
        settings.extraRequestJSON = #"{"enable_thinking":false,"temperature":null,"max_tokens":1024}"#
        #expect(try settings.extraRequestParameters()["enable_thinking"] as? Bool == false)
        settings.temperature = .nan
        #expect(throws: RewriteFailure.self) { try settings.extraRequestParameters() }
    }

    @Test func codingAgentPresetPersistsWithoutChangingProviderTuning() throws {
        var settings = RewriteSettings(enabled: true, cleanup: .codingAgent, reasoning: .off)
        settings.selectProvider(.cerebras)
        let restored = try JSONDecoder().decode(RewriteSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings && restored.cleanup == .codingAgent && restored.reasoning == .off)
    }
}
