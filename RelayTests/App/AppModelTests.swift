import XCTest
@testable import Relay

@MainActor
final class AppModelTests: XCTestCase {
    func testChangingActivityOverlayStylePersistsImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let model = makeModel(store: store)

        model.setActivityOverlayStyle(.minimal)

        XCTAssertEqual(model.settings.activityOverlayStyle, .minimal)
        XCTAssertEqual(store.saved.last?.activityOverlayStyle, .minimal)
    }

    func testOverlayLifecycleReachesInjectedPresenter() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.states.last?.sessionID, sessionID)
        withExtendedLifetime(model) {}
    }

    func testActiveOverlayStyleChangeUpdatesPresenterImmediately() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()
        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        model.setActivityOverlayStyle(.minimal)

        XCTAssertEqual(presenter.styles.last, .minimal)
        withExtendedLifetime(model) {}
    }

    func testSubsequentOverlayTransitionUsesNewlyPersistedStyle() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        model.setActivityOverlayStyle(.minimal)
        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.styles.last, .minimal)
        withExtendedLifetime(model) {}
    }

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
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsSubmitted)
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
        XCTAssertEqual(model.diagnosticsCounters.dispatched, 0)
        XCTAssertFalse(model.diagnosticsEntries.contains { if case .actionDispatched = $0.event { true } else { false } })
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

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let speech = FakeSpeechCoordinator(replayError: TestError.saveFailed)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)
        hotkeys.send(.replayLast, .pressed)
        await Task.yield()
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsFailed)
    }

    func testHoldToTalkStartsOnPressAndFinishesOnRelease() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        await Task.yield()

        XCTAssertEqual(model.dictationPhase, .released)
        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testToggleDictationAlternatesOnPressAndIgnoresRelease() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        hotkeys.send(.dictate, .pressed)
        await Task.yield()

        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testHoldToTalkQueuesReleaseUntilBlockedStartCompletes() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator(blockStart: true)
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start"] { await Task.yield() }
        hotkeys.send(.dictate, .released)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start"])

        dictation.resumeStart()
        while dictation.events != ["start", "finish"] { await Task.yield() }
        withExtendedLifetime(model) {}
    }

    func testToggleQueuesNewPressUntilBlockedFinishCompletes() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator(blockFinish: true)
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start"] { await Task.yield() }
        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start", "finish"] { await Task.yield() }
        hotkeys.send(.dictate, .pressed)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start", "finish"])

        dictation.resumeFinish()
        while dictation.events != ["start", "finish", "start"] { await Task.yield() }
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

    func testModifierOnlyAndDoubleTapModifierConflictIsRejected() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.setHotkey(.doubleTapModifier(.function), for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testRegistrationFailureSurfacesActionableStatus() {
        let hotkeys = FakeHotkeyManager(
            status: .unavailable("Enable Accessibility permission, then reopen Relay.")
        )

        let model = makeModel(hotkeys: hotkeys)

        XCTAssertEqual(model.statusText, "Enable Accessibility permission, then reopen Relay.")
    }

    func testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot() {
        let hotkeys = FakeHotkeyManager()
        let permissions = FakePermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let model = makeModel(hotkeys: hotkeys, permissions: permissions)

        model.recheckDiagnostics()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(model.permissionSnapshot.inputMonitoringGranted, false)
    }

    func testRecheckRefreshesObservableMicrophonePermissionAfterExternalChange() {
        let microphone = FakeMicrophonePermissionStatus(granted: false)
        let model = makeModel(microphone: microphone)

        XCTAssertFalse(model.microphonePermissionGranted)
        microphone.grantedValue = true
        model.recheckDiagnostics()

        XCTAssertTrue(model.microphonePermissionGranted)
        microphone.grantedValue = false
        model.recheckDiagnostics()
        XCTAssertFalse(model.microphonePermissionGranted)
    }

    func testRequestMicrophonePermissionRefreshesObservableState() async {
        let microphone = FakeMicrophonePermissionStatus(granted: false, requestResult: true)
        let model = makeModel(microphone: microphone)

        await model.requestMicrophonePermission()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(model.microphonePermissionGranted)
        XCTAssertEqual(model.statusText, "Microphone permission granted")
    }

    func testOpenPrivacySettingsDelegatesToInjectedOpener() {
        let opener = FakePrivacySettingsOpener()
        let model = makeModel(opener: opener)

        model.openPrivacySettings(.microphone)
        model.openPrivacySettings(.accessibility)
        model.openPrivacySettings(.inputMonitoring)

        XCTAssertEqual(opener.opened, [.microphone, .accessibility, .inputMonitoring])
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
        hotkeys: FakeHotkeyManager? = nil,
        permissions: FakePermissionService? = nil,
        dictation: FakeDictationCoordinator? = nil,
        microphone: FakeMicrophonePermissionStatus? = nil,
        opener: FakePrivacySettingsOpener? = nil,
        overlayModel: ActivityOverlayModel? = nil,
        overlayPresenter: (any ActivityOverlayPresenting)? = nil
    ) -> AppModel {
        AppModel(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            selectionReader: selection ?? FakeSelectionReader(text: "selected"),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: speech ?? FakeSpeechCoordinator(),
            hotkeyManager: hotkeys ?? FakeHotkeyManager(),
            permissionService: permissions ?? FakePermissionService(snapshot: .init(inputMonitoringGranted: true, accessibilityGranted: true)),
            diagnostics: DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: dictation,
            microphonePermissions: microphone ?? FakeMicrophonePermissionStatus(granted: true),
            privacySettingsOpener: opener ?? FakePrivacySettingsOpener(),
            overlayModel: overlayModel ?? ActivityOverlayModel(),
            overlayPresenter: overlayPresenter ?? NoOpActivityOverlayPresenter()
        )
    }
}

