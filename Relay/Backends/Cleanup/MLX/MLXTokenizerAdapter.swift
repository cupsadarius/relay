import Foundation
import MLXLMCommon

/// Local-only `TokenizerLoader`: wraps `RelayBPETokenizer` (spec §13.3). Never uses a Hub client.
struct RelayTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any Tokenizer {
        MLXQwenTokenizer(base: try await RelayBPETokenizer.load(from: directory))
    }
}

/// `MLXLMCommon.Tokenizer` over `RelayBPETokenizer`. The chat template is `QwenChatTemplate`,
/// encoded without extra special tokens; end of turn (`<|im_end|>`) is the EOS token.
struct MLXQwenTokenizer: Tokenizer {
    static let endOfTurnToken = "<|im_end|>"

    let base: RelayBPETokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { base.tokenID(for: token) }
    func convertIdToToken(_ id: Int) -> String? { base.token(for: id) }

    var bosToken: String? { base.bosToken }
    var eosToken: String? { Self.endOfTurnToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        base.encode(try QwenChatTemplate.render(messages: messages), addSpecialTokens: false)
    }
}
