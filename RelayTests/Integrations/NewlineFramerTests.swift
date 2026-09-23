import XCTest

@testable import Relay

final class NewlineFramerTests: XCTestCase {
    private struct Result {
        var lines: [String] = []
        var oversized = 0
        var closeRequests: [Bool] = []
    }

    private func feed(_ chunks: [[UInt8]], maxLineBytes: Int = 16) -> Result {
        var framer = NewlineFramer(maxLineBytes: maxLineBytes)
        var result = Result()
        for chunk in chunks {
            let shouldClose = framer.append(
                ArraySlice(chunk),
                onLine: { result.lines.append($0) },
                onOversizedLine: { _ in result.oversized += 1 },
                onOversizedUnterminated: { _ in }
            )
            result.closeRequests.append(shouldClose)
        }
        return result
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testLinesSplitAcrossReadsAreReassembledInOrder() {
        let result = feed([bytes("ab"), bytes("c\nde"), bytes("f\n\ng\n")])
        XCTAssertEqual(result.lines, ["abc", "def", "", "g"])
        XCTAssertEqual(result.closeRequests, [false, false, false])
    }

    func testOversizedTerminatedLineIsReportedAndSkipped() {
        let result = feed([bytes(String(repeating: "x", count: 17) + "\nok\n")])
        XCTAssertEqual(result.lines, ["ok"])
        XCTAssertEqual(result.oversized, 1)
    }

    func testUnterminatedOverflowRequestsCloseReportsItsSizeAndDiscardsTheBuffer() {
        var framer = NewlineFramer(maxLineBytes: 4)
        var unterminated: [Int] = []
        XCTAssertTrue(
            framer.append(
                ArraySlice(bytes("12345")),
                onLine: { _ in XCTFail() },
                onOversizedLine: { _ in XCTFail() },
                onOversizedUnterminated: { unterminated.append($0) }
            ))
        XCTAssertEqual(unterminated, [5])
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    /// Ported from `UnixSocketServerTests.testOversizedTerminatedLineIsReportedAndFollowingLinesStillArrive`
    /// (which drove `UnixSocketClientConnection.append` directly) at the real limit.
    func testOversizedTerminatedLineReportsItsByteCountAndFollowingLinesStillArrive() {
        var framer = NewlineFramer(maxLineBytes: UnixSocketServer.maxLineBytes)
        var lines: [String] = []
        var oversizedByteCounts: [Int] = []
        var chunk = [UInt8](repeating: UInt8(ascii: "a"), count: UnixSocketServer.maxLineBytes + 1)
        chunk.append(UInt8(ascii: "\n"))
        chunk.append(contentsOf: Array(#"{"ok":1}"#.utf8))
        chunk.append(UInt8(ascii: "\n"))

        let shouldClose = framer.append(
            chunk[...],
            onLine: { lines.append($0) },
            onOversizedLine: { oversizedByteCounts.append($0) },
            onOversizedUnterminated: { _ in XCTFail("no unterminated oversized line in this test") }
        )

        XCTAssertFalse(shouldClose)
        XCTAssertEqual(oversizedByteCounts, [UnixSocketServer.maxLineBytes + 1])
        XCTAssertEqual(lines, [#"{"ok":1}"#])
    }

    func testLongLineArrivingInManySmallReadsIsDeliveredOnce() {
        let chunks = Array(repeating: bytes("abcd"), count: 512) + [bytes("\n")]
        let result = feed(chunks, maxLineBytes: 4_096)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines.first?.utf8.count, 2_048)
    }

    func testInvalidUTF8LineIsSkippedWithoutAffectingTheNextLine() {
        let result = feed([[0xFF, 0x0A] + bytes("ok\n")])
        XCTAssertEqual(result.lines, ["ok"])
    }
}
