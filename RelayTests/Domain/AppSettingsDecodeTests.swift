import XCTest
@testable import Relay

/// Task 6 (Reliability Wave 3): `AppSettings.init(from:)` used to decode six fields
/// (`dictationMode`, `hotkeys`, `sttBackendOrder`, `ttsBackendOrder`, `ttsRate`,
/// `autoReadEnabled`) as REQUIRED — any single missing or malformed field threw, and
/// `SettingsStore.load()` swallowed that throw into a full reset to `.defaults`, silently
/// discarding every other saved field (all keybinds included). These tests pin the fix: every
/// field now falls back to its own default independently, backend-order lists are normalized,
/// and a legacy (pre-schema-version) blob migrates instead of resetting.
final class AppSettingsDecodeTests: XCTestCase {
    func testMissingOneRequiredFieldKeepsOthers() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        saved.sttBackendOrder = ["parakeet", "apple-speech"]
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "ttsRate")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, saved.hotkeys)
        XCTAssertEqual(decoded.sttBackendOrder, saved.sttBackendOrder)
        XCTAssertEqual(decoded.ttsRate, AppSettings.defaults.ttsRate, accuracy: 0.0001)
    }

    func testInvalidOneFieldDoesNotResetUnrelated() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.ttsVoiceIdentifier = "voice.test"
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["autoReadEnabled"] = "not-a-bool"

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.ttsVoiceIdentifier, "voice.test")
        XCTAssertEqual(decoded.autoReadEnabled, AppSettings.defaults.autoReadEnabled)
    }

    func testUnknownBackendIDsAreNormalized() throws {
        var saved = AppSettings.defaults
        saved.sttBackendOrder = ["totally-unknown", "apple-speech", "parakeet", "apple-speech"]
        saved.ttsBackendOrder = ["mystery-tts", "kokoro", "apple-tts"]
        let data = try JSONEncoder().encode(saved)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        // Unknown ids are dropped and duplicates collapsed to their first occurrence, but the
        // relative order of the known ids that remain is preserved exactly.
        XCTAssertEqual(decoded.sttBackendOrder, ["apple-speech", "parakeet"])
        XCTAssertEqual(decoded.ttsBackendOrder, ["kokoro", "apple-tts"])
    }

    /// If normalization would leave an order completely empty (every id unknown), that is
    /// treated as if the field were absent: fall back to the shipped default order rather than
    /// leave a settings value where no backend at all is enabled.
    func testUnknownBackendIDsFallBackToDefaultsWhenOrderBecomesEmpty() throws {
        var saved = AppSettings.defaults
        saved.sttBackendOrder = ["only-unknown-id"]
        let data = try JSONEncoder().encode(saved)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.sttBackendOrder, AppSettings.defaults.sttBackendOrder)
    }

    /// `ttsRate`'s valid range mirrors `TTSSettingsView`'s slider bounds (`0.1...1.0`).
    func testTTSRateIsClampedToValidRange() throws {
        var saved = AppSettings.defaults
        saved.ttsRate = 5.0
        let highData = try JSONEncoder().encode(saved)
        let decodedHigh = try JSONDecoder().decode(AppSettings.self, from: highData)
        XCTAssertEqual(decodedHigh.ttsRate, 1.0, accuracy: 0.0001)

        saved.ttsRate = -3.0
        let lowData = try JSONEncoder().encode(saved)
        let decodedLow = try JSONDecoder().decode(AppSettings.self, from: lowData)
        XCTAssertEqual(decodedLow.ttsRate, 0.1, accuracy: 0.0001)
    }

    /// A genuinely legacy blob: no `schemaVersion` key at all, and missing every field added
    /// after the very first shipped release (mirrors the existing per-field "pre-X settings"
    /// tests in `AppSettingsTests.swift`, but removes all of them at once plus the version key).
    /// It must MIGRATE — keep the fields it has, default the rest, and land on
    /// `AppSettings.currentSchemaVersion` — not reset to `.defaults` wholesale.
    func testOldSchemaVersionMigrates() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.sttBackendOrder = ["apple-speech"]
        saved.ttsBackendOrder = ["apple-tts"]
        saved.ttsRate = 0.75
        saved.autoReadEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for legacyMissingKey in [
            "schemaVersion", "activityOverlayStyle", "kokoroVoice", "pocketVoice", "liveTranscriptionEnabled",
        ] {
            object.removeValue(forKey: legacyMissingKey)
        }

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.sttBackendOrder, ["apple-speech"])
        XCTAssertEqual(decoded.ttsBackendOrder, ["apple-tts"])
        XCTAssertEqual(decoded.ttsRate, 0.75, accuracy: 0.0001)
        XCTAssertFalse(decoded.autoReadEnabled)
        XCTAssertEqual(decoded.activityOverlayStyle, .interactive)
        XCTAssertNil(decoded.kokoroVoice)
        XCTAssertNil(decoded.pocketVoice)
        XCTAssertFalse(decoded.liveTranscriptionEnabled)
        XCTAssertEqual(decoded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    /// A fully-valid, current-format blob must decode to EXACTLY the same values as today: no
    /// silent reordering and no dropping of valid ids just because normalization now runs.
    func testValidCurrentBlobRoundTripsIdentically() throws {
        var value = AppSettings.defaults
        value.dictationMode = .toggle
        value.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option])
        value.sttBackendOrder = ["parakeet", "apple-speech"]
        value.ttsBackendOrder = ["apple-tts", "kokoro", "pocket-tts"]
        value.ttsVoiceIdentifier = "voice.test"
        value.ttsRate = 0.65
        value.autoReadEnabled = false
        value.activityOverlayStyle = .minimal
        value.kokoroVoice = "af_heart"
        value.pocketVoice = "alba"
        value.liveTranscriptionEnabled = true

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded, value)
    }

    /// Optional and newer fields used `try decodeIfPresent`, so a wrong-typed value threw and
    /// `SettingsStore.load()` reset EVERY setting. Each must now fall back on its own.
    func testWrongTypedOptionalFieldsFallBackWithoutResettingOthers() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.ttsRate = 0.8
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["ttsVoiceIdentifier"] = 42
        object["kokoroVoice"] = true
        object["pocketVoice"] = ["not", "a", "string"]
        object["liveTranscriptionEnabled"] = "yes"

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.ttsRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(decoded.ttsVoiceIdentifier, AppSettings.defaults.ttsVoiceIdentifier)
        XCTAssertEqual(decoded.kokoroVoice, AppSettings.defaults.kokoroVoice)
        XCTAssertEqual(decoded.pocketVoice, AppSettings.defaults.pocketVoice)
        XCTAssertEqual(decoded.liveTranscriptionEnabled, AppSettings.defaults.liveTranscriptionEnabled)
    }

    func testUnknownActivityOverlayStyleFallsBackToDefault() throws {
        var saved = AppSettings.defaults
        saved.autoReadEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["activityOverlayStyle"] = "holographic"

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.activityOverlayStyle, AppSettings.defaults.activityOverlayStyle)
        XCTAssertFalse(decoded.autoReadEnabled)
    }

    /// Pins the on-disk format: a `[HotkeyAction: HotkeyDefinition]` encodes as a flat
    /// `[key, value, key, value]` array, and it must keep round-tripping.
    func testHotkeysStillEncodeAsFlatArrayAndRoundTrip() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        saved.hotkeys[.dictate] = .doubleTapModifier(.control)
        let encoded = try JSONEncoder().encode(saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNotNil(object["hotkeys"] as? [Any], "hotkeys must stay a flat array on disk")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded).hotkeys, saved.hotkeys)
    }

    func testUnknownHotkeyActionDropsOnlyThatEntry() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["hotkeys"] as? [Any])
        entries.append("summonDragons")
        entries.append(["chord": ["keyCode": 1, "modifiers": [String]()]])
        object["hotkeys"] = entries

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, saved.hotkeys)
    }

    func testMalformedHotkeyDefinitionDropsOnlyThatEntry() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["hotkeys"] as? [Any])
        let dictateIndex = try XCTUnwrap(entries.firstIndex { ($0 as? String) == "dictate" })
        entries[dictateIndex + 1] = ["bogus": 1]
        object["hotkeys"] = entries

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        var expected = saved.hotkeys
        expected[.dictate] = nil
        XCTAssertEqual(decoded.hotkeys, expected)
    }

    /// A keyed-object hotkeys map (what the dictionary would encode as if `HotkeyAction` ever
    /// becomes `CodingKeyRepresentable`) is read too, with unknown keys dropped.
    func testKeyedObjectHotkeysFormatIsAlsoRead() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["hotkeys"] = [
            "readSelection": ["chord": ["keyCode": 15, "modifiers": ["option"]]],
            "summonDragons": ["chord": ["keyCode": 1, "modifiers": [String]()]],
        ]

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, [.readSelection: .chord(keyCode: 15, modifiers: [.option])])
    }

    /// Every saved entry present but none usable (every action unknown) must fall back to the
    /// shipped default hotkeys, not leave the user with zero hotkeys.
    func testAllUnknownHotkeyActionsFallBackToDefaults() throws {
        let saved = AppSettings.defaults
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["hotkeys"] as? [Any])
        var index = 0
        while index < entries.count {
            entries[index] = "unknownAction\(index)"
            index += 2
        }
        object["hotkeys"] = entries

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, AppSettings.defaults.hotkeys)
    }

    /// An honestly empty `hotkeys` array (no entries at all, as opposed to entries that all fail
    /// to decode) must still decode to an empty map, not fall back to the defaults.
    func testEmptyHotkeysArrayDecodesToEmptyMap() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["hotkeys"] = [String]()

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, [:])
    }
}