@MainActor
private final class FakeOverlayPresenter: ActivityOverlayPresenting {
    private(set) var states: [ActivityOverlayState] = []
    private(set) var styles: [ActivityOverlayStyle] = []

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        states.append(state)
        styles.append(style)
    }
}

@MainActor
private final class FakeDictationCoordinator: DictationCoordinating {
    private(set) var events: [String] = []
    private let blockStart: Bool
    private let blockFinish: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(blockStart: Bool = false, blockFinish: Bool = false) {
        self.blockStart = blockStart
        self.blockFinish = blockFinish
    }

    func start() async {
        events.append("start")
        if blockStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func finish() async {
        events.append("finish")
        if blockFinish { await withCheckedContinuation { finishContinuation = $0 } }
    }
    func toggle() async {
        if events.last == "start" { await finish() }
        else { await start() }
    }
    func cancel(sessionID: UUID) async {}
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func resumeFinish() { finishContinuation?.resume(); finishContinuation = nil }
}

@MainActor
private final class FakePermissionService: GlobalPermissionAuthorizing {
    let value: PermissionSnapshot
    private(set) var snapshotCount = 0
    init(snapshot: PermissionSnapshot) { value = snapshot }
    func snapshot() -> PermissionSnapshot { snapshotCount += 1; return value }
    func requestPermissions() {}
}

@MainActor
private final class FakeMicrophonePermissionStatus: MicrophonePermissionStatusProviding {
    var grantedValue: Bool
    let requestResult: Bool
    private(set) var requestCount = 0
    init(granted: Bool, requestResult: Bool? = nil) {
        grantedValue = granted
        self.requestResult = requestResult ?? granted
    }
    func isGranted() -> Bool { grantedValue }
    func requestPermission() async -> Bool {
        requestCount += 1
        grantedValue = requestResult
        return requestResult
    }
}

@MainActor
private final class FakePrivacySettingsOpener: PrivacySettingsOpening {
    private(set) var opened: [PrivacySettingsPane] = []
    func open(_ pane: PrivacySettingsPane) { opened.append(pane) }
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

    func readSelection() throws -> SelectionResult {
        readCount += 1
        return .init(text: text, source: .accessibility)
    }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stopCount = 0
    private(set) var stoppedSessionIDs: [UUID] = []
    private(set) var replayCount = 0
    let replayError: Error?
    init(replayError: Error? = nil) { self.replayError = replayError }

    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
    func stop() { stopCount += 1 }
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws { replayCount += 1; if let replayError { throw replayError } }
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
