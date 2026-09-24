import XCTest

@testable import Relay

final class ProtectedLiteralExtractorTests: XCTestCase {
    private func literals(_ text: String) -> [String] {
        ProtectedLiteralExtractor.extract(from: text).map { "\($0.kind):\($0.value)" }
    }

    func testCodeSpans() {
        XCTAssertEqual(literals("run `make test` now"), ["code:`make test`"])
    }

    func testQuotesButNeverApostrophes() {
        XCTAssertEqual(literals("set the title to \"Weekly Sync\" and “Q3 Plan”"), ["quoted:\"Weekly Sync\"", "quoted:“Q3 Plan”"])
        XCTAssertEqual(literals("don't touch Bob's 'config'"), ["quoted:'config'"])
        XCTAssertEqual(literals("it's Bob's and we're done"), [])
    }

    func testUnbalancedQuoteProducesNoQuotedLiteral() {
        XCTAssertEqual(literals("say \"hello world"), [])
    }

    func testURLsAreEdgeTrimmed() {
        XCTAssertEqual(literals("see https://example.com/docs. or www.apple.com, ok"), ["url:https://example.com/docs", "url:www.apple.com"])
    }

    func testPaths() {
        XCTAssertEqual(
            literals("open ~/Library/Logs and ./build and /usr/bin and src/app.swift"),
            ["path:~/Library/Logs", "path:./build", "path:/usr/bin", "path:src/app.swift"]
        )
        XCTAssertEqual(literals("and/or TCP/IP"), [])
    }

    func testFlags() {
        XCTAssertEqual(literals("use --dry-run=true and -v"), ["flag:--dry-run=true", "flag:-v"])
        XCTAssertEqual(literals("a state-of-the-art build"), [])
    }

    func testVersions() {
        XCTAssertEqual(literals("bump to v1.2.3-beta, not 2.0."), ["version:v1.2.3-beta", "version:2.0"])
    }

    func testHexNeedsADigitAndALetter() {
        XCTAssertEqual(literals("commit 3b1b176 and 0xFF but not deadbeef"), ["hex:3b1b176", "hex:0xFF"])
    }

    func testNumbers() {
        XCTAssertEqual(literals("set 3 workers at 50% and 1,000 rows"), ["number:3", "number:50%", "number:1,000"])
    }

    /// Review fix 1: sign, currency and magnitude are part of the literal, so "-5" and "5" (and
    /// "5 million" and "5 billion") are different literals.
    func testSignCurrencyAndMagnitudeAreProtected() {
        XCTAssertEqual(literals("set it to -5 now"), ["number:-5"])
        XCTAssertEqual(literals("set it to 5 now"), ["number:5"])
        XCTAssertEqual(literals("raise it to 5 million"), ["number:5 million"])
        XCTAssertEqual(literals("pay $5 or £10"), ["number:$5", "number:£10"])
    }

    func testIdentifiers() {
        XCTAssertEqual(
            literals("userService calls AuthService.refresh via user_id and h264"),
            ["identifier:userService", "identifier:AuthService.refresh", "identifier:user_id", "identifier:h264"]
        )
        XCTAssertEqual(literals("Change the API"), [])
    }

    func testEdgeTrimmingStripsParenthesesAndSentencePunctuation() {
        XCTAssertEqual(literals("(see src/main.swift)."), ["path:src/main.swift"])
    }

    func testEarlierKindClaimsItsCharactersFirst() {
        XCTAssertEqual(literals("clone https://github.com/a_b/c.swift now"), ["url:https://github.com/a_b/c.swift"])
    }

    func testRangesPointAtTheValues() {
        let text = "open (src/app.swift) with --verbose, then 3."
        for literal in ProtectedLiteralExtractor.extract(from: text) {
            XCTAssertEqual(String(text[literal.range]), literal.value)
        }
    }

    func testKindClasses() {
        XCTAssertEqual(ProtectedLiteralKind.number.kindClass, .numeric)
        XCTAssertEqual(ProtectedLiteralKind.version.kindClass, .numeric)
        XCTAssertEqual(ProtectedLiteralKind.spokenNumber.kindClass, .numeric)
        XCTAssertEqual(ProtectedLiteralKind.flag.kindClass, .flag)
        XCTAssertEqual(ProtectedLiteralKind.path.kindClass, .path)
        XCTAssertEqual(ProtectedLiteralKind.url.kindClass, .url)
        for kind in [ProtectedLiteralKind.code, .quoted, .identifier, .hex] {
            XCTAssertEqual(kind.kindClass, .symbol)
        }
    }
}
