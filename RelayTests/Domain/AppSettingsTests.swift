import XCTest
@testable import Relay

final class AppSettingsTests: XCTestCase {
    func testDefaultsUseInteractiveActivityOverlay() {
        XCTAssertEqual(AppSettings.defaults.activityOverlayStyle, .interactive)
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
        XCTAssertEqual(AppSettings.defaults.ttsBackendOrder, ["apple-tts"])
        XCTAssertNil(AppSettings.defaults.ttsVoiceIdentifier)
        XCTAssertEqual(AppSettings.defaults.ttsRate, 0.5)
        XCTAssertTrue(AppSettings.defaults.autoReadEnabled)
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
