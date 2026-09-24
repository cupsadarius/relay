import Foundation
import WhisperKit

/// Relay's own handle on the Qwen3 BPE tokenizer, bridged to ArgmaxCore's tokenizer (re-exported
/// by WhisperKit), which maps `Qwen2Tokenizer` to `BPETokenizer`. Loads only from a local,
/// already-verified folder (`tokenizer.json` + `tokenizer_config.json`); never touches the network.
///
/// This is the only cleanup file that imports WhisperKit. MLX files never import it (spec §5.3):
/// `MLXTokenizerAdapter.swift` adapts this type to `MLXLMCommon.Tokenizer`.
struct RelayBPETokenizer: Sendable {
    private let wrapper: TokenizerWrapper

    static func load(from directory: URL) async throws -> RelayBPETokenizer {
        RelayBPETokenizer(wrapper: try await AutoTokenizerWrapper.from(modelFolder: directory))
    }

    func encode(_ text: String, addSpecialTokens: Bool) -> [Int] {
        wrapper.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(_ ids: [Int], skipSpecialTokens: Bool) -> String {
        wrapper.decode(tokens: ids, skipSpecialTokens: skipSpecialTokens)
    }

    func tokenID(for token: String) -> Int? { wrapper.convertTokenToId(token) }
    func token(for id: Int) -> String? { wrapper.convertIdToToken(id) }

    var bosToken: String? { wrapper.bosToken }
    var eosToken: String? { wrapper.eosToken }
    var unknownToken: String? { wrapper.unknownToken }
}
