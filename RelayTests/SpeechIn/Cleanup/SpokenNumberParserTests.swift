import XCTest

@testable import Relay

final class SpokenNumberParserTests: XCTestCase {
    private func digits(_ text: String) -> [String] {
        SpokenNumberParser.parse(text).map(\.canonicalDigits)
    }

    func testUnitsTeensAndTens() {
        XCTAssertEqual(digits("zero"), ["0"])
        XCTAssertEqual(digits("three"), ["3"])
        XCTAssertEqual(digits("nineteen"), ["19"])
        XCTAssertEqual(digits("ninety"), ["90"])
    }

    func testCompounds() {
        XCTAssertEqual(digits("twenty-five"), ["25"])
        XCTAssertEqual(digits("twenty five"), ["25"])
    }

    func testHundredsAndThousands() {
        XCTAssertEqual(digits("one hundred and five"), ["105"])
        XCTAssertEqual(digits("two thousand twenty"), ["2020"])
        XCTAssertEqual(digits("nine hundred ninety nine thousand nine hundred ninety nine"), ["999999"])
    }

    func testDecimals() {
        XCTAssertEqual(digits("two point five"), ["2.5"])
        XCTAssertEqual(digits("three point one four"), ["3.14"])
        XCTAssertEqual(digits("zero point five"), ["0.5"])
    }

    func testRunBoundaries() {
        XCTAssertEqual(digits("three four"), ["3", "4"])
        XCTAssertEqual(digits("three, four"), ["3", "4"])
        XCTAssertEqual(digits("port three no four"), ["3", "4"])
        XCTAssertEqual(digits("one and two"), ["1", "2"])
        XCTAssertEqual(digits("point five"), ["5"])
    }

    func testOtherHyphenatedWordsAreNotNumbers() {
        XCTAssertEqual(digits("we need to one-up them"), [])
    }

    func testWordsAreLowercasedAndHyphenSplit() {
        XCTAssertEqual(SpokenNumberParser.parse("Twenty-Five").first?.words, ["twenty", "five"])
    }

    func testRangeCoversTheWholeRun() {
        let text = "set it to one hundred and five now"
        let run = try? XCTUnwrap(SpokenNumberParser.parse(text).first)
        XCTAssertEqual(run.map { String(text[$0.range]) }, "one hundred and five")
    }

    func testClaimedRangesAreSkipped() {
        let text = "`one` and two"
        let claimed = ProtectedLiteralExtractor.extract(from: text).map(\.range)
        XCTAssertEqual(SpokenNumberParser.parse(text, excluding: claimed).map(\.canonicalDigits), ["2"])
    }

    func testExtractAllAddsSpokenNumbersInTextOrder() {
        let all = ProtectedLiteralExtractor.extractAll(from: "port three and 4")
        XCTAssertEqual(all.map { "\($0.kind):\($0.value)" }, ["spokenNumber:three", "number:4"])
        XCTAssertEqual(all.first?.canonicalDigits, "3")
    }

    func testWordSequenceAndContiguousMatch() {
        let words = SpokenNumberParser.wordSequence(of: "Port Twenty-five, ok")
        XCTAssertEqual(words, ["port", "twenty", "five", "ok"])
        XCTAssertTrue(SpokenNumberParser.contains(["twenty", "five"], in: words))
        XCTAssertFalse(SpokenNumberParser.contains(["five", "ok", "port"], in: words))
    }
}
