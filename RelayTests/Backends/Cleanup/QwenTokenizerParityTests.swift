import XCTest

@testable import Relay

/// Spike S1 (spec §21), kept as a regression test. Opt-in: set
/// `TEST_RUNNER_RELAY_QWEN_TOKENIZER_DIR` to a folder holding the pinned `tokenizer.json` and
/// `tokenizer_config.json`.
final class QwenTokenizerParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let ids: [Int]
        }
        let imEndID: Int
        let cases: [Case]
    }

    func testRelayTokenizerMatchesTransformersIDs() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RELAY_QWEN_TOKENIZER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_RELAY_QWEN_TOKENIZER_DIR to run the tokenizer parity check")
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "qwen3-tokenizer-parity", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 30)

        let tokenizer = try await RelayBPETokenizer.load(from: URL(fileURLWithPath: directory, isDirectory: true))

        var encodeMismatches = 0
        var decodeMismatches = 0
        for (index, testCase) in fixture.cases.enumerated() {
            let ids = tokenizer.encode(testCase.text, addSpecialTokens: false)
            if ids != testCase.ids {
                encodeMismatches += 1
                XCTFail("encode mismatch at case \(index)")
            }
            if tokenizer.decode(testCase.ids, skipSpecialTokens: false) != testCase.text {
                decodeMismatches += 1
                XCTFail("decode mismatch at case \(index)")
            }
        }
        XCTAssertEqual(tokenizer.tokenID(for: "<|im_end|>"), fixture.imEndID)
        print("S1 encodeMismatches=\(encodeMismatches) decodeMismatches=\(decodeMismatches) imEnd=\(tokenizer.tokenID(for: "<|im_end|>") ?? -1)")
    }
}
