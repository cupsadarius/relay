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

    func testDisplayNamesAreCanonical() {
        XCTAssertEqual(BackendID.appleSpeech.displayName, "Apple Speech")
        XCTAssertEqual(BackendID.parakeet.displayName, "Parakeet")
        XCTAssertEqual(BackendID.whisper.displayName, "OpenAI Whisper")
        XCTAssertEqual(BackendID.pocketTTS.displayName, "PocketTTS")
        XCTAssertEqual(BackendID.appleTTS.displayName, "Apple System Voice")
        XCTAssertEqual(BackendID.kokoro.displayName, "Kokoro")
    }

    func testKnownIDSetsDeriveFromBackendID() {
        XCTAssertEqual(AppSettings.knownSTTBackendIDs, ["apple-speech", "parakeet", "whisper"])
        XCTAssertEqual(AppSettings.knownTTSBackendIDs, ["pocket-tts", "apple-tts", "kokoro"])
    }
}
