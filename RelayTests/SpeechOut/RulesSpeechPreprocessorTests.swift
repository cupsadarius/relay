import XCTest
@testable import Relay

final class RulesSpeechPreprocessorTests: XCTestCase {
    private let subject = RulesSpeechPreprocessor()
    private let codeBlockCue = "There is a code block on screen. Please read it there."

    func testAutomaticModeReplacesShortAndLongFencedCodeBlocks() {
        let longCode = String(repeating: "let value = 1; ", count: 12)
        let source = """
        Before.
        ```swift
        print(1)
        ```
        Between.
        ```swift
        \(longCode)
        ```
        After.
        """

        let output = subject.prepare(text: source, mode: .automatic)

        XCTAssertEqual(
            output,
            "Before. \(codeBlockCue) Between. \(codeBlockCue) After."
        )
        XCTAssertFalse(output.contains("print(1)"))
        XCTAssertFalse(output.contains("let value"))
    }

    func testUserRequestedModeReplacesShortAndLongFencedCodeBlocks() {
        let longCode = String(repeating: "let value = 1; ", count: 12)
        let source = """
        Before.
        ```swift
        print(1)
        ```
        Between.
        ```swift
        \(longCode)
        ```
        After.
        """

        let output = subject.prepare(text: source, mode: .userRequested)

        XCTAssertEqual(
            output,
            "Before. \(codeBlockCue) Between. \(codeBlockCue) After."
        )
        XCTAssertFalse(output.contains("print(1)"))
        XCTAssertFalse(output.contains("let value"))
    }

    func testRemovesMarkdownDecorationAndKeepsReadableText() {
        let source = """
        ## **Release** notes
        > Read [the migration guide](https://example.com/guide) and `run tests`.
        """

        XCTAssertEqual(
            subject.prepare(text: source, mode: .automatic),
            "Release notes Read the migration guide and run tests."
        )
    }

    func testConvertsBulletsToSentenceBreaks() {
        let source = """
        Shopping list:
        - apples
        * pears
        + plums
        """

        XCTAssertEqual(
            subject.prepare(text: source, mode: .automatic),
            "Shopping list: apples. pears. plums."
        )
    }

    func testCollapsesRunsOfWhitespaceWithoutJoiningWords() {
        let source = "First\n\n\nSecond    third\t\t\tfourth"

        XCTAssertEqual(
            subject.prepare(text: source, mode: .automatic),
            "First Second third fourth"
        )
    }
}
