import Foundation

enum QwenChatTemplateError: Error, Equatable, Sendable {
    case unsupportedMessages
}

/// Qwen3 ChatML in non-thinking mode: the empty think block `enable_thinking=False` produces
/// (spec §10). Relay renders this itself instead of running the model's Jinja template. There is
/// no `/no_think` soft switch: the official template does not add one, and the models copied it
/// into their output.
enum QwenChatTemplate {
    static func render(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Accepts exactly `[system, user]` message dictionaries (the shape MLXLMCommon's
    /// `DefaultMessageGenerator` produces for `UserInput(chat: [.system, .user])`).
    static func render(messages: [[String: any Sendable]]) throws -> String {
        guard messages.count == 2,
            messages[0]["role"] as? String == "system",
            messages[1]["role"] as? String == "user",
            let system = messages[0]["content"] as? String,
            let user = messages[1]["content"] as? String
        else { throw QwenChatTemplateError.unsupportedMessages }
        return render(system: system, user: user)
    }
}
