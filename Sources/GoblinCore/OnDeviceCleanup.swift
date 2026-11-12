import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why Apple's on-device model cannot clean up text here, or that it can.
public enum OnDeviceCleanupAvailability: Equatable, Sendable {
    case available, notInThisBuild, deviceNotEligible, notEnabled, modelNotReady, unavailable

    /// The setup problem to show, or nil when cleanup can run.
    public var problem: String? {
        switch self {
        case .available: nil
        case .notInThisBuild: "Apple Intelligence cleanup isn't included in this build."
        #if os(iOS)
        case .deviceNotEligible: "This iPhone doesn't support Apple Intelligence."
        case .notEnabled: "Turn on Apple Intelligence in Settings to use on-device cleanup."
        case .modelNotReady: "Apple Intelligence is still getting ready on this iPhone. Try again later."
        #else
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
        case .notEnabled: "Turn on Apple Intelligence in System Settings to use on-device cleanup."
        case .modelNotReady: "Apple Intelligence is still getting ready on this Mac. Try again later."
        #endif
        case .unavailable: "Apple Intelligence is unavailable right now."
        }
    }
}

/// Cleanup through the system on-device language model. Nothing leaves the Mac,
/// but the model is small: a 4,096-token window must hold the instructions, the
/// transcript and the cleaned output, so long dictations fall back to raw text.
public enum OnDeviceCleanup {
    static let tooLongMessage = "This dictation is too long for on-device cleanup. Choose another provider for long takes."

    /// Read lazily, when the provider is selected or used; never at launch.
    public static var availability: OnDeviceCleanupAvailability {
        #if canImport(FoundationModels)
        switch Self.model.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
        #else
        .notInThisBuild
        #endif
    }

    /// Loads the model ahead of first use. Call when cleanup settings change, not while dictating.
    public static func prewarm() {
        #if canImport(FoundationModels)
        guard availability == .available else { return }
        LanguageModelSession(model: model).prewarm()
        #endif
    }

    /// Estimates with characters per token; the framework offers no token counter.
    /// The output is a cleaned copy, so the transcript counts twice.
    static func exceedsContext(instructions: String, transcript: String) -> Bool {
        func tokens(_ text: String) -> Int { (text.count * 2 + 6) / 7 }
        return tokens(instructions) + 2 * tokens(transcript) > 4_000
    }

    static func rewrite(_ rawText: String, cleanup: RewriteCleanup, tone: DictationTone,
                        preferredSpellings: [String]) async -> RewriteResult {
        guard let messages = try? RewritePrompt.messages(transcript: rawText, cleanup: cleanup, tone: tone, preferredSpellings: preferredSpellings),
              let instructions = messages.first(where: { $0["role"] == "system" })?["content"],
              let payload = messages.first(where: { $0["role"] == "user" })?["content"] else {
            return RewriteResult(rawText: rawText, failure: .invalidResponse)
        }
        guard !exceedsContext(instructions: instructions, transcript: payload) else {
            return RewriteResult(rawText: rawText, failure: .configuration(tooLongMessage))
        }
        #if canImport(FoundationModels)
        guard availability == .available else {
            return RewriteResult(rawText: rawText, failure: .configuration(availability.problem ?? "Apple Intelligence is unavailable."))
        }
        do {
            let text = try await generate(instructions: instructions, payload: payload)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard RewritePrompt.permitsEmptyOutput(for: rawText, preferredSpellings: preferredSpellings) else {
                    return RewriteResult(rawText: rawText, failure: .invalidResponse)
                }
                return RewriteResult(rawText: rawText, polishedText: "")
            }
            return RewriteResult(rawText: rawText, polishedText: text)
        } catch let failure as RewriteFailure {
            return RewriteResult(rawText: rawText, failure: failure)
        } catch is CancellationError {
            return RewriteResult(rawText: rawText, failure: .transport)
        } catch let error as LanguageModelSession.GenerationError {
            return RewriteResult(rawText: rawText, failure: failure(for: error))
        } catch {
            return RewriteResult(rawText: rawText, failure: .invalidResponse)
        }
        #else
        return RewriteResult(rawText: rawText, failure: .configuration(OnDeviceCleanupAvailability.notInThisBuild.problem!))
        #endif
    }

    #if canImport(FoundationModels)
    /// The cleanup model instance. Permissive transformations let dictated
    /// swearing and sensitive wording through to be cleaned, not censored.
    private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    @Generable
    struct CleanedTranscript {
        @Guide(description: "The cleaned transcript, exactly as it should be typed, with nothing added or removed beyond the instructions")
        var text: String
    }

    /// Structured output first; a structured-only failure gets one plain attempt.
    /// Both share cleanup's four-second deadline, after which raw text wins.
    private static func generate(instructions: String, payload: String) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(RewriteClient.hardTimeout))
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(model: model, instructions: instructions)
                session.prewarm()
                do {
                    return try await session.respond(to: payload, generating: CleanedTranscript.self,
                                                     options: GenerationOptions(sampling: .greedy)).content.text
                } catch let error as LanguageModelSession.GenerationError {
                    switch error {
                    // Structured-only failures get a plain attempt. Language detection also
                    // trips intermittently on slangy supported text, and busy errors can clear.
                    case .decodingFailure, .unsupportedGuide, .unsupportedLanguageOrLocale, .rateLimited, .concurrentRequests: break
                    default: throw error
                    }
                }
                let plain = LanguageModelSession(model: model, instructions: instructions)
                return try await plain.respond(to: payload, options: GenerationOptions(sampling: .greedy)).content
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw RewriteFailure.timeout
            }
            defer { group.cancelAll() }
            guard let text = try await group.next() else { throw RewriteFailure.invalidResponse }
            return text
        }
    }

    private static func failure(for error: LanguageModelSession.GenerationError) -> RewriteFailure {
        switch error {
        case .exceededContextWindowSize: .configuration(tooLongMessage)
        case .unsupportedLanguageOrLocale: .configuration("Apple Intelligence doesn't support this language yet.")
        case .guardrailViolation, .refusal: .configuration("Apple Intelligence declined to process this text.")
        case .assetsUnavailable: .configuration("Apple Intelligence is unavailable right now.")
        case .rateLimited, .concurrentRequests: .configuration("Apple Intelligence is busy. Your next take may work.")
        default: .invalidResponse
        }
    }
    #endif
}
