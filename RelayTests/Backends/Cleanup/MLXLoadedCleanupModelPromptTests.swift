import MLXLMCommon
import XCTest

@testable import Relay

/// `MLXLoadedCleanupModel.chatMessages(for:)` is the pure prompt-construction step the live
/// engine feeds to `UserInput(chat:)` (spec §10 addendum): it must render the REQUEST's
/// instructions and examples, never a static `CleanupPrompt` constant, so a saved override reaches
/// generation the same way it reaches `QwenChatTemplate`.
final class MLXLoadedCleanupModelPromptTests: XCTestCase {
    func testRendersTheRequestsInstructionsExamplesAndInputInOrder() {
        let request = CleanupRequest(
            modelID: .qwen3_1_7b, instructions: "CUSTOM-INSTRUCTIONS", input: "the input", maxOutputTokens: 64,
            examples: [CleanupExample(input: "ex in 1", output: "ex out 1"), CleanupExample(input: "ex in 2", output: "ex out 2")]
        )

        let messages = MLXLoadedCleanupModel.chatMessages(for: request)

        XCTAssertEqual(
            messages.map { "\($0.role.rawValue): \($0.content)" },
            [
                "system: CUSTOM-INSTRUCTIONS",
                "user: ex in 1",
                "assistant: ex out 1",
                "user: ex in 2",
                "assistant: ex out 2",
                "user: the input",
            ])
    }

    func testRendersWithNoExamples() {
        let request = CleanupRequest(modelID: .qwen3_1_7b, instructions: "I", input: "hi", maxOutputTokens: 32)
        let messages = MLXLoadedCleanupModel.chatMessages(for: request)
        XCTAssertEqual(messages.map { "\($0.role.rawValue): \($0.content)" }, ["system: I", "user: hi"])
    }

    /// The default request (no `examples:` argument) carries none — production always supplies
    /// `CleanupPrompt.effective(_:)`'s examples explicitly.
    func testRequestDefaultsToNoExamples() {
        let request = CleanupRequest(modelID: .qwen3_1_7b, instructions: "I", input: "hi", maxOutputTokens: 32)
        XCTAssertTrue(request.examples.isEmpty)
    }
}
