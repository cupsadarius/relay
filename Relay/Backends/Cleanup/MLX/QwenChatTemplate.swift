import Foundation

enum QwenChatTemplateError: Error, Equatable, Sendable {
    case unsupportedMessages
}

/// Qwen3 ChatML in non-thinking mode: the empty think block `enable_thinking=False` produces
/// (spec §10). Relay renders this itself instead of running the model's Jinja template. There is
/// no `/no_think` soft switch: the official template does not add one, and the models copied it
/// into their output. Example turns render as Qwen3's template renders earlier turns: plain
/// user/assistant ChatML with no think block.
enum QwenChatTemplate {
    static func render(system: String, examples: [CleanupExample] = [], user: String) -> String {
        var prompt = "<|im_start|>system\n\(system)<|im_end|>\n"
        for example in examples {
            prompt += "<|im_start|>user\n\(example.input)<|im_end|>\n<|im_start|>assistant\n\(example.output)<|im_end|>\n"
        }
        return prompt + "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Accepts `[system, (user, assistant)*, user]` message dictionaries (the shape MLXLMCommon's
    /// `DefaultMessageGenerator` produces for `UserInput(chat:)` with example turns).
    static func render(messages: [[String: any Sendable]]) throws -> String {
        func content(_ index: Int, _ role: String) throws -> String {
            guard messages[index]["role"] as? String == role, let text = messages[index]["content"] as? String else {
                throw QwenChatTemplateError.unsupportedMessages
            }
            return text
        }
        guard messages.count >= 2, messages.count % 2 == 0 else { throw QwenChatTemplateError.unsupportedMessages }
        let system = try content(0, "system")
        let examples = try stride(from: 1, to: messages.count - 1, by: 2).map {
            CleanupExample(input: try content($0, "user"), output: try content($0 + 1, "assistant"))
        }
        return render(system: system, examples: examples, user: try content(messages.count - 1, "user"))
    }
}
