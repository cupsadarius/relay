import XCTest

final class CleanupEvalScoringTests: XCTestCase {
    func testReferenceKeyIgnoresOnlyCaseAndWhitespace() {
        XCTAssertEqual(CleanupEvalScoring.referenceKey("Set  the port to 4."), CleanupEvalScoring.referenceKey("set the port to 4."))
        XCTAssertNotEqual(CleanupEvalScoring.referenceKey("Set the port to 4."), CleanupEvalScoring.referenceKey("Set the port to 4"))
    }

    func testContentKeyIgnoresSentencePunctuation() {
        XCTAssertEqual(CleanupEvalScoring.contentKey("Set the port to 4."), CleanupEvalScoring.contentKey("set the port to 4"))
        XCTAssertEqual(
            CleanupEvalScoring.contentKey("Here's the plan: ship it Friday."), CleanupEvalScoring.contentKey("Here's the plan, ship it Friday.")
        )
        XCTAssertEqual(CleanupEvalScoring.contentKey("Open src/main.swift."), CleanupEvalScoring.contentKey("open src/main.swift"))
    }

    func testContentKeyKeepsLiteralPunctuation() {
        XCTAssertNotEqual(CleanupEvalScoring.contentKey("Pin it to 1.5."), CleanupEvalScoring.contentKey("Pin it to 15."))
        XCTAssertNotEqual(CleanupEvalScoring.contentKey("We saw 1,000 errors."), CleanupEvalScoring.contentKey("We saw 1 000 errors."))
        XCTAssertNotEqual(CleanupEvalScoring.contentKey("Run it with --quiet."), CleanupEvalScoring.contentKey("Run it with quiet."))
        XCTAssertNotEqual(CleanupEvalScoring.contentKey("Bump to 2.0."), CleanupEvalScoring.contentKey("Bump to 2.0. No changes needed."))
    }

    func testMatchesAnyGoodOutput() {
        let good = ["Port 4.", "Port four."]
        XCTAssertTrue(CleanupEvalScoring.matches("port 4", good: good, key: CleanupEvalScoring.contentKey))
        XCTAssertFalse(CleanupEvalScoring.matches("port 4", good: good, key: CleanupEvalScoring.referenceKey))
        XCTAssertFalse(CleanupEvalScoring.matches("Port 3.", good: good, key: CleanupEvalScoring.contentKey))
    }
}
