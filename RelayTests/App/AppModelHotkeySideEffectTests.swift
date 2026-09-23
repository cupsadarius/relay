import CoreFoundation
import CoreGraphics
import XCTest

@testable import Relay

/// Locks in the fix for the "narrow hotkey side effects" reliability item: `AppModel
/// .updateSettings` used to call `registerHotkeys()` unconditionally, which rebuilt
/// `GlobalHotkeyManager`'s `HotkeyMatcher` (discarding any in-flight chord/double-tap gesture
/// state) on every settings write, including ones with nothing to do with hotkeys (voice, rate,
/// backend order, ...). Only a change to the hotkey *definitions* should rebuild the matcher;
/// `GlobalHotkeyManager.register`'s `eventTap != nil` guard now lives in `ensureTap()`, and the
/// matcher is rebuilt by `update(definitions:)` only when definitions change — the event tap
/// itself is untouched by this fix and must never be re-created.
@MainActor
final class AppModelHotkeySideEffectTests: XCTestCase {
    func testChangingVoiceDoesNotRebuildMatcher() {
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        XCTAssertEqual(hotkeys.updates.count, 1, "initial construction pushes definitions once")

        model.settingsController.setVoice("com.apple.voice.some-voice", for: BackendID.appleTTS.rawValue)

        XCTAssertEqual(
            hotkeys.updates.count, 1,
            "a non-hotkey settings change must not rebuild the matcher"
        )
    }

    func testChangingHotkeyDefinitionRebuildsMatcher() {
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        XCTAssertEqual(hotkeys.updates.count, 1)

        model.settingsController.setHotkey(.chord(keyCode: 49, modifiers: [.command]), for: .readSelection)

        XCTAssertEqual(
            hotkeys.updates.count, 2,
            "a hotkey definition change must rebuild the matcher"
        )
        XCTAssertEqual(
            hotkeys.updates.last?[.readSelection],
            .chord(keyCode: 49, modifiers: [.command])
        )
    }

    /// Uses the real `GlobalHotkeyManager` (not the settings-recording spy above) so this
    /// exercises the actual `eventTap != nil` guard (now inside `ensureTap()`) rather than a
    /// mock's idea of it. The injected `tapFactory` stands in for `CGEvent.tapCreate` so the test
    /// doesn't depend on this machine's Accessibility permission to deterministically produce a
    /// non-nil tap.
    func testEventTapNotReRegisteredOnAnyChange() {
        let tapSpy = TapCreationSpy()
        let realHotkeyManager = GlobalHotkeyManager(tapFactory: { mask, userInfo in
            tapSpy.make(mask: mask, userInfo: userInfo)
        })
        let model = makeModel(hotkeys: realHotkeyManager)
        XCTAssertEqual(tapSpy.callCount, 1, "initial registration creates the tap once")

        model.settingsController.setVoice("com.apple.voice.some-voice", for: BackendID.appleTTS.rawValue)
        model.settingsController.setHotkey(.chord(keyCode: 49, modifiers: [.command]), for: .readSelection)
        model.settingsController.setSpeechRate(0.75)

        XCTAssertEqual(
            tapSpy.callCount, 1,
            "the event tap must never be re-created, whether or not the matcher is rebuilt"
        )
    }

    private func makeModel(hotkeys: any HotkeyManaging) -> AppModel {
        AppModel(runtime: .testing(hotkeyManager: hotkeys))
    }
}

/// Stands in for `CGEvent.tapCreate` in `GlobalHotkeyManager`, counting invocations while still
/// returning a real, valid `CFMachPort` (via `CFMachPortCreate`, which needs no special
/// entitlement or permission) so `register()`'s `eventTap != nil` guard behaves exactly as it
/// would with a real, permission-granted tap.
private final class TapCreationSpy: @unchecked Sendable {
    private(set) var callCount = 0

    func make(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        callCount += 1
        return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
    }
}

private final class FakeSettingsStore: SettingsStoring {
    func load() -> AppSettings { .defaults }
    func save(_ value: AppSettings) throws {}
}

@MainActor
private final class FakeSelectionReader: SelectionReading {
    func readSelection() throws -> SelectionResult { .init(text: "selected", source: .accessibility) }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    func speak(_ request: SpeechRequest) async throws {}
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {}
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}
