import XCTest
@testable import Relay

final class AppSettingsTests: XCTestCase {
    func testDefaultsUseInteractiveActivityOverlay() {
        XCTAssertEqual(AppSettings.defaults.activityOverlayStyle, .interactive)
    }

    /// Live interim transcription must default OFF everywhere a default can originate: the
    /// `static let defaults` value, the memberwise initializer's default parameter, and the
    /// decode fallback used when loading settings saved before this field existed. It stays off
    /// until interim inference is fully isolated from the final-transcription critical path.
    func testDefaultLiveTranscriptionIsOff() throws {
        XCTAssertFalse(AppSettings.defaults.liveTranscriptionEnabled)

        XCTAssertFalse(
            AppSettings(
                dictationMode: .holdToTalk,
                hotkeys: [:],
                sttBackendOrder: [],
                ttsBackendOrder: [],
                ttsVoiceIdentifier: nil,
                ttsRate: 0.5,
                autoReadEnabled: true,
                activityOverlayStyle: .interactive
            ).liveTranscriptionEnabled
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any]
        )
        object.removeValue(forKey: "liveTranscriptionEnabled")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(decoded.liveTranscriptionEnabled)
    }

    func testDecodingPreOverlaySettingsAddsInteractiveWithoutResettingOtherFields() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.ttsVoiceIdentifier = "voice.test"
        saved.ttsRate = 0.7
        saved.autoReadEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "activityOverlayStyle")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.activityOverlayStyle, .interactive)
        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.ttsVoiceIdentifier, "voice.test")
        XCTAssertEqual(decoded.ttsRate, 0.7, accuracy: 0.0001)
        XCTAssertFalse(decoded.autoReadEnabled)
    }

    func testDefaultsHaveNoKokoroVoiceConfigured() {
        XCTAssertNil(AppSettings.defaults.kokoroVoice)
    }

    func testKokoroVoiceRoundTrips() throws {
        var value = AppSettings.defaults
        value.kokoroVoice = "af_heart"

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).kokoroVoice, "af_heart")
    }

    func testDecodingPreKokoroSettingsDefaultsKokoroVoiceToNilWithoutResettingOtherFields() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "kokoroVoice")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.kokoroVoice)
        XCTAssertEqual(decoded.dictationMode, .toggle)
    }

    func testDefaultsHaveNoPocketVoiceConfigured() {
        XCTAssertNil(AppSettings.defaults.pocketVoice)
    }

    func testPocketVoiceRoundTrips() throws {
        var value = AppSettings.defaults
        value.pocketVoice = "alba"

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).pocketVoice, "alba")
    }

    func testDecodingPrePocketVoiceSettingsDefaultsPocketVoiceToNilWithoutResettingOtherFields() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pocketVoice")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.pocketVoice)
        XCTAssertEqual(decoded.dictationMode, .toggle)
    }

    func testSettingsRoundTrip() throws {
        var value = AppSettings.defaults
        value.dictationMode = .toggle
        value.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option])

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), value)
    }

    func testSettingsRoundTripPreservesDoubleControlHotkey() throws {
        var value = AppSettings.defaults
        value.hotkeys[.dictate] = .doubleTapModifier(.control)

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), value)
    }

    func testDefaultsUsePhaseOneBackendsAndExpectedHotkeys() {
        XCTAssertEqual(AppSettings.defaults.dictationMode, .holdToTalk)
        XCTAssertEqual(AppSettings.defaults.hotkeys, [
            .dictate: .modifierOnly(.function),
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .stopSpeech: .chord(keyCode: 53, modifiers: []),
            .replayLast: .chord(keyCode: 15, modifiers: [.option, .shift]),
            .toggleAutoRead: .chord(keyCode: 0, modifiers: [.option, .shift]),
        ])
        XCTAssertEqual(AppSettings.defaults.sttBackendOrder, ["apple-speech"])
        XCTAssertEqual(AppSettings.defaults.ttsBackendOrder, ["pocket-tts", "apple-tts", "kokoro"])
        XCTAssertNil(AppSettings.defaults.ttsVoiceIdentifier)
        XCTAssertEqual(AppSettings.defaults.ttsRate, 0.5)
        XCTAssertTrue(AppSettings.defaults.autoReadEnabled)
    }

    /// Now that the minimum macOS is 26, Apple Speech is a zero-download baseline and must
    /// remain the sole default STT backend.
    func testDefaultSTTOrderIsAppleSpeech() {
        XCTAssertEqual(AppSettings.defaults.sttBackendOrder, ["apple-speech"])
    }

    /// Apple TTS must stay present in the default order as a reliable fallback, regardless of
    /// its exact position.
    func testDefaultTTSOrderContainsAppleTTSFallback() {
        XCTAssertTrue(AppSettings.defaults.ttsBackendOrder.contains("apple-tts"))
    }

    func testSelectedSpeechModelByBackendDefaultsEmpty() {
        XCTAssertEqual(AppSettings.defaults.selectedSpeechModelByBackend, [:])
    }

    func testSelectedSpeechModelByBackendRoundTrips() throws {
        var value = AppSettings.defaults
        value.selectedSpeechModelByBackend = ["whisper": "small.en", "parakeet": "parakeet-v2"]

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: data).selectedSpeechModelByBackend,
            value.selectedSpeechModelByBackend
        )
    }

    /// A malformed value for the field (here, a non-string value under a known key) must decode
    /// without throwing and fall back to the empty default, matching the resilient per-field
    /// decode pattern the rest of this file follows (e.g. `hotkeys`) rather than resetting every
    /// other field along with it.
    func testSelectedSpeechModelByBackendDecodesResilientlyOnGarbage() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["selectedSpeechModelByBackend"] = ["whisper": 42]

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.selectedSpeechModelByBackend, [:])
        XCTAssertEqual(decoded.dictationMode, .toggle)
    }

    /// `whisper` must be registered in `AppSettings.knownSTTBackendIDs` so it survives
    /// `normalizedBackendOrder`'s known-id filter during decode, even though it is not part of
    /// the default order (Task 11 registers the backend itself in the composition root).
    func testWhisperIdSurvivesBackendOrderDecode() throws {
        var saved = AppSettings.defaults
        saved.sttBackendOrder = ["apple-speech", "whisper"]
        let encoded = try JSONEncoder().encode(saved)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.sttBackendOrder, ["apple-speech", "whisper"])
    }

    @MainActor
    func testSettingsStoreReturnsDefaultsWhenNoSettingsAreSaved() {
        let defaults = makeUserDefaults()

        XCTAssertEqual(SettingsStore(defaults: defaults).load(), .defaults)
    }

    @MainActor
    func testSettingsStoreReturnsDefaultsWhenSavedSettingsAreInvalid() {
        let defaults = makeUserDefaults()
        defaults.set(Data("not json".utf8), forKey: "relay.settings.v1")

        XCTAssertEqual(SettingsStore(defaults: defaults).load(), .defaults)
    }

    @MainActor
    func testSettingsStorePersistsSavedSettings() throws {
        let defaults = makeUserDefaults()
        let store = SettingsStore(defaults: defaults)
        var value = AppSettings.defaults
        value.dictationMode = .toggle
        value.autoReadEnabled = false

        try store.save(value)

        XCTAssertEqual(store.load(), value)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
