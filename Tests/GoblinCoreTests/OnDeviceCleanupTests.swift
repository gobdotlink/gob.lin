import Foundation
import Testing
@testable import GoblinCore

struct OnDeviceCleanupTests {
    private func appleSettings() -> RewriteSettings {
        var settings = RewriteSettings()
        settings.selectProvider(.appleIntelligence)
        settings.enabled = true
        return settings
    }

    @Test func providerIsKeylessAndOnThisMac() {
        let provider = RewriteProvider.appleIntelligence
        #expect(provider.runsOnDevice)
        #expect(provider.group == .local)
        #expect(provider.hasFixedAddress)
        #expect(provider.configuration.model == "on-device")
        #expect(!RewriteProvider.groq.runsOnDevice)
    }

    @Test func selectingAppleKeepsOtherProvidersSettings() {
        var settings = RewriteSettings()
        settings.selectProvider(.groq)
        let groqModel = settings.model
        settings.selectProvider(.appleIntelligence)
        #expect(settings.model == "on-device")
        settings.selectProvider(.groq)
        #expect(settings.model == groqModel)
    }

    @Test func appleSettingsSurviveCoding() throws {
        let settings = appleSettings()
        let decoded = try JSONDecoder().decode(RewriteSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.provider == .appleIntelligence)
    }

    @Test func contextEstimateRejectsHugeTranscriptsOnly() {
        #expect(!OnDeviceCleanup.exceedsContext(instructions: "Clean this.", transcript: "um hello there"))
        #expect(OnDeviceCleanup.exceedsContext(instructions: RewritePrompt.predefined,
                                                transcript: String(repeating: "a fairly long sentence ", count: 2_000)))
    }

    @Test func tooLongDictationFallsBackToRaw() async {
        let raw = String(repeating: "this dictation keeps going and going. ", count: 1_000)
        let result = await RewriteClient().rewrite(raw, settings: appleSettings(), apiKey: "")
        #expect(result.failure != nil)
        #expect(result.polishedText == nil)
        #expect(result.outputText == raw)
    }

    @Test func unavailableOnDeviceModelFallsBackToRaw() async {
        guard OnDeviceCleanup.availability != .available else { return }
        let result = await RewriteClient().rewrite("um hello there", settings: appleSettings(), apiKey: "")
        #expect(result.failure != nil)
        #expect(result.outputText == "um hello there")
        #expect(OnDeviceCleanup.availability.problem != nil)
    }
}
