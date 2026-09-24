import XCTest

@testable import Relay

final class SelfCorrectionDetectorTests: XCTestCase {
    private func pairs(_ text: String) -> [String] {
        let literals = ProtectedLiteralExtractor.extractAll(from: text)
        return SelfCorrectionDetector.analyze(text, literals: literals).pairs
            .map { "\(literals[$0.old].value)->\(literals[$0.new].value)" }
            .sorted()
    }

    func testSpecTablePairs() {
        XCTAssertEqual(pairs("set the port to 3, no, 4"), ["3->4"])
        XCTAssertEqual(pairs("run it with --verbose no --quiet"), ["--verbose->--quiet"])
        XCTAssertEqual(pairs("open src/app.swift I mean src/main.swift"), ["src/app.swift->src/main.swift"])
        XCTAssertEqual(pairs("port three no four"), ["three->four"])
        XCTAssertEqual(pairs("version 1.2 actually 1.3"), ["1.2->1.3"])
    }

    func testChainFollowsTokenIdentity() {
        let text = "3, no, 4, no wait, 5 workers"
        let literals = ProtectedLiteralExtractor.extractAll(from: text)
        let analysis = SelfCorrectionDetector.analyze(text, literals: literals)
        XCTAssertEqual(pairs(text), ["3->4", "4->5"])
        XCTAssertEqual(analysis.chainTargets(from: 0).map { literals[$0].value }, ["4", "5"])
        XCTAssertEqual(analysis.chainTargets(from: 2), [])
    }

    func testCueNegativesProduceNoPairs() {
        XCTAssertEqual(pairs("bump to 2.0 no changes needed"), [])
        XCTAssertEqual(pairs("wait for build 42 to finish"), [])
        XCTAssertEqual(pairs("it actually works on port 8080"), [])
        XCTAssertEqual(pairs("sorry about the 2 failing tests"), [])
        XCTAssertEqual(pairs("say no to the 3 extra meetings"), [])
    }

    func testMissingReplacementGivesNoPair() {
        XCTAssertEqual(pairs("use --force scratch that"), [])
    }

    func testKindClassMismatchGivesNoPair() {
        XCTAssertEqual(pairs("port 3 no --force"), [])
    }

    func testClauseBoundaryBlocksPairing() {
        XCTAssertEqual(pairs("set it to 3. No, use the default 4"), [])
    }

    /// Review fix 4's off-by-one: up to 4 words are allowed, not 3. The old side (and a
    /// multi-word cue's new side) still use the window; a single-word cue's new side does not
    /// (see `testSingleWordCuesRequireTheReplacementImmediatelyAfter`).
    func testWindowIsFourWords() {
        XCTAssertEqual(pairs("port 3 aaa bbb ccc ddd wait 4"), ["3->4"])
        XCTAssertEqual(pairs("port 3 aaa bbb ccc ddd eee wait 4"), [])
        XCTAssertEqual(pairs("port 3 no wait aaa bbb ccc ddd 4"), ["3->4"])
        XCTAssertEqual(pairs("port 3 no wait aaa bbb ccc ddd eee 4"), [])
    }

    /// Review fix 4: the single-word cues "no", "wait" and "sorry" need their replacement right
    /// after them, with no word tokens between (a soft separator is still fine).
    func testSingleWordCuesRequireTheReplacementImmediatelyAfter() {
        XCTAssertEqual(pairs("port 3 no we want 4"), [])
        XCTAssertEqual(pairs("set timeout to 30 no retries 5"), [])
        XCTAssertEqual(pairs("the file is config.yaml sorry really config.yml"), [])
        XCTAssertEqual(pairs("port 3 no, 4"), ["3->4"])
        XCTAssertEqual(pairs("port 3 wait, 4"), ["3->4"])
        // "actually" is not in the immediate-only set, so it keeps the ordinary window.
        XCTAssertEqual(pairs("version 1.2 actually make it 1.3"), ["1.2->1.3"])
    }

    func testLongestCueIsUsedOnce() {
        XCTAssertEqual(pairs("3 no wait 4"), ["3->4"])
    }

    func testSoftSeparatorsInsideACue() {
        XCTAssertEqual(pairs("set 3 no, wait, 4"), ["3->4"])
    }
}
