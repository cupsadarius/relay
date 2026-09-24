import Foundation
import FoundationModels
import Synchronization

/// `SystemLanguageModel.default` with a fresh `LanguageModelSession` per request (spec §12.1).
/// Uses only macOS 26 SDK API so it builds on CI (Xcode 26) and locally (Xcode 27). Never logs
/// text, `debugDescription` or `localizedDescription`.
final class AppleFoundationCleanupEngine: AppleCleanupEngine {

    /// Keeps the most recent prewarmed session alive so the prewarm is not dropped at once.
    private let prewarmed = Mutex<LanguageModelSession?>(nil)

    func availability() -> AppleCleanupAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    func supportsLocale(_ locale: Locale) -> Bool {
        SystemLanguageModel.default.supportsLocale(locale)
    }

    func prewarm(instructions: String) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = Self.session(instructions: instructions)
        session.prewarm(promptPrefix: nil)
        prewarmed.withLock { $0 = session }
    }

    func releasePrewarm() {
        prewarmed.withLock { $0 = nil }
    }

    func respond(_ request: CleanupRequest) async throws -> String {
        let session = Self.session(instructions: request.instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: request.maxOutputTokens)
        do {
            return try await session.respond(to: request.input, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.engineError(for: error)
        }
    }

    /// A fresh session whose transcript holds the instructions and `CleanupPrompt.examples` as
    /// prior prompt/response turns — the same turns the MLX backend renders (spec §10).
    static func session(instructions: String) -> LanguageModelSession {
        typealias Turns = FoundationModels.Transcript
        func text(_ content: String) -> [Turns.Segment] { [.text(Turns.TextSegment(content: content))] }
        var entries: [Turns.Entry] = [.instructions(Turns.Instructions(segments: text(instructions), toolDefinitions: []))]
        for example in CleanupPrompt.examples {
            entries.append(.prompt(Turns.Prompt(segments: text(example.input))))
            entries.append(.response(Turns.Response(assetIDs: [], segments: text(example.output))))
        }
        return LanguageModelSession(model: .default, transcript: Turns(entries: entries))
    }

    /// `SystemLanguageModel.Availability` is `@frozen`, so the outer switch is exhaustive with no
    /// `@unknown default`. `UnavailableReason` is not frozen and keeps one.
    static func map(_ availability: SystemLanguageModel.Availability) -> AppleCleanupAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        }
    }

    static func kind(for error: LanguageModelSession.GenerationError) -> GenerationFailureKind {
        switch error {
        case .exceededContextWindowSize: .exceededContextWindow
        case .assetsUnavailable: .assetsUnavailable
        case .guardrailViolation: .guardrailViolation
        case .unsupportedGuide: .unsupportedGuide
        case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale
        case .decodingFailure: .decodingFailure
        case .rateLimited: .rateLimited
        case .concurrentRequests: .concurrentRequests
        case .refusal: .refusal
        @unknown default: .other
        }
    }

    /// Any error that is not a `GenerationError` (including macOS 27 errors this SDK cannot name)
    /// maps to `.other`.
    static func engineError(for error: any Error) -> CleanupEngineError {
        if let generationError = error as? LanguageModelSession.GenerationError {
            return .generation(kind(for: generationError))
        }
        return .generation(.other)
    }
}
