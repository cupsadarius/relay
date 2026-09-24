import XCTest

@testable import Relay

final class QwenChatTemplateTests: XCTestCase {
    /// Byte-for-byte what Qwen3's own chat template renders for `[system, user]` with
    /// `add_generation_prompt=True, enable_thinking=False`: no `/no_think` soft switch in the user
    /// turn (the model copied it into its output, which the validator then rejected).
    func testRendersNonThinkingChatML() {
        XCTAssertEqual(
            QwenChatTemplate.render(system: "SYS", user: "hello"),
            "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

    /// Qwen3's template for `[system, user a, assistant b, user hi]` (transformers 4.56,
    /// `enable_thinking=False`): earlier assistant turns carry no think block.
    func testRendersExampleTurnsBeforeTheUserTurn() {
        XCTAssertEqual(
            QwenChatTemplate.render(system: "SYS", examples: [CleanupExample(input: "a", output: "b")], user: "hi"),
            "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\na<|im_end|>\n<|im_start|>assistant\nb<|im_end|>\n"
                + "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

    func testRendersSystemPlusUserMessageDictionaries() throws {
        let messages: [[String: any Sendable]] = [["role": "system", "content": "SYS"], ["role": "user", "content": "hi"]]
        XCTAssertEqual(try QwenChatTemplate.render(messages: messages), QwenChatTemplate.render(system: "SYS", user: "hi"))
    }

    func testRendersExampleTurnMessageDictionaries() throws {
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "SYS"], ["role": "user", "content": "a"], ["role": "assistant", "content": "b"],
            ["role": "user", "content": "hi"],
        ]
        XCTAssertEqual(
            try QwenChatTemplate.render(messages: messages),
            QwenChatTemplate.render(system: "SYS", examples: [CleanupExample(input: "a", output: "b")], user: "hi")
        )
    }

    func testRejectsAnyOtherMessageShape() {
        let userOnly: [[String: any Sendable]] = [["role": "user", "content": "hi"]]
        let endsWithAssistant: [[String: any Sendable]] = [
            ["role": "system", "content": "S"], ["role": "user", "content": "a"], ["role": "assistant", "content": "b"],
        ]
        let twoUsersInARow: [[String: any Sendable]] = [
            ["role": "system", "content": "S"], ["role": "user", "content": "a"], ["role": "user", "content": "b"],
            ["role": "assistant", "content": "c"], ["role": "user", "content": "d"],
        ]
        XCTAssertThrowsError(try QwenChatTemplate.render(messages: userOnly))
        XCTAssertThrowsError(try QwenChatTemplate.render(messages: endsWithAssistant))
        XCTAssertThrowsError(try QwenChatTemplate.render(messages: twoUsersInARow))
    }
}
