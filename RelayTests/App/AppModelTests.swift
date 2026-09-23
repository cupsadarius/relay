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
    /// `ActivityOverlayActionDispatcher` to `SpeechCoordinator.stop(sessionID:)`, and the real
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

        model.statusText = "Sentinel status"

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

    func testReadSelectionReleasedDoesNothing() async {
        let selection = SpySelectionReader(text: "selected")
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
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
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.stopSpeech, .released)
        hotkeys.send(.replayLast, .released)
        hotkeys.send(.stopSpeech, .pressed)
        hotkeys.send(.replayLast, .pressed)
        // `replayLast()` now hops through `sessionRegistry` (a real actor) before falling back to
        // `speechCoordinator.replayLast()`, so a single `Task.yield()` is no longer guaranteed to
        // let it finish; poll instead.
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let speech = SpySpeechCoordinator(replayError: TestError.saveFailed)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)
        hotkeys.send(.replayLast, .pressed)
        // See `testStopAndReplayOnlyActWhenPressed` for why this polls rather than yielding once.
        await waitUntil { model.diagnosticsEntries.first?.event == .ttsFailed }
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsFailed)
    }

    func testTwoQuickReadSelectionPressesSpeakOnlyOnce() async {
        let selection = SpySelectionReader(text: "selected")
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.requests.count, 1)
        withExtendedLifetime(model) {}
    }

    func testTwoQuickReplayPressesReplayOnlyOnce() async {
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testStopSpeechCancelsAPendingReplay() async {
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.stopSpeech, .pressed)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertEqual(speech.stopCount, 1)
        withExtendedLifetime(model) {}
    }

    func testCancelledReadSelectionIsNotReportedAsFailure() async {
        let speech = SpySpeechCoordinator(speakError: CancellationError())
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(model.diagnosticsEntries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(model.statusText, "Ready")
    }

    // MARK: - Session-aware Replay Last

    func testReplayLastWithFocusedHighConfidenceSessionSpeaksThatSessionsLatestReply() async {
        let registry = AgentSessionRegistry()
        let sessionA = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [],
            tty: nil
        )
        _ = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-b", text: "Reply B"),
            processAncestry: [],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: sessionA.id),
            frontmostApps: StubFrontmostAppMonitor(pid: nil)
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { !speech.requests.isEmpty }

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertEqual(speech.requests.first?.sessionID, "claude-code:session-a")
        XCTAssertEqual(speech.replayCount, 0)
        withExtendedLifetime(model) {}
    }

    /// `replayLast()` must prune dead-process sessions from `sessionRegistry` before its tier-1
    /// focus loop runs, exactly like `AgentAutoReadCoordinator` does before its own focus
    /// decision — otherwise a dead agent's stale session could still be offered to (and spoken
    /// by) the manual replay path. The stub focus resolver would report this session confidently
    /// focused if it survived pruning; injecting a process inspector that reports every pid dead
    /// proves it's gone before that resolver is ever consulted, falling through to tier 3.
    func testReplayLastSkipsDeadProcessSessionBeforeFocusResolution() async {
        let registry = AgentSessionRegistry()
        let deadSession = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "dead-session", text: "Reply from a dead process"),
            processAncestry: [1_234_567],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: deadSession.id),
            frontmostApps: StubFrontmostAppMonitor(pid: nil),
            processInspector: ProcessInspector(runner: AllPIDsDeadProcessRunner())
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.replayCount, 1)
        XCTAssertTrue(speech.requests.isEmpty, "the dead session must not be spoken via tier 1")
        withExtendedLifetime(model) {}
    }

    func testReplayLastWithAmbiguousFocusButFrontmostHostsASessionSpeaksGlobalLatest() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let store = LatestAgentResponseStore()
        let latest = AgentResponseEvent.fixture(providerSessionID: "global-latest", text: "Global reply")
        await store.set(latest)
        // Drive one accepted event through a stub integration so `latestResponse` (the MainActor
        // property `AppModel.replayLast()` reads to decide whether a global latest is available)
        // reflects the same event just seeded into `store`, exactly as the real socket pipeline
        // keeps the two in sync.
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let drivenManager = IntegrationManager(
            events: events,
            integrations: [StubIntegration(provider: .claudeCode, event: latest)],
            store: store,
            speechCoordinator: speech
        )
        drivenManager.start()
        continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: 100,
            environment: [:],
            capturedAt: latest.capturedAt
        ))
        await waitUntil { drivenManager.latestResponse != nil }
        drivenManager.stop()

        let hotkeys = SpyHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: nil),
            frontmostApps: StubFrontmostAppMonitor(pid: 4242),
            integrationManager: drivenManager
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { !speech.requests.isEmpty }

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests.first?.sessionID, "claude-code:global-latest")
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertEqual(speech.replayCount, 0)
        withExtendedLifetime(model) {}
    }

    func testReplayLastFallsBackToLastSpokenWhenFrontmostHostsNoSession() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: nil),
            frontmostApps: StubFrontmostAppMonitor(pid: 9999)
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.replayCount, 1)
        XCTAssertTrue(speech.requests.isEmpty)
        withExtendedLifetime(model) {}
    }

    func testReplayLastFallsBackToLastSpokenWhenNoFrontmostApplication() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: nil),
            frontmostApps: StubFrontmostAppMonitor(pid: nil)
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.replayCount, 1)
        XCTAssertTrue(speech.requests.isEmpty)
        withExtendedLifetime(model) {}
    }

    func testReplayLastFallsBackToLastSpokenWhenGlobalStoreIsEmptyEvenIfFrontmostHostsASession() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(
            response: AgentResponseEvent.fixture(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = SpySpeechCoordinator()
        let hotkeys = SpyHotkeyManager()
        // `integrationManager` left nil: `makeModel`'s underlying `AppModel` init builds a fresh
        // `IntegrationManager` around an empty, never-fed `AsyncStream`, so `latestResponse` stays
        // `nil` — exactly the "empty global store" case.
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: nil),
            frontmostApps: StubFrontmostAppMonitor(pid: 4242)
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.replayCount, 1)
        XCTAssertTrue(speech.requests.isEmpty)
        withExtendedLifetime(model) {}
    }


    func testPreviewVoiceUsesClickedProviderAndCurrentRateWithoutPersistingSelection() async {
        let speech = SpySpeechCoordinator()
        var settings = AppSettings.defaults
        settings.kokoroVoice = "af_heart"
        settings.ttsRate = 0.75
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, speech: speech)

        await model.previewVoice(backendID: "kokoro", voiceID: "kokoro:am_adam")

        XCTAssertEqual(speech.previews.count, 1)
        XCTAssertEqual(speech.previews.first?.backendID, "kokoro")
        XCTAssertEqual(speech.previews.first?.options.kokoroVoice, "am_adam")
        XCTAssertEqual(speech.previews.first?.options.rate, 0.75)
        XCTAssertEqual(model.settings.kokoroVoice, "af_heart")
    }

    func testSelectVoicePersistsThroughProviderNeutralCatalogMapping() {
        let model = makeModel()

        model.selectVoice(backendID: "kokoro", voiceID: "kokoro:am_adam")

        XCTAssertEqual(model.settings.kokoroVoice, "am_adam")
    }

    func testHoldToTalkStartsOnPressAndFinishesOnRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        await Task.yield()

        XCTAssertEqual(model.dictationPhase, .released)
        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testToggleDictationAlternatesOnPressAndIgnoresRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.settingsController.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        hotkeys.send(.dictate, .pressed)
        await Task.yield()

        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testHoldToTalkQueuesReleaseUntilBlockedStartCompletes() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockStart: true)
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
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockFinish: true)
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.settingsController.setDictationMode(.toggle)

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

    /// `autoReadEnabled` is not a hotkey definition, so toggling it must persist immediately
    /// without rebuilding the hotkey matcher (see `AppModelHotkeySideEffectTests` for the
    /// general rule this is one instance of).
    func testToggleAutoReadPersistsWithoutReregisteringHotkeys() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(model.settings.autoReadEnabled)
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false])
        XCTAssertEqual(hotkeys.registrations.count, 1, "toggling auto-read must not rebuild the hotkey matcher")
    }

    func testChangingASettingPersistsAndReregistersImmediately() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.settingsController.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(model.settings.hotkeys[.readSelection], replacement)
        XCTAssertEqual(store.saved.last?.hotkeys[.readSelection], replacement)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
    }

    func testDuplicateHotkeyIsRejectedWithoutPersistenceOrReregistration() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.settingsController.setHotkey(existing, for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testRemoveHotkeyClearsTheBindingAndPersists() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.settingsController.removeHotkey(for: .readSelection)

        XCTAssertNil(model.settings.hotkeys[.readSelection])
        XCTAssertNil(store.saved.last?.hotkeys[.readSelection])
        XCTAssertNil(hotkeys.registrations.last?.hotkeys[.readSelection])
    }

    func testModifierOnlyAndDoubleTapModifierConflictIsRejected() {
        let store = SpySettingsStore(settings: .defaults)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.settingsController.setHotkey(.doubleTapModifier(.function), for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testRegistrationFailureSurfacesActionableStatus() {
        let hotkeys = SpyHotkeyManager(
            status: .unavailable("Enable Accessibility permission, then reopen Relay.")
        )

        let model = makeModel(hotkeys: hotkeys)

        XCTAssertEqual(model.statusText, "Enable Accessibility permission, then reopen Relay.")
    }

    func testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot() {
        let hotkeys = SpyHotkeyManager()
        let permissions = SpyPermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let model = makeModel(hotkeys: hotkeys, permissions: permissions)

        model.recheckDiagnostics()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(model.permissionSnapshot.inputMonitoringGranted, false)
    }

    func testRecheckRefreshesObservableMicrophonePermissionAfterExternalChange() {
        let microphone = SpyMicrophonePermission(granted: false)
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
        let microphone = SpyMicrophonePermission(granted: false, requestResult: true)
        let model = makeModel(microphone: microphone)

        await model.requestMicrophonePermission()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(model.microphonePermissionGranted)
        XCTAssertEqual(model.statusText, "Microphone permission granted")
    }

    func testOpenPrivacySettingsDelegatesToInjectedOpener() {
        let opener = SpyPrivacyOpener()
        let model = makeModel(opener: opener)

        model.openPrivacySettings(.microphone)
        model.openPrivacySettings(.accessibility)

        XCTAssertEqual(opener.opened, [.microphone, .accessibility])
    }

    /// "Open Microphone Settings" (Security tab) must call the injectable opener seam exactly
    /// once per click — never a real `NSWorkspace` in tests.
    func testOpenMicrophoneSettingsDelegatesToInjectedOpenerExactlyOnce() {
        let opener = SpyPrivacyOpener()
        let model = makeModel(opener: opener)

        model.openMicrophoneSettings()

        XCTAssertEqual(opener.opened, [.microphone])
    }

    func testLastMicrophoneCaptureDiagnosticsIsNilBeforeAnyCapture() {
        let model = makeModel()

        XCTAssertNil(model.lastMicrophoneCaptureDiagnostics)
    }

    /// `AppModel.lastMicrophoneCaptureDiagnostics` is a passthrough onto
    /// `DiagnosticsRecorder.lastMicrophoneCaptureDiagnostics`; verifies the wiring end to end
    /// (the actual population from a real capture is covered at the `MicrophoneCapture` level in
    /// `MicrophoneCaptureStateTests`, and the zero-frame path there is the one this tab most needs
    /// to make visible).
    func testLastMicrophoneCaptureDiagnosticsReflectsRecorderState() {
        let diagnosticsRecorder = DiagnosticsRecorder(capacity: 10)
        let model = makeModel(diagnostics: diagnosticsRecorder)
        let record = MicrophoneCaptureDiagnostics(inputSampleRate: 48_000, frameCount: 0, capturedAt: Date(timeIntervalSince1970: 1))

        diagnosticsRecorder.recordMicrophoneCapture(record)

        XCTAssertEqual(model.lastMicrophoneCaptureDiagnostics, record)
    }

    func testLaunchAtLoginEnabledReflectsServiceInitialStatusWhenEnabled() {
        let loginItem = SpyLoginItemController(enabled: true)
        let model = makeModel(loginItem: loginItem)

        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testLaunchAtLoginEnabledReflectsServiceInitialStatusWhenDisabled() {
        let loginItem = SpyLoginItemController(enabled: false)
        let model = makeModel(loginItem: loginItem)

        XCTAssertFalse(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginOnRegistersAndUpdatesFlag() {
        let loginItem = SpyLoginItemController(enabled: false)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginOffUnregistersAndUpdatesFlag() {
        let loginItem = SpyLoginItemController(enabled: true)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(false)

        XCTAssertEqual(loginItem.setEnabledCalls, [false])
        XCTAssertFalse(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginFailureLeavesFlagMatchingActualStatusAndSurfacesMessage() {
        let loginItem = SpyLoginItemController(enabled: false, setEnabledError: TestError.loginItemFailed)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.statusText, "Could not change launch-at-login.")
    }

    func testSaveFailureStillAppliesHotkeyImmediatelyAndSurfacesError() {
        let store = SpySettingsStore(settings: .defaults, saveError: TestError.saveFailed)
        let hotkeys = SpyHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.settingsController.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
        XCTAssertTrue(model.statusText.contains("Could not save settings"))
    }

    func testBackendListsReadAndPersistOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, sttRegistry: [
            "a": FakeSTTBackend(id: "a", displayName: "A"),
            "b": FakeSTTBackend(id: "b", displayName: "B"),
        ])
        await model.initialSpeechBackendRefresh?.value

        model.sttBackendList.setEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
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
        settings.kokoroVoice = "af_bella"
        settings.pocketVoice = "alba"
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
            options: {
                TTSOptions(
                    voiceIdentifier: settings.ttsVoiceIdentifier,
                    rate: settings.ttsRate,
                    kokoroVoice: settings.kokoroVoice,
                    pocketVoice: settings.pocketVoice
                )
            },
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

/// Always decodes any envelope for `provider` into a fixed `event`, regardless of `rawPayload`.
/// Used only to drive `IntegrationManager.latestResponse` to a known value through the real
/// consume loop, mirroring how the production socket pipeline keeps it in sync with the store.
private struct StubIntegration: RelayIntegration {
    let provider: AgentProvider
    let event: AgentResponseEvent
    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent { event }
}
