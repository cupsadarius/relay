import XCTest

@testable import Relay

final class RulesTranscriptProcessorTests: XCTestCase {
    func testTrimsCollapsesSpacesAndKeepsFillerWords() {
        let output = RulesTranscriptProcessor().process("  um   hello\tworld  ")

        XCTAssertEqual(output, "um hello\tworld")
    }

    func testCollapsesThreeOrMoreBlankLinesToOneNewline() {
        let output = RulesTranscriptProcessor().process("first\n\n\n\nsecond")

        XCTAssertEqual(output, "first\nsecond")
    }
}
