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

    func testWindowIsFourTokens() {
        XCTAssertEqual(pairs("port 3 no we want 4"), ["3->4"])
        XCTAssertEqual(pairs("set 3 then wait for the build and then 4"), [])
    }

    func testLongestCueIsUsedOnce() {
        XCTAssertEqual(pairs("3 no wait 4"), ["3->4"])
    }

    func testSoftSeparatorsInsideACue() {
        XCTAssertEqual(pairs("set 3 no, wait, 4"), ["3->4"])
    }
}
