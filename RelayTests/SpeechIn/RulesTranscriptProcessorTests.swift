import XCTest

@testable import Relay

final class RulesTranscriptProcessorTests: XCTestCase {
    private func process(_ text: String) -> String {
        RulesTranscriptProcessor().process(text)
    }

    func testTrimsAndCollapsesSpaces() {
        XCTAssertEqual(process("  um   hello\tworld  "), "hello\tworld")
    }

    func testCollapsesThreeOrMoreBlankLinesToOneNewline() {
        XCTAssertEqual(process("first\n\n\n\nsecond"), "first\nsecond")
    }

    func testFillersLeaveWithTheirCommasAndSpaces() {
        XCTAssertEqual(process("So, um, we should go."), "So, we should go.")
        XCTAssertEqual(process("I think uh we should go."), "I think we should go.")
        XCTAssertEqual(process("I think, um."), "I think.")
        XCTAssertEqual(process("Well umm... maybe"), "Well maybe")
        XCTAssertEqual(process("It was, er, erm, fine"), "It was, fine")
        XCTAssertEqual(process("Done, uh"), "Done")
        XCTAssertEqual(process("(um, aside)"), "(aside)")
    }

    func testAFillerThatStartedASentenceHandsOnItsCapital() {
        XCTAssertEqual(process("Um, so I think"), "So I think")
        XCTAssertEqual(process("Hello. Uh, we left. Ah. Then"), "Hello. We left. Then")
        XCTAssertEqual(process("Uh, um, okay"), "Okay")
    }

    func testLineBreaksAreKept() {
        XCTAssertEqual(process("First line.\nUm, second"), "First line.\nSecond")
        XCTAssertEqual(process("one um\ntwo"), "one\ntwo")
        XCTAssertEqual(process("one um\r\ntwo"), "one\r\ntwo")
    }

    func testOtherWordsAreLeftAlone() {
        for text in [
            "The umbrella is ahead of the error.",
            "Uhura said uh-huh.",
            "Take him to the ER.",
            "UM is a university.",
            "drum, Ahab, ermine",
            "Plain text, nothing to do.",
            "",
        ] {
            XCTAssertEqual(process(text), text)
        }
    }
}
