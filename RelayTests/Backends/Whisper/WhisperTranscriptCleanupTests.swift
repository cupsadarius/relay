import XCTest

@testable import Relay

final class WhisperTranscriptCleanupTests: XCTestCase {
    func testBlankAudioAloneBecomesEmptyString() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioInsideSentenceLeavesNoDoubleSpace() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testCaseInsensitiveAndSpacedVariants() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[blank_audio]"), "")
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[ Silence ]"), "")
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[SILENCE]"), "")
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[Music]"), "")
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[NOISE]"), "")
        XCTAssertEqual(WhisperTranscriptCleanup.clean("[inaudible]"), "")
    }

    func testMultipleMarkersInOneTranscript() {
        XCTAssertEqual(
            WhisperTranscriptCleanup.clean("[BLANK_AUDIO] turn on the lights [SILENCE]"),
            "turn on the lights"
        )
    }

    func testSpecialTokenIsStripped() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("<|startoftranscript|>hello world<|endoftext|>"), "hello world")
    }

    func testSpecialTokenAndMarkerTogether() {
        XCTAssertEqual(
            WhisperTranscriptCleanup.clean("<|en|>[BLANK_AUDIO] hello<|endoftext|>"),
            "hello"
        )
    }

    func testNormalTextIsUnchanged() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("hello world, how are you today?"), "hello world, how are you today?")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("  hello world  "), "hello world")
    }

    func testUnknownBracketedContentIsPreservedAsLegitimateUserContent() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean("please add [item one] to the list"), "please add [item one] to the list")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(WhisperTranscriptCleanup.clean(""), "")
    }
}
