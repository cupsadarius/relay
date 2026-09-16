import XCTest
@testable import Relay

/// Task 6 (Reliability Wave 3): `SettingsStore.load()` used to swallow ANY decode failure
/// (`try?`) and silently return `.defaults`, discarding the saved blob entirely with no trace it
/// ever happened. These tests cover the "total failure" path that per-field resilience in
/// `AppSettings.init(from:)` can't reach on its own — bytes that aren't even a JSON object — and
/// confirm that path preserves the raw blob for later recovery and records a diagnostic that
/// never contains the blob's contents.
@MainActor
final class SettingsStoreTests: XCTestCase {
    func testFullyCorruptJSONPreservesBlobAndRecordsDiagnostic() throws {
        let defaults = makeUserDefaults()
        let corruptBytes = Data("{not valid json at all]".utf8)
        defaults.set(corruptBytes, forKey: "relay.settings.v1")
        let diagnostics = DiagnosticsRecorder()

        let loaded = SettingsStore(defaults: defaults, diagnostics: diagnostics).load()

        XCTAssertEqual(loaded, .defaults)

        let preserved = try XCTUnwrap(defaults.data(forKey: SettingsStore.corruptBlobKey))
        XCTAssertEqual(preserved, corruptBytes)

        let recorded = try XCTUnwrap(diagnostics.entries.last)
        guard case let .settingsDecodeFailed(byteCount) = recorded.event else {
            XCTFail("expected a settingsDecodeFailed diagnostic, got \(recorded.event)")
            return
        }
        XCTAssertEqual(byteCount, corruptBytes.count)

        // Privacy: neither the recorded event's rendered message nor the diagnostics copy text
        // may contain the corrupt blob's actual contents — a byte count is fine, the bytes are
        // not.
        let corruptString = String(decoding: corruptBytes, as: UTF8.self)
        XCTAssertFalse(recorded.event.message.contains(corruptString))
        XCTAssertFalse(diagnostics.copyText.contains(corruptString))
    }

    /// Valid JSON that isn't a keyed object at all (e.g. a bare array) must be treated as total
    /// corruption too, not silently misread as some near-empty settings value.
    func testTopLevelNonObjectJSONIsTreatedAsFullCorruption() throws {
        let defaults = makeUserDefaults()
        let arrayBytes = Data("[1,2,3]".utf8)
        defaults.set(arrayBytes, forKey: "relay.settings.v1")

        let loaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(loaded, .defaults)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.corruptBlobKey), arrayBytes)
    }

    /// The recovery key holds only the single latest corrupt blob (overwritten, not accumulated)
    /// — a second corruption in the same run replaces the first rather than growing without
    /// bound.
    func testRecoveryKeyHoldsOnlyTheLatestCorruptBlob() throws {
        let defaults = makeUserDefaults()
        defaults.set(Data("first corrupt blob".utf8), forKey: "relay.settings.v1")
        _ = SettingsStore(defaults: defaults).load()

        let secondCorruptBytes = Data("second corrupt blob".utf8)
        defaults.set(secondCorruptBytes, forKey: "relay.settings.v1")
        _ = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(defaults.data(forKey: SettingsStore.corruptBlobKey), secondCorruptBytes)
    }

    /// A valid, current-format saved blob must still load fully intact — the resilience path
    /// must never kick in (and never touch the recovery key) for good data.
    func testValidSavedSettingsLoadWithoutTouchingRecoveryKey() throws {
        let defaults = makeUserDefaults()
        let store = SettingsStore(defaults: defaults)
        var value = AppSettings.defaults
        value.dictationMode = .toggle
        try store.save(value)

        XCTAssertEqual(store.load(), value)
        XCTAssertNil(defaults.data(forKey: SettingsStore.corruptBlobKey))
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
