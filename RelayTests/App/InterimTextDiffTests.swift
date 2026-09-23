import XCTest

@testable import Relay

final class InterimTextDiffTests: XCTestCase {
    func testEmptyCurrentTextProducesEmptyResult() {
        let result = InterimTextDiff.diff(previous: "hello", current: "")

        XCTAssertEqual(result, .init(stablePrefix: "", changedTail: ""))
    }

    func testIdenticalTextIsEntirelyStableWithNoChangedTail() {
        let result = InterimTextDiff.diff(previous: "hello there", current: "hello there")

        XCTAssertEqual(result, .init(stablePrefix: "hello there", changedTail: ""))
    }

    func testFirstUpdateFromEmptyPreviousTreatsEverythingAsTheChangedTail() {
        let result = InterimTextDiff.diff(previous: "", current: "hello")

        XCTAssertEqual(result, .init(stablePrefix: "", changedTail: "hello"))
    }

    func testGrowingTheSameWordKeepsItEntirelyInTheTailUntilAWordBoundaryCompletes() {
        let result = InterimTextDiff.diff(previous: "hel", current: "hello")

        XCTAssertEqual(result, .init(stablePrefix: "", changedTail: "hello"))
    }

    func testAppendingANewWordKeepsThePriorCompleteWordsStable() {
        let result = InterimTextDiff.diff(previous: "hello wor", current: "hello world")

        XCTAssertEqual(result, .init(stablePrefix: "hello ", changedTail: "world"))
    }

    func testAppendingAWordWithNoPriorTrailingSpaceTreatsTheWholeTextAsChangedForThisTick() {
        let result = InterimTextDiff.diff(previous: "hello", current: "hello there")

        XCTAssertEqual(result, .init(stablePrefix: "", changedTail: "hello there"))
    }

    func testRevisingAnEarlierWordDropsEverythingFromThatWordOnwardIntoTheTail() {
        let result = InterimTextDiff.diff(previous: "hello there friend", current: "hello there world")

        XCTAssertEqual(result, .init(stablePrefix: "hello there ", changedTail: "world"))
    }

    func testCompletelyDifferentTextHasNoStablePrefix() {
        let result = InterimTextDiff.diff(previous: "goodbye", current: "hello")

        XCTAssertEqual(result, .init(stablePrefix: "", changedTail: "hello"))
    }

    func testStablePrefixAndChangedTailAlwaysConcatenateBackToCurrentText() {
        let cases: [(String, String)] = [
            ("", "hello"),
            ("hel", "hello"),
            ("hello wor", "hello world"),
            ("hello there friend", "hello there world"),
            ("hello there", "hello there"),
            ("goodbye", "hello"),
        ]

        for (previous, current) in cases {
            let result = InterimTextDiff.diff(previous: previous, current: current)
            XCTAssertEqual(result.stablePrefix + result.changedTail, current)
        }
    }
}
