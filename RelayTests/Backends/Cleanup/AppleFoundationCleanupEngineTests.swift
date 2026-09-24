import FoundationModels
import XCTest

@testable import Relay

final class AppleFoundationCleanupEngineTests: XCTestCase {
    func testAvailabilityMapping() {
        XCTAssertEqual(AppleFoundationCleanupEngine.map(.available), .available)
        XCTAssertEqual(AppleFoundationCleanupEngine.map(.unavailable(.deviceNotEligible)), .unavailable(.deviceNotEligible))
        XCTAssertEqual(
            AppleFoundationCleanupEngine.map(.unavailable(.appleIntelligenceNotEnabled)), .unavailable(.appleIntelligenceNotEnabled)
        )
        XCTAssertEqual(AppleFoundationCleanupEngine.map(.unavailable(.modelNotReady)), .unavailable(.modelNotReady))
    }

    func testGenerationErrorMapping() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "SECRET")
        let cases: [(LanguageModelSession.GenerationError, GenerationFailureKind)] = [
            (.exceededContextWindowSize(context), .exceededContextWindow),
            (.assetsUnavailable(context), .assetsUnavailable),
            (.guardrailViolation(context), .guardrailViolation),
            (.unsupportedGuide(context), .unsupportedGuide),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguageOrLocale),
            (.decodingFailure(context), .decodingFailure),
            (.rateLimited(context), .rateLimited),
            (.concurrentRequests(context), .concurrentRequests),
            (.refusal(LanguageModelSession.GenerationError.Refusal(transcriptEntries: []), context), .refusal),
        ]
        for (error, kind) in cases {
            XCTAssertEqual(AppleFoundationCleanupEngine.kind(for: error), kind)
        }
    }

    func testNonGenerationErrorsMapToOther() {
        XCTAssertEqual(AppleFoundationCleanupEngine.engineError(for: CleanupTestError()), .generation(.other))
    }
}
