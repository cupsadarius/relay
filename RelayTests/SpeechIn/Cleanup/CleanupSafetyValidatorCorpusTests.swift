import XCTest

@testable import Relay

/// Deterministic use of the eval corpus: no model runs (spec §19). Failure messages carry case
/// ids only.
final class CleanupSafetyValidatorCorpusTests: XCTestCase {
    static let requiredCategories: Set<String> = [
        "filler", "falseStart", "punctuation",
        "correction.no", "correction.noWait", "correction.wait", "correction.iMean", "correction.actually",
        "correction.sorry", "correction.scratchThat", "correction.orRather",
        "correction.kind.number", "correction.kind.spokenNumber", "correction.kind.flag", "correction.kind.path",
        "correction.kind.identifier", "correction.kind.url", "correction.kind.version",
        "correction.chained", "correction.retractionOnly", "cueNegative", "spokenNumber", "digitsStayDigits",
        "identifiers", "cliFlags", "paths", "urls", "versions", "quotedStrings", "numbers", "hex",
        "inventedLiteral", "alreadyClean", "promptInjection", "wrapperOutput", "nonEnglish",
    ]

    private let validator = CleanupSafetyValidator()

    func testEveryAcceptableOutputPasses() throws {
        for testCase in try CleanupEvalCorpus.load() {
            for (index, output) in testCase.acceptable.enumerated() {
                guard case .accept = validator.validate(input: testCase.input, output: output) else {
                    XCTFail("\(testCase.id) acceptable[\(index)] was rejected")
                    continue
                }
            }
        }
    }

    func testEveryMustRejectOutputFailsWithTheStatedReason() throws {
        for testCase in try CleanupEvalCorpus.load() {
            for (index, rejection) in testCase.mustReject.enumerated() {
                XCTAssertEqual(
                    validator.validate(input: testCase.input, output: rejection.output), .reject(rejection.reason),
                    "\(testCase.id) mustReject[\(index)]"
                )
            }
        }
    }

    func testCorpusCoversEveryRequiredCategory() throws {
        let categories = Set(try CleanupEvalCorpus.load().map(\.category))
        XCTAssertEqual(Self.requiredCategories.subtracting(categories), [])
    }

    func testCaseIDsAreUnique() throws {
        let ids = try CleanupEvalCorpus.load().map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
