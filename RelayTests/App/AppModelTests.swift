import XCTest
@testable import Relay

@MainActor
final class AppModelTests: XCTestCase {
    func testReadSelectionPressedPreprocessesAndSpeaksUserRequest() async {
        let selection = FakeSelectionReader(text: "Intro\n```swift\nsecret()\n```\nEnd")
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        await Task.yield()

        XCTAssertEqual(speech.requests, [
            SpeechRequest(
                text: "Intro There is a code block on screen. Please read it there. End",
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            ),
        ])
        XCTAssertEqual(model.statusText, "Speaking selected text")
    }

    func testReadSelectionReleasedDoesNothing() async {
        let selection = FakeSelectionReader(text: "selected")
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .released)
        await Task.yield()

        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertEqual(selection.readCount, 0)
        withExtendedLifetime(model) {}
    }

    func testStopAndReplayOnlyActWhenPressed() async {
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.stopSpeech, .released)
        hotkeys.send(.replayLast, .released)
        hotkeys.send(.stopSpeech, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await Task.yield()

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testDictationPreservesBothPhasesForFutureWiring() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)

        hotkeys.send(.dictate, .pressed)
        XCTAssertEqual(model.dictationPhase, .pressed)

        hotkeys.send(.dictate, .released)
        XCTAssertEqual(model.dictationPhase, .released)
    }

    func testToggleAutoReadPersistsAndReregistersImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(model.settings.autoReadEnabled)
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false])
        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations.last?.autoReadEnabled, false)
    }

    func testChangingASettingPersistsAndReregistersImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(model.settings.hotkeys[.readSelection], replacement)
        XCTAssertEqual(store.saved.last?.hotkeys[.readSelection], replacement)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
    }

    func testDuplicateHotkeyIsRejectedWithoutPersistenceOrReregistration() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.setHotkey(existing, for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testDuplicateHotkeyRejectionSurfacesActionableConflictMessage() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.setHotkey(existing, for: .readSelection)

        let expected = "Read Selection conflicts with Replay Last. Choose a different shortcut."
        XCTAssertEqual(model.statusText, expected)
        XCTAssertEqual(model.hotkeyConflictMessage, expected)
    }

    func testRegistrationFailureSurfacesActionableStatus() {
        let hotkeys = FakeHotkeyManager(
            status: .unavailable("Enable Accessibility permission, then reopen Relay.")
        )

        let model = makeModel(hotkeys: hotkeys)

        XCTAssertEqual(model.statusText, "Enable Accessibility permission, then reopen Relay.")
    }

    func testSaveFailureStillAppliesHotkeyImmediatelyAndSurfacesError() {
        let store = FakeSettingsStore(settings: .defaults, saveError: TestError.saveFailed)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
        XCTAssertTrue(model.statusText.contains("Could not save settings"))
    }

    private func makeModel(
        store: FakeSettingsStore? = nil,
        selection: FakeSelectionReader? = nil,
        speech: FakeSpeechCoordinator? = nil,
        hotkeys: FakeHotkeyManager? = nil
    ) -> AppModel {
        AppModel(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            selectionReader: selection ?? FakeSelectionReader(text: "selected"),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: speech ?? FakeSpeechCoordinator(),
            hotkeyManager: hotkeys ?? FakeHotkeyManager()
        )
    }
}

@MainActor
private final class FakeSettingsStore: SettingsStoring {
    let settings: AppSettings
    let saveError: Error?
    private(set) var saved: [AppSettings] = []

    init(settings: AppSettings, saveError: Error? = nil) {
        self.settings = settings
        self.saveError = saveError
    }

    func load() -> AppSettings { settings }
    func save(_ value: AppSettings) throws {
        if let saveError { throw saveError }
        saved.append(value)
    }
}

private enum TestError: Error {
    case saveFailed
}

@MainActor
private final class FakeSelectionReader: SelectionReading {
    let text: String
    private(set) var readCount = 0

    init(text: String) {
        self.text = text
    }

    func readSelection() throws -> String {
        readCount += 1
        return text
    }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stopCount = 0
    private(set) var replayCount = 0

    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
    func stop() { stopCount += 1 }
    func replayLast() async throws { replayCount += 1 }
}

@MainActor
private final class FakeHotkeyManager: HotkeyManaging {
    private let status: HotkeyRegistrationStatus
    private var handler: ((HotkeyAction, HotkeyPhase) -> Void)?
    private(set) var registrations: [AppSettings] = []

    init(status: HotkeyRegistrationStatus = .registered) {
        self.status = status
    }

    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        registrations.append(settings)
        self.handler = handler
        return status
    }

    func send(_ action: HotkeyAction, _ phase: HotkeyPhase) {
        handler?(action, phase)
    }
}
