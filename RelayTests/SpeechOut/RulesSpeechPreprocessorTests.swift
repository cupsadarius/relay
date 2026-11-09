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

        let output = subject.prepare(text: source)

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

        let output = subject.prepare(text: source)

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
            subject.prepare(text: source),
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
            subject.prepare(text: source),
            "Shopping list: apples. pears. plums."
        )
    }

    func testAnnouncesTwoColumnBoxTableAndLabelsRowsByFirstCell() {
        let source = """
            Timeline

            ┌─────────┬──────────────┐
            │  When   │     What     │
            ├─────────┼──────────────┤
            │ Mar–Apr │ Exec demo.   │
            ├─────────┼──────────────┤
            │         │ Vendor       │
            │ May–Jun │ onboarding   │
            │         │ gauntlet     │
            └─────────┴──────────────┘
            After.
            """

        XCTAssertEqual(
            subject.prepare(text: source),
            "Timeline Table with 2 rows, by When and What. Mar–Apr: Exec demo. "
                + "May–Jun: Vendor onboarding gauntlet. End of table. After."
        )
    }

    func testNamesTheColumnBeforeEachValueInWiderPipeTable() {
        let source = """
            | Backend | Latency | Status |
            |---|---|:---:|
            | Kokoro | 120 ms | **ok** |
            | Apple |  | down |
            """

        XCTAssertEqual(
            subject.prepare(text: source),
            "Table with 2 rows. Columns: Backend, Latency, Status. Kokoro: Latency 120 ms. Status ok. "
                + "Apple: Status down. End of table."
        )
    }

    func testPointsToTheScreenInsteadOfReadingLargeTable() {
        let rows = (1...16).map { "| r\($0) | v\($0) |" }.joined(separator: "\n")
        let source = "Before.\n| Key | Value |\n|---|---|\n\(rows)\nAfter."

        XCTAssertEqual(
            subject.prepare(text: source),
            "Before. There is a table on screen with 16 rows. Please read it there. After."
        )
    }

    func testReadsBoxAroundSingleLineAsPlainText() {
        let source = """
            ┌──────────────┐
            │ Build passed │
            └──────────────┘
            """

        XCTAssertEqual(subject.prepare(text: source), "Build passed.")
    }

    func testCollapsesRunsOfWhitespaceWithoutJoiningWords() {
        let source = "First\n\n\nSecond    third\t\t\tfourth"

        XCTAssertEqual(
            subject.prepare(text: source),
            "First Second third fourth"
        )
    }

    func testAutomaticModeFailsClosedForUnclosedBacktickFence() {
        let source = """
            Before.
            ```swift
            let secret = true
            """

        let output = subject.prepare(text: source)

        XCTAssertEqual(output, "Before. \(codeBlockCue)")
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("swift"))
    }

    func testUserRequestedModeFailsClosedForUnclosedTildeFence() {
        let source = """
            Before.
              ~~~json
              { "secret": true }
            """

        let output = subject.prepare(text: source)

        XCTAssertEqual(output, "Before. \(codeBlockCue)")
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("json"))
    }

    func testLongBacktickFenceIgnoresShorterRunsInsideItsContent() {
        let source = """
            Before.
            ````text
            hidden start
            ```
            hidden end
            ````
            After.
            """

        let output = subject.prepare(text: source)

        XCTAssertEqual(output, "Before. \(codeBlockCue) After.")
        XCTAssertFalse(output.contains("hidden"))
    }

    func testTildeFenceIsRemovedInUserRequestedMode() {
        let source = """
            Before.
            ~~~swift
            print("hidden")
            ~~~
            After.
            """

        let output = subject.prepare(text: source)

        XCTAssertEqual(output, "Before. \(codeBlockCue) After.")
        XCTAssertFalse(output.contains("hidden"))
    }

    func testInlineTripleBackticksAreNotTreatedAsFencedCode() {
        let source = "Explain ```this phrase``` briefly."

        XCTAssertEqual(
            subject.prepare(text: source),
            "Explain this phrase briefly."
        )
    }

    func testRemovesClosingAndSetextHeadingMarkersAndNestedBlockquotes() {
        let source = """
            ## Release notes ##
            Migration guide
            ---------------
            >>> Read this now.
            """

        XCTAssertEqual(
            subject.prepare(text: source),
            "Release notes Migration guide Read this now."
        )
    }
}
