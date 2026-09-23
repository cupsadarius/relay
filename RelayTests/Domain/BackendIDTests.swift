import XCTest

@testable import Relay

final class BackendIDTests: XCTestCase {
    /// These strings are persisted in `AppSettings` (backend orders, voice/model maps) and must
    /// never change.
    func testRawValuesMatchPersistedStrings() {
        XCTAssertEqual(BackendID.appleSpeech.rawValue, "apple-speech")
        XCTAssertEqual(BackendID.parakeet.rawValue, "parakeet")
        XCTAssertEqual(BackendID.whisper.rawValue, "whisper")
        XCTAssertEqual(BackendID.pocketTTS.rawValue, "pocket-tts")
        XCTAssertEqual(BackendID.appleTTS.rawValue, "apple-tts")
        XCTAssertEqual(BackendID.kokoro.rawValue, "kokoro")
    }

    func testDisplayNamesAreCanonicalAndUnknownIDsFallBackToRawValue() {
        XCTAssertEqual(BackendID.appleSpeech.displayName, "Apple Speech")
        XCTAssertEqual(BackendID.parakeet.displayName, "Parakeet")
        XCTAssertEqual(BackendID.whisper.displayName, "OpenAI Whisper")
        XCTAssertEqual(BackendID.pocketTTS.displayName, "PocketTTS")
        XCTAssertEqual(BackendID.appleTTS.displayName, "Apple System Voice")
        XCTAssertEqual(BackendID.kokoro.displayName, "Kokoro")
        XCTAssertEqual(BackendID.displayName(for: "future-backend"), "future-backend")
    }

    func testPatternMatchesPlainStrings() {
        let id = "kokoro"
        switch id {
        case BackendID.kokoro: break
        default: XCTFail("BackendID must pattern-match its raw string")
        }
    }

    func testKnownIDSetsDeriveFromBackendID() {
        XCTAssertEqual(AppSettings.knownSTTBackendIDs, ["apple-speech", "parakeet", "whisper"])
        XCTAssertEqual(AppSettings.knownTTSBackendIDs, ["pocket-tts", "apple-tts", "kokoro"])
    }
}
