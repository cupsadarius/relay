import XCTest

@testable import Relay

final class SelfCorrectionPrePassTests: XCTestCase {
    private func applied(_ text: String) -> String { SelfCorrectionPrePass.apply(to: text).text }

    /// The eval corpus correction cases the pre-pass rewrites (spec §10.1, §19).
    func testCorpusCorrectionCasesKeepOnlyTheNewValue() {
        let cases: [(String, String)] = [
            ("set the port to 3, no, 4", "set the port to 4"),
            ("open src/app.swift I mean src/main.swift", "open src/main.swift"),
            ("the file is config.yaml sorry config.yml", "the file is config.yml"),
            ("set retries to 5 scratch that 3", "set retries to 3"),
            ("pin it to 1.4 or rather 1.5", "pin it to 1.5"),
            ("port three no four", "port four"),
            ("run it with --verbose no --quiet", "run it with --quiet"),
            ("look in ~/Library/Logs no wait /var/log", "look in /var/log"),
            ("call userService no wait authService", "call authService"),
            ("go to https://staging.example.com sorry https://prod.example.com", "go to https://prod.example.com"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(applied(input), expected, input)
        }
    }

    func testRecordsTheReplacedValues() {
        XCTAssertEqual(SelfCorrectionPrePass.apply(to: "set the port to 3, no, 4").replaced, ["3"])
        XCTAssertEqual(SelfCorrectionPrePass.apply(to: "port three no four").replaced, ["3"])
        XCTAssertEqual(SelfCorrectionPrePass.apply(to: "port 3 no 4 and 5 sorry 6").replaced, ["3", "5"])
        XCTAssertEqual(SelfCorrectionPrePass.apply(to: "run it with --verbose no --quiet").replaced, ["--verbose"])
    }

    func testAppliesIndependentPairsInOneSentence() {
        XCTAssertEqual(applied("set port 3 no 4 and timeout 10 or rather 20"), "set port 4 and timeout 20")
        XCTAssertEqual(applied("use --verbose sorry --quiet and port 3, no, 4"), "use --quiet and port 4")
    }

    /// Corpus correction cases the pre-pass leaves to the model: bare "wait" and bare "actually"
    /// are not pre-pass cues, and a replacement followed by a unit or count word is ambiguous.
    func testCorpusCorrectionCasesItLeavesToTheModel() {
        for input in [
            "bump the timeout to 30 no wait 45 seconds", "use node 18 wait 20 for the build",
            "run it with 4 threads actually 8 threads", "version 1.2 actually 1.3", "allocate 16 no 32 gigabytes",
        ] {
            XCTAssertEqual(applied(input), input, input)
        }
    }

    /// A comma on only one side of the cue is not a correction ("3 no, 2", "10, no 2").
    func testSeparatorsMustBeSymmetric() {
        XCTAssertEqual(applied("set the port to 3, no, 4"), "set the port to 4")
        XCTAssertEqual(applied("set the port to 3 no 4"), "set the port to 4")
        XCTAssertEqual(applied("set the port to 3, no 4"), "set the port to 3, no 4")
        XCTAssertEqual(applied("set the port to 3 no, 4"), "set the port to 3 no, 4")
    }

    func testCueNegativesStayUnchanged() {
        for input in [
            "bump to 2.0 no changes needed", "say no to the 3 extra meetings", "wait for build 42 to finish",
            "it actually works on port 8080", "sorry about the 2 failing tests", "set timeout to 30 no retries 5",
            // Final review: ordinary sentences the first pre-pass rewrote.
            "do step 1, wait 10 seconds, then step 2", "press 4, wait one second, press 5", "5 yes, 3 no, 2 abstain",
            "out of 10, no 2 people agree", "we shipped 5, actually 3 were late", "invited 5, no 1 came",
            "out of 10 no 2 people agree", "invited 5 no 1 came", "invited 5 no one came",
        ] {
            XCTAssertEqual(SelfCorrectionPrePass.apply(to: input), PrePassedText(text: input, replaced: []), input)
        }
    }

    /// Conservative: anything the detector is unsure about is left for the model (or unchanged).
    func testUnsureCasesStayUnchanged() {
        for input in [
            "3, no, 4, no wait, 5 workers", // chained
            "use --force scratch that", // retraction only
            "uh change the user service no wait the auth service", // no literals
            "we need 2 no one else", // "no one"
            "version 4 actually works on port 8080", // replacement not right after the cue
            "we have 3 servers but actually 5 are down", // words between the old value and the cue
            "we have 3 servers but no 5 are down", // words between the old value and the cue
            "run it with 4 threads no 8 threads", // unit after the replacement
            "set 3 workers. No, 4 is fine", // clause boundary
        ] {
            XCTAssertEqual(applied(input), input, input)
        }
    }

    func testTextWithoutCorrectionsIsUnchanged() {
        XCTAssertEqual(SelfCorrectionPrePass.apply(to: "Ship it on Friday."), PrePassedText(text: "Ship it on Friday.", replaced: []))
    }
}
