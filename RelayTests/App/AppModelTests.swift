import XCTest
@testable import Relay

@MainActor
final class AppModelTests: XCTestCase {
    func testChangingActivityOverlayStylePersistsImmediately() {
        let store = SpySettingsStore(settings: .defaults)
        let model = makeModel(store: store)

        model.setActivityOverlayStyle(.minimal)

        XCTAssertEqual(model.settings.activityOverlayStyle, .minimal)
        XCTAssertEqual(store.saved.last?.activityOverlayStyle, .minimal)
    }

    func testOverlayLifecycleReachesInjectedPresenter() {
        let presenter = SpyOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.states.last?.sessionID, sessionID)
        withExtendedLifetime(model) {}
    }

    func testActiveOverlayStyleChangeUpdatesPresenterImmediately() {
        let presenter = SpyOverlayPresenter()
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
        let presenter = SpyOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        model.setActivityOverlayStyle(.minimal)
        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.styles.last, .minimal)
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextReflectsListeningOverlayState() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(model.activityStatusText, "Listening…")
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextReflectsProcessingOverlayState() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)
        overlayModel.process(sessionID: sessionID)

        XCTAssertEqual(model.activityStatusText, "Transcribing…")
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextReflectsPreparingSpeechOverlayState() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.prepareSpeaking(sessionID: sessionID)

        XCTAssertEqual(model.activityStatusText, "Processing…")
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextReflectsSpeakingOverlayState() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.speak(sessionID: sessionID)

        XCTAssertEqual(model.activityStatusText, "Speaking…")
        withExtendedLifetime(model) {}
    }

    /// Regression for the stale menu-bar label bug: the pill's Stop button routes through
    /// `ActivityOverlayActions.perform` to `SpeechCoordinator.stop(sessionID:)`, and the real
    /// (non-fake) coordinator hides the overlay itself by calling `overlay.cancel(sessionID:)` —
    /// it never touches `AppModel.statusText`. `SpySpeechCoordinator.stop(sessionID:)` only
    /// records the call, so this drives the same overlay transition directly to exercise what
    /// happens once the overlay actually hides. Before the fix, the speak methods left a
    /// "Speaking…"-style string sitting in `statusText`, which `activityStatusText` fell back to
    /// once `.hidden`; with those success-path assignments removed, the fallback must be the
    /// clean idle status instead.
    func testActivityStatusTextReturnsToIdleAfterOverlayHidesFollowingPillStop() {
        let overlayModel = ActivityOverlayModel()
        let speech = SpySpeechCoordinator()
        let model = makeModel(speech: speech, overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.speak(sessionID: sessionID)
        XCTAssertEqual(model.activityStatusText, "Speaking…")

        speech.stop(sessionID: sessionID)
        overlayModel.cancel(sessionID: sessionID)

        XCTAssertTrue(overlayModel.state.isHidden)
        XCTAssertEqual(speech.stoppedSessionIDs, [sessionID])
        XCTAssertNotEqual(model.activityStatusText, "Speaking…")
        XCTAssertEqual(model.activityStatusText, "Ready")
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextReflectsErrorOverlayStateMessage() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.fail(sessionID: sessionID, category: .speechPlayback, message: "Could not play audio.")

        XCTAssertEqual(model.activityStatusText, "Could not play audio.")
        withExtendedLifetime(model) {}
    }

    func testActivityStatusTextFallsBackToStatusTextWhenOverlayIsHidden() {
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel)

        model.runtime.status.post("Sentinel status")

        XCTAssertEqual(model.activityStatusText, "Sentinel status")
        withExtendedLifetime(model) {}
    }

    func testReadSelectionPressedPreprocessesAndSpeaksUserRequest() async {
        let selection = SpySelectionReader(text: "Intro\n```swift\nsecret()\n```\nEnd")
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
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
        // The success path no longer sets a "Speaking…" `statusText`: the overlay's live state
        // drives `activityStatusText` while speech is in flight, and a stale imperative string
        // here is exactly what would survive after the overlay hides once speech ends (e.g. via
        // the pill's Stop button). With no overlay transition driven by this fake, `statusText`
        // should remain at its clean default.
        XCTAssertEqual(model.statusText, "Ready")
        XCTAssertEqual(model.activityStatusText, "Ready")
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsSubmitted)
    }

    func testSelectVoicePersistsThroughProviderNeutralCatalogMapping() {
        let model = makeModel()

        model.speechBackends.selectVoice(backendID: "kokoro", voiceID: "kokoro:am_adam")

        XCTAssertEqual(model.settings.voiceByBackend["kokoro"], "am_adam")
    }

    func testChangingASettingPersistsAndReregistersImmediately() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.settingsController.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(model.settings.hotkeys[.readSelection], replacement)
        XCTAssertEqual(store.saved.last?.hotkeys[.readSelection], replacement)
        XCTAssertEqual(hotkeys.updates.last?[.readSelection], replacement)
    }

    func testDuplicateHotkeyIsRejectedWithoutPersistenceOrReregistration() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.settingsController.setHotkey(existing, for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.updates.count, 1)
    }

    func testRemoveHotkeyClearsTheBindingAndPersists() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.settingsController.removeHotkey(for: .readSelection)

        XCTAssertNil(model.settings.hotkeys[.readSelection])
        XCTAssertNil(store.saved.last?.hotkeys[.readSelection])
        XCTAssertNil(hotkeys.updates.last?[.readSelection])
    }

    func testModifierOnlyAndDoubleTapModifierConflictIsRejected() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.settingsController.setHotkey(.doubleTapModifier(.function), for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.updates.count, 1)
    }

    func testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot() {
        let hotkeys = SpyHotkeyManager()
        let permissions = SpyPermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let model = makeModel(hotkeys: hotkeys, permissions: permissions)

        model.recheckDiagnostics()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(hotkeys.ensureTapCount, 2, "recheck retries the tap")
        XCTAssertEqual(hotkeys.updates.count, 1, "recheck must not rebuild the matcher")
        XCTAssertEqual(model.permissions.snapshot.inputMonitoringGranted, false)
    }

    func testSaveFailureStillAppliesHotkeyImmediatelyAndSurfacesError() {
        let store = SpySettingsStore(settings: .defaults, saveError: TestError.saveFailed)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.settingsController.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(hotkeys.updates.count, 2)
        XCTAssertEqual(hotkeys.updates.last?[.readSelection], replacement)
        XCTAssertTrue(model.statusText.contains("Could not save settings"))
    }

    func testReadSelectionRoutesThroughKokoroWithConfiguredVoiceWhenAvailable() async {
        let (model, hotkeys, pocket, kokoro, apple) = makeTTSRoutingModel(
            pocketAvailability: .modelNotDownloaded,
            kokoroAvailability: .available
        )

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !kokoro.spoken.isEmpty || !apple.spoken.isEmpty }

        XCTAssertEqual(kokoro.spoken.map(\.options.kokoroVoice), ["af_bella"])
        XCTAssertTrue(apple.spoken.isEmpty)
        XCTAssertTrue(pocket.spoken.isEmpty)
        withExtendedLifetime(model) {}
    }

    func testReadSelectionFallsBackToAppleWithTheSameOptionsWhenKokoroReportsModelNotDownloaded() async {
        let (model, hotkeys, pocket, kokoro, apple) = makeTTSRoutingModel(
            pocketAvailability: .modelNotDownloaded,
            kokoroAvailability: .modelNotDownloaded
        )

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !kokoro.spoken.isEmpty || !apple.spoken.isEmpty }

        XCTAssertTrue(kokoro.spoken.isEmpty)
        XCTAssertEqual(apple.spoken.map(\.options.kokoroVoice), ["af_bella"])
        XCTAssertTrue(pocket.spoken.isEmpty)
        withExtendedLifetime(model) {}
    }

    func testReadSelectionRoutesThroughPocketTTSWithConfiguredVoiceWhenAvailable() async {
        let (model, hotkeys, pocket, kokoro, apple) = makeTTSRoutingModel(
            pocketAvailability: .available,
            kokoroAvailability: .available
        )

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !pocket.spoken.isEmpty || !kokoro.spoken.isEmpty || !apple.spoken.isEmpty }

        XCTAssertEqual(pocket.spoken.map(\.options.pocketVoice), ["alba"])
        XCTAssertTrue(kokoro.spoken.isEmpty)
        XCTAssertTrue(apple.spoken.isEmpty)
        withExtendedLifetime(model) {}
    }

    func testReadSelectionFallsBackToAppleWithTheSameOptionsWhenPocketTTSReportsModelNotDownloaded() async {
        let (model, hotkeys, pocket, kokoro, apple) = makeTTSRoutingModel(
            pocketAvailability: .modelNotDownloaded,
            kokoroAvailability: .modelNotDownloaded
        )

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !apple.spoken.isEmpty || !kokoro.spoken.isEmpty }

        XCTAssertTrue(pocket.spoken.isEmpty)
        XCTAssertTrue(kokoro.spoken.isEmpty)
        XCTAssertEqual(apple.spoken.map(\.options.pocketVoice), ["alba"])
        withExtendedLifetime(model) {}
    }

    /// Builds a real `AppModel` around a real `TTSRouter`/`SpeechCoordinator` pair (not the
    /// `SpySpeechCoordinator` the other tests in this file use) wired exactly like the
    /// production convenience `init()` wires PocketTTS, Apple, and Kokoro: `backendOrder` and the
    /// `TTSOptions.kokoroVoice`/`pocketVoice` fields all read from the same settings snapshot.
    /// This exercises the one-line options-closure edit the plan calls out as the easiest step to
    /// miss - if `kokoroVoice`/`pocketVoice` stopped reaching `TTSOptions`, the routing tests
    /// above would fail.
    private func makeTTSRoutingModel(
        pocketAvailability: BackendAvailability,
        kokoroAvailability: BackendAvailability
    ) -> (
        model: AppModel, hotkeys: SpyHotkeyManager, pocket: FakeTTSBackend, kokoro: FakeTTSBackend, apple: FakeTTSBackend
    ) {
        let pocket = FakeTTSBackend(id: "pocket-tts")
        pocket.availabilityValue = pocketAvailability
        let kokoro = FakeTTSBackend(id: "kokoro")
        kokoro.availabilityValue = kokoroAvailability
        let apple = FakeTTSBackend(id: "apple-tts")
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["pocket-tts", "kokoro", "apple-tts"]
        settings.voiceByBackend = ["kokoro": "af_bella", "pocket-tts": "alba"]
        let store = SpySettingsStore(settings: settings)
        let overlay = ActivityOverlayModel()
        let player = FakePlayer()
        pocket.player = player
        kokoro.player = player
        apple.player = player
        let router = TTSRouter(
            backends: ["pocket-tts": pocket, "kokoro": kokoro, "apple-tts": apple],
            backendOrder: { settings.ttsBackendOrder },
            player: player
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: { TTSOptions(settings: settings) },
            overlay: overlay
        )
        let hotkeys = SpyHotkeyManager()
        let model = AppModel(runtime: .testing(
            settingsStore: store,
            selectionReader: SpySelectionReader(text: "hello"),
            speechCoordinator: coordinator,
            hotkeyManager: hotkeys,
            overlayModel: overlay,
            ttsRegistry: ["pocket-tts": pocket, "kokoro": kokoro, "apple-tts": apple]
        ))
        return (model, hotkeys, pocket, kokoro, apple)
    }

    /// Polls `condition` until it's true, yielding between checks so other tasks (fakes waiting
    /// on a continuation, progress callbacks hopping to the main actor, etc.) get a chance to
    /// run. Fails the test instead of hanging forever if `condition` never becomes true.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private func makeModel(
        store: SpySettingsStore? = nil,
        selection: SpySelectionReader? = nil,
        speech: SpySpeechCoordinator? = nil,
        hotkeys: SpyHotkeyManager? = nil,
        permissions: SpyPermissionService? = nil,
        dictation: SpyDictationCoordinator? = nil,
        microphone: SpyMicrophonePermission? = nil,
        opener: SpyPrivacyOpener? = nil,
        loginItem: SpyLoginItemController? = nil,
        overlayModel: ActivityOverlayModel? = nil,
        overlayPresenter: (any ActivityOverlayPresenting)? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        diagnostics: DiagnosticsRecorder? = nil,
        sessionRegistry: AgentSessionRegistry? = nil,
        focusResolution: (any SessionFocusResolving)? = nil,
        frontmostApps: (any FrontmostAppMonitoring)? = nil,
        integrationManager: IntegrationManager? = nil,
        processInspector: ProcessInspector? = nil
    ) -> AppModel {
        AppModel(runtime: .testing(
            settingsStore: store ?? SpySettingsStore(),
            selectionReader: selection ?? SpySelectionReader(),
            speechCoordinator: speech ?? SpySpeechCoordinator(),
            hotkeyManager: hotkeys ?? SpyHotkeyManager(),
            permissionService: permissions ?? SpyPermissionService(),
            microphonePermissions: microphone ?? SpyMicrophonePermission(granted: true),
            privacySettingsOpener: opener ?? SpyPrivacyOpener(),
            loginItemService: loginItem ?? SpyLoginItemController(enabled: false),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: dictation,
            overlayModel: overlayModel ?? ActivityOverlayModel(),
            overlayPresenter: overlayPresenter ?? NoOpActivityOverlayPresenter(),
            sttRegistry: sttRegistry,
            speechModelManagers: speechModelManagers,
            integrationManager: integrationManager,
            sessionRegistry: sessionRegistry ?? AgentSessionRegistry(),
            frontmostApps: frontmostApps ?? StubFrontmostAppMonitor(pid: nil),
            focusResolution: focusResolution,
            processInspector: processInspector ?? ProcessInspector(runner: AllPIDsAliveProcessRunner())
        ))
    }
}

private enum TestError: Error {
    case saveFailed
    case loginItemFailed
}

private actor FakeSTTBackend: SpeechToTextBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    private var availabilityResult: BackendAvailability
    private var shouldBlockAvailability = false
    private(set) var availabilityCallCount = 0
    private var availabilityContinuation: CheckedContinuation<Void, Never>?

    init(id: String, displayName: String, availability: BackendAvailability = .available) {
        self.id = id
        self.displayName = displayName
        availabilityResult = availability
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        if shouldBlockAvailability {
            await withCheckedContinuation { availabilityContinuation = $0 }
        }
        return availabilityResult
    }

    func setAvailability(_ value: BackendAvailability) { availabilityResult = value }

    /// Makes `availability()` suspend on a continuation instead of returning immediately, so a
    /// test can deterministically hold a refresh mid-flight and interleave other work before
    /// calling `resumeAvailability()`.
    func setShouldBlockAvailability(_ value: Bool) { shouldBlockAvailability = value }

    func resumeAvailability() {
        availabilityContinuation?.resume()
        availabilityContinuation = nil
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        Transcript(text: "", backendID: id)
    }
}
