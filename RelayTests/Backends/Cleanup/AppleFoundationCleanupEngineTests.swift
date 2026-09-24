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

    /// The session's transcript holds the CALLER'S instructions and examples (a saved override, or
    /// `CleanupPrompt`'s defaults) as prior turns, never a static constant of the engine's own
    /// (spec §10 addendum). This is the seed both `respond(_:)` and `prewarm(instructions:examples:)`
    /// build the session from.
    func testSessionSeedsTheTranscriptWithTheGivenInstructionsAndExamples() throws {
        let session = AppleFoundationCleanupEngine.session(
            instructions: "CUSTOM-INSTRUCTIONS",
            examples: [CleanupExample(input: "custom in", output: "custom out")]
        )
        let entries = Array(session.transcript)
        XCTAssertEqual(entries.count, 3)

        guard case let .instructions(instructions) = entries[0] else { return XCTFail("expected instructions") }
        XCTAssertEqual(Self.text(instructions.segments), "CUSTOM-INSTRUCTIONS")

        guard case let .prompt(prompt) = entries[1] else { return XCTFail("expected a prompt turn") }
        XCTAssertEqual(Self.text(prompt.segments), "custom in")

        guard case let .response(response) = entries[2] else { return XCTFail("expected a response turn") }
        XCTAssertEqual(Self.text(response.segments), "custom out")
    }

    func testSessionWithNoExamplesSeedsOnlyInstructions() {
        let session = AppleFoundationCleanupEngine.session(instructions: "I", examples: [])
        XCTAssertEqual(Array(session.transcript).count, 1)
    }

    private static func text(_ segments: [FoundationModels.Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case let .text(text) = segment else { return nil }
            return text.content
        }.joined()
    }
}
