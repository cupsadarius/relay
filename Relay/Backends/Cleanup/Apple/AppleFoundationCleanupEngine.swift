import Foundation
import FoundationModels
import Synchronization

/// `SystemLanguageModel.default` with a fresh `LanguageModelSession` per request (spec §12.1).
/// Uses only macOS 26 SDK API so it builds on CI (Xcode 26) and locally (Xcode 27). Never logs
/// text, `debugDescription` or `localizedDescription`.
final class AppleFoundationCleanupEngine: AppleCleanupEngine {
    static let temperature = 0.2

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
        let session = LanguageModelSession(model: .default, instructions: instructions)
        session.prewarm(promptPrefix: nil)
        prewarmed.withLock { $0 = session }
    }

    func respond(_ request: CleanupRequest) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: request.instructions)
        let options = GenerationOptions(temperature: Self.temperature, maximumResponseTokens: request.maxOutputTokens)
        do {
            return try await session.respond(to: request.input, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.engineError(for: error)
        }
    }

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
        @unknown default:
            // Controller decision (Task 23): `SystemLanguageModel.Availability` is `@frozen` in
            // this SDK, so this arm is unreachable today (compiler warning, not an error) — kept
            // so a future SDK that adds a top-level case still maps to something sane.
            return .unavailable(.unknown)
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
