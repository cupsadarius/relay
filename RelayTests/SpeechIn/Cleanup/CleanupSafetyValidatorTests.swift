import XCTest

@testable import Relay

final class CleanupSafetyValidatorTests: XCTestCase {
    private let validator = CleanupSafetyValidator()

    private func verdict(_ input: String, _ output: String) -> ValidationVerdict {
        validator.validate(input: input, output: output)
    }

    func testEmptyOutputIsRejected() {
        XCTAssertEqual(verdict("hello there", "  \n "), .reject(.empty))
    }

    func testReasoningMarkupIsRejected() {
        for marker in ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|endoftext|>"] {
            XCTAssertEqual(verdict("hello there", "Hello \(marker) there."), .reject(.reasoningMarkup), marker)
        }
    }

    func testWrapperPrefixesAreRejected() {
        for prefix in ["Here is", "Here's", "Sure", "Cleaned text:", "Output:", "Result:"] {
            XCTAssertEqual(verdict("check the build", "\(prefix) Check the build."), .reject(.wrapper), prefix)
        }
    }

    func testWrapperPhraseAlreadyInTheInputIsAllowed() {
        XCTAssertEqual(verdict("sure let's do it", "Sure, let's do it."), .accept("Sure, let's do it."))
    }

    /// Review fix 2: the exemption requires the input to itself START with the phrase (after
    /// trimming fillers), not merely contain it — an input that opens with "here's" still gets a
    /// real "here's the cleaned text:" preamble rejected.
    func testWrapperExemptionRequiresTheInputToStartWithThePhrase() {
        XCTAssertEqual(
            verdict("here's the plan ship it friday", "Here's the cleaned text: Here's the plan, ship it Friday."),
            .reject(.wrapper)
        )
    }

    func testWrapperExemptionSurvivesLeadingFillers() {
        XCTAssertEqual(verdict("uh sure let's do it", "Sure, let's do it."), .accept("Sure, let's do it."))
    }

    /// A mid-sentence, unrelated colon (not part of a wrapper preamble) never triggers the
    /// always-reject rule.
    func testAWrapperPrefixWithNoNearbyColonIsStillExemptWhenTheInputStartsWithIt() {
        XCTAssertEqual(
            verdict("sure it starts at 3:00", "Sure, it starts at 3:00."),
            .accept("Sure, it starts at 3:00.")
        )
    }

    func testANewCodeFenceIsAWrapper() {
        XCTAssertEqual(verdict("check the build", "```\nCheck the build.\n```"), .reject(.wrapper))
    }

    func testLengthLimitIsInputTimes1Point75Plus16() {
        let input = "check the build" // 15 characters → limit 42.25
        XCTAssertEqual(verdict(input, String(repeating: "a", count: 42)), .accept(String(repeating: "a", count: 42)))
        XCTAssertEqual(verdict(input, String(repeating: "a", count: 43)), .reject(.tooLong))
    }

    func testIdenticalOutputIsValidAndOutputIsTrimmed() {
        XCTAssertEqual(verdict("Ship it on Friday.", "Ship it on Friday."), .accept("Ship it on Friday."))
        XCTAssertEqual(verdict("ship it", "  Ship it.\n"), .accept("Ship it."))
    }

    func testSpecCorrectionTable() {
        let rows: [(String, String, ValidationVerdict)] = [
            ("set the port to 3, no, 4", "Set the port to 4.", .accept("Set the port to 4.")),
            ("run it with --verbose no --quiet", "Run it with --quiet.", .accept("Run it with --quiet.")),
            ("open src/app.swift I mean src/main.swift", "Open src/main.swift.", .accept("Open src/main.swift.")),
            ("port three no four", "Port 4.", .accept("Port 4.")),
            ("3, no, 4, no wait, 5 workers", "5 workers.", .accept("5 workers.")),
            ("set the port to 3, no, 4", "Set the port to 3.", .reject(.literalMissing)),
            ("bump to 2.0 no changes needed", "Bump to 2.0. No changes needed.", .accept("Bump to 2.0. No changes needed.")),
            ("use --force scratch that", "Scratch that.", .reject(.literalMissing)),
            ("use --force scratch that", "", .reject(.empty)),
            ("version 1.2 actually 1.3", "Version 1.2, actually 1.3.", .accept("Version 1.2, actually 1.3.")),
        ]
        for (input, output, expected) in rows {
            XCTAssertEqual(verdict(input, output), expected, "\(input) → \(output)")
        }
    }

    func testMissingReplacementMakesTheOldLiteralRequired() {
        XCTAssertEqual(verdict("use port 3 sorry", "Use the port."), .reject(.literalMissing))
    }

    func testKindClassMismatchGivesNoExemption() {
        XCTAssertEqual(verdict("port 3 no --force", "Port --force."), .reject(.literalMissing))
    }

    func testClauseBoundaryBlocksExemption() {
        XCTAssertEqual(verdict("set it to 3. No, use 4", "Use 4."), .reject(.literalMissing))
    }

    func testWindowLimitBlocksExemption() {
        XCTAssertEqual(verdict("set 3 then wait for the build and then 4", "Set 4."), .reject(.literalMissing))
    }

    func testSpokenNumbersAreSatisfiedByWordsOrDigits() {
        XCTAssertEqual(verdict("retry three times", "Retry 3 times."), .accept("Retry 3 times."))
        XCTAssertEqual(verdict("retry three times", "Retry three times."), .accept("Retry three times."))
        XCTAssertEqual(verdict("set scale to two point five", "Set scale to 2.5."), .accept("Set scale to 2.5."))
        XCTAssertEqual(verdict("one hundred and five rows", "105 rows."), .accept("105 rows."))
        XCTAssertEqual(verdict("we have twenty-five tickets", "We have 25 tickets."), .accept("We have 25 tickets."))
    }

    func testDigitsAreNeverSatisfiedByWords() {
        XCTAssertEqual(verdict("set 3 workers", "Set three workers."), .reject(.literalMissing))
    }

    func testInventedLiteralsAreRejected() {
        XCTAssertEqual(verdict("go to example dot com", "Go to example.com."), .reject(.literalInvented))
        XCTAssertEqual(verdict("use version two", "Use v2."), .reject(.literalInvented))
        XCTAssertEqual(verdict("open readme.md", "Open Readme.md."), .reject(.literalInvented))
        XCTAssertEqual(verdict("retry three times", "Retry 4 times."), .reject(.literalInvented))
    }

    func testInventedSpokenNumberWithNoInputNumberIsRejected() {
        // Controller decision: the invented-literal check also covers .spokenNumber output
        // literals. An output number absent from the input, in digits or in words, is invented.
        XCTAssertEqual(verdict("set retries to", "Set retries to four."), .reject(.literalInvented))
    }

    func testApostrophesAreNotQuotes() {
        XCTAssertEqual(verdict("don't change Bob's config", "Don't change Bob's config."), .accept("Don't change Bob's config."))
    }

    func testTheTestToolSample() {
        XCTAssertEqual(
            verdict(
                "uh change the user service no wait the auth service to use refresh tokens and don't change the API",
                "Change the auth service to use refresh tokens. Don't change the API."
            ),
            .accept("Change the auth service to use refresh tokens. Don't change the API.")
        )
    }

    func testRejectionLabelsAreFixedStrings() {
        XCTAssertEqual(
            ValidationRejection.allCases.map(\.label),
            [
                "empty output", "reasoning markup", "wrapper text", "output too long", "literal invented", "literal missing",
            ])
    }
}
