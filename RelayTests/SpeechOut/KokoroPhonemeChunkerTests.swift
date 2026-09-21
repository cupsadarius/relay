import XCTest
@testable import Relay

final class KokoroPhonemeChunkerTests: XCTestCase {
    func testEmptyInputProducesNoChunks() {
        XCTAssertTrue(KokoroPhonemeChunker().chunks(from: "").isEmpty)
    }

    func testShortInputStaysWhole() {
        let input = "həˈloʊ wɝld."
        XCTAssertEqual(KokoroPhonemeChunker().chunks(from: input), [input])
    }

    func testLongInputPrefersSentenceBoundaryAndPreservesSequence() {
        let first = String(repeating: "a", count: 450) + "."
        let second = String(repeating: "b", count: 120)
        let input = first + second
        let chunks = KokoroPhonemeChunker(preferredTarget: 480, hardMaximum: 510).chunks(from: input)

        XCTAssertEqual(chunks.first, first)
        XCTAssertEqual(chunks.joined(), input)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 510 })
    }

    func testNoBoundaryHardSplitsAndTerminates() {
        let input = String(repeating: "x", count: 1_501)
        let chunks = KokoroPhonemeChunker(preferredTarget: 480, hardMaximum: 510).chunks(from: input)

        XCTAssertEqual(chunks.joined(), input)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 510 })
        XCTAssertEqual(chunks.dropLast().map(\.count), [480, 480, 480])
    }
}
