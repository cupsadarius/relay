import XCTest
@testable import Relay

@MainActor
final class SpeechVoiceCatalogTests: XCTestCase {
    func testNilSettingsProduceExactlyOneActiveVoicePerProvider() {
        let catalog = SpeechVoiceCatalog(
            appleVoices: [
                .init(id: "apple.voice", displayName: "Voice", detail: "en-US", storedValue: "apple.voice")
            ],
            kokoroVoices: ["af_heart", "am_adam"],
            recommendedKokoroVoice: "af_heart",
            pocketVoice: "alba"
        )
        let settings = AppSettings.defaults

        for backendID in ["apple-tts", "kokoro", "pocket-tts"] {
            let activeID = catalog.activeVoiceID(for: backendID, settings: settings)
            XCTAssertNotNil(activeID)
            XCTAssertEqual(catalog.voices(for: backendID).filter { $0.id == activeID }.count, 1)
        }
    }

    func testStoredValueDistinguishesKnownDefaultFromUnknownVoice() {
        let catalog = SpeechVoiceCatalog(
            appleVoices: [],
            kokoroVoices: ["af_heart", "am_adam"],
            recommendedKokoroVoice: "af_heart",
            pocketVoice: "alba"
        )

        let knownDefault = catalog.storedValue(for: "kokoro:default", backendID: "kokoro")
        XCTAssertNotNil(knownDefault)
        XCTAssertNil(knownDefault!)
        XCTAssertNil(catalog.storedValue(for: "missing", backendID: "kokoro"))
        XCTAssertEqual(catalog.storedValue(for: "kokoro:am_adam", backendID: "kokoro")!, "am_adam")
    }

    func testOptionsOverrideOnlyClickedProvidersVoiceAndPreserveRate() {
        let catalog = SpeechVoiceCatalog(
            appleVoices: [],
            kokoroVoices: ["af_heart", "am_adam"],
            recommendedKokoroVoice: "af_heart",
            pocketVoice: "alba"
        )
        var settings = AppSettings.defaults
        settings.ttsVoiceIdentifier = "apple.saved"
        settings.kokoroVoice = "af_heart"
        settings.pocketVoice = "alba"
        settings.ttsRate = 0.75

        let options = catalog.options(for: "kokoro:am_adam", backendID: "kokoro", settings: settings)

        XCTAssertEqual(options?.voiceIdentifier, "apple.saved")
        XCTAssertEqual(options?.kokoroVoice, "am_adam")
        XCTAssertEqual(options?.pocketVoice, "alba")
        XCTAssertEqual(options?.rate, 0.75)
    }
}
