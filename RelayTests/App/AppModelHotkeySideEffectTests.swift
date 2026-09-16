import CoreFoundation
import CoreGraphics
import XCTest
@testable import Relay

/// Locks in the fix for the "narrow hotkey side effects" reliability item: `AppModel
/// .updateSettings` used to call `registerHotkeys()` unconditionally, which rebuilt
/// `GlobalHotkeyManager`'s `HotkeyMatcher` (discarding any in-flight chord/double-tap gesture
/// state) on every settings write, including ones with nothing to do with hotkeys (voice, rate,
/// backend order, ...). Only a change to the hotkey *definitions* should rebuild the matcher; the
/// event tap registration (already correctly guarded by `eventTap != nil` in
/// `GlobalHotkeyManager.register`) is untouched by this fix and must never re-create the tap.
@MainActor
final class AppModelHotkeySideEffectTests: XCTestCase {
    func testChangingVoiceDoesNotRebuildMatcher() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        XCTAssertEqual(hotkeys.registrations.count, 1, "initial construction registers once")

        model.setVoiceIdentifier("com.apple.voice.some-voice")

        XCTAssertEqual(
            hotkeys.registrations.count, 1,
            "a non-hotkey settings change must not rebuild the matcher"
        )
    }

    func testChangingHotkeyDefinitionRebuildsMatcher() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        XCTAssertEqual(hotkeys.registrations.count, 1)

        model.setHotkey(.chord(keyCode: 49, modifiers: [.command]), for: .readSelection)

        XCTAssertEqual(
            hotkeys.registrations.count, 2,
            "a hotkey definition change must rebuild the matcher"
        )
        XCTAssertEqual(
            hotkeys.registrations.last?.hotkeys[.readSelection],
            .chord(keyCode: 49, modifiers: [.command])
        )
    }

    /// Uses the real `GlobalHotkeyManager` (not the settings-recording fake above) so this
    /// exercises the actual `eventTap != nil` guard rather than a mock's idea of it. The
    /// injected `tapFactory` stands in for `CGEvent.tapCreate` so the test doesn't depend on this
    /// machine's Accessibility permission to deterministically produce a non-nil tap.
    func testEventTapNotReRegisteredOnAnyChange() {
        let tapSpy = TapCreationSpy()
        let realHotkeyManager = GlobalHotkeyManager(tapFactory: { mask, userInfo in
            tapSpy.make(mask: mask, userInfo: userInfo)
        })
        let model = makeModel(hotkeys: realHotkeyManager)
        XCTAssertEqual(tapSpy.callCount, 1, "initial registration creates the tap once")

        model.setVoiceIdentifier("com.apple.voice.some-voice")
        model.setHotkey(.chord(keyCode: 49, modifiers: [.command]), for: .readSelection)
        model.setSpeechRate(0.75)

        XCTAssertEqual(
            tapSpy.callCount, 1,
            "the event tap must never be re-created, whether or not the matcher is rebuilt"
        )
    }

    private func makeModel(hotkeys: any HotkeyManaging) -> AppModel {
        AppModel(
            settingsStore: FakeSettingsStore(),
            selectionReader: FakeSelectionReader(),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: FakeSpeechCoordinator(),
            hotkeyManager: hotkeys
        )
    }
}

@MainActor
private final class FakeHotkeyManager: HotkeyManaging {
    private(set) var registrations: [AppSettings] = []

    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        registrations.append(settings)
        return .registered
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
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}
