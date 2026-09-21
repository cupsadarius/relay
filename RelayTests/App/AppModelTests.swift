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
    /// it never touches `AppModel.statusText`. `FakeSpeechCoordinator.stop(sessionID:)` only
    /// records the call, so this drives the same overlay transition directly to exercise what
    /// happens once the overlay actually hides. Before the fix, the speak methods left a
    /// "Speaking…"-style string sitting in `statusText`, which `activityStatusText` fell back to
    /// once `.hidden`; with those success-path assignments removed, the fallback must be the
    /// clean idle status instead.
    func testActivityStatusTextReturnsToIdleAfterOverlayHidesFollowingPillStop() {
        let overlayModel = ActivityOverlayModel()
        let speech = FakeSpeechCoordinator()
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
        // `replayLast()` now hops through `sessionRegistry` (a real actor) before falling back to
        // `speechCoordinator.replayLast()`, so a single `Task.yield()` is no longer guaranteed to
        // let it finish; poll instead.
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let speech = FakeSpeechCoordinator(replayError: TestError.saveFailed)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)
        hotkeys.send(.replayLast, .pressed)
        // See `testStopAndReplayOnlyActWhenPressed` for why this polls rather than yielding once.
        await waitUntil { model.diagnosticsEntries.first?.event == .ttsFailed }
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsFailed)
    }

    // MARK: - Session-aware Replay Last

    func testReplayLastWithFocusedHighConfidenceSessionSpeaksThatSessionsLatestReply() async {
        let registry = AgentSessionRegistry()
        let sessionA = await registry.upsert(
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [],
            tty: nil
        )
        _ = await registry.upsert(
            response: makeAgentResponseEvent(providerSessionID: "session-b", text: "Reply B"),
            processAncestry: [],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
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
            response: makeAgentResponseEvent(providerSessionID: "dead-session", text: "Reply from a dead process"),
            processAncestry: [1_234_567],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: deadSession.id),
            frontmostApps: StubFrontmostAppMonitor(pid: nil),
            processInspector: ProcessInspector(runner: AllProcessesDeadRunner())
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
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let store = LatestAgentResponseStore()
        let latest = makeAgentResponseEvent(providerSessionID: "global-latest", text: "Global reply")
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

        let hotkeys = FakeHotkeyManager()
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
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
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
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
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
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
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

    /// Hardens against a latent trap: tier 2 gates on `integrationManager.latestResponse != nil`
    /// but actually speaks via `IntegrationManager.speakLatest()`, which reads its own internal
    /// `LatestAgentResponseStore`. `latestResponse` is now a single-writer projection of that same
    /// store (see `LatestAgentResponseStore.subscribe(_:)`), so clearing the store — even directly,
    /// bypassing the manager's own consume loop, as done here — clears the gate too; `replayLast()`
    /// falls through to tier 3 both because `speakLatest()` finds nothing AND because the gate
    /// itself has already gone false. Simulated here by driving `latestResponse` to non-nil through
    /// the real consume loop, then clearing the backing store out from under it.
    func testReplayLastFallsBackToTierThreeWhenGlobalLatestGateIsTrueButStoreHasNothingToSpeak() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(
            response: makeAgentResponseEvent(providerSessionID: "session-a", text: "Reply A"),
            processAncestry: [4242],
            tty: nil
        )
        let speech = FakeSpeechCoordinator()
        let store = LatestAgentResponseStore()
        let latest = makeAgentResponseEvent(providerSessionID: "global-latest", text: "Global reply")
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
        // Clear the store directly, bypassing the manager's own consume loop entirely (stopped
        // just above) — `latestResponse` is a projection of `store`, so this drives the gate back
        // to `nil` on its own, same as `speakLatest()`'s own `store.get()` finding nothing.
        await store.clear()

        let hotkeys = FakeHotkeyManager()
        let model = makeModel(
            speech: speech,
            hotkeys: hotkeys,
            sessionRegistry: registry,
            focusResolution: StubSessionFocusResolver(focusedSessionID: nil),
            frontmostApps: StubFrontmostAppMonitor(pid: 4242),
            integrationManager: drivenManager
        )

        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.replayCount, 1)
        XCTAssertTrue(speech.requests.isEmpty)
        withExtendedLifetime(model) {}
    }

    private func makeAgentResponseEvent(
        provider: AgentProvider = .claudeCode,
        providerSessionID: String,
        text: String,
        parentPID: Int32 = 900
    ) -> AgentResponseEvent {
        .init(
            id: UUID(), provider: provider, providerSessionID: providerSessionID, turnID: nil,
            text: text, cwd: "/tmp/repo", transcriptPath: nil,
            parentPID: parentPID, environment: [:], capturedAt: Date()
        )
    }

    func testRealAppModelRegistersAKokoroDownloaderButNoAppleDownloader() {
        let model = AppModel(runtime: .makeProduction())

        XCTAssertTrue(model.canDownloadTTSModel("kokoro"))
        XCTAssertTrue(model.canDownloadTTSModel("pocket-tts"))
        XCTAssertFalse(model.canDownloadTTSModel("apple-tts"))
    }

    func testTestVoiceSpeaksAFixedSampleSentenceThroughTheCurrentSelection() async {
        let speech = FakeSpeechCoordinator()
        let model = makeModel(speech: speech)

        await model.testVoice()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests.first?.source, .testVoice)
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertFalse(speech.requests.first?.text.isEmpty ?? true)
        // Same rationale as `testReadSelectionPressedPreprocessesAndSpeaksUserRequest`: the
        // success path leaves `statusText` alone so it can never go stale once the overlay hides.
        XCTAssertEqual(model.statusText, "Ready")
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsSubmitted)
    }

    func testTestVoiceFailureIsLoggedAsTTSFailure() async {
        let speech = FakeSpeechCoordinator(speakError: TestError.saveFailed)
        let model = makeModel(speech: speech)

        await model.testVoice()

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

    /// `autoReadEnabled` is not a hotkey definition, so toggling it must persist immediately
    /// without rebuilding the hotkey matcher (see `AppModelHotkeySideEffectTests` for the
    /// general rule this is one instance of).
    func testToggleAutoReadPersistsWithoutReregisteringHotkeys() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(model.settings.autoReadEnabled)
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false])
        XCTAssertEqual(hotkeys.registrations.count, 1, "toggling auto-read must not rebuild the hotkey matcher")
    }

    /// `toggleAutoRead()` is the shared method behind both the `toggleAutoRead` hotkey (tested
    /// above) and the menu bar's auto-read control — calling it directly exercises the same path
    /// the menu item invokes.
    func testToggleAutoReadMethodTogglesSettingAndStatusText() {
        let store = FakeSettingsStore(settings: .defaults)
        let model = makeModel(store: store)
        XCTAssertTrue(model.settings.autoReadEnabled)

        model.toggleAutoRead()
        XCTAssertFalse(model.settings.autoReadEnabled)
        XCTAssertEqual(model.statusText, "Auto-read disabled")
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false])

        model.toggleAutoRead()
        XCTAssertTrue(model.settings.autoReadEnabled)
        XCTAssertEqual(model.statusText, "Auto-read enabled")
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false, true])
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

    func testRemoveHotkeyClearsTheBindingAndPersists() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.removeHotkey(for: .readSelection)

        XCTAssertNil(model.settings.hotkeys[.readSelection])
        XCTAssertNil(store.saved.last?.hotkeys[.readSelection])
        XCTAssertNil(hotkeys.registrations.last?.hotkeys[.readSelection])
    }

    func testRemoveHotkeyClearsAnExistingConflictMessage() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])
        model.setHotkey(existing, for: .readSelection)
        XCTAssertNotNil(model.hotkeyConflictMessage)

        model.removeHotkey(for: .readSelection)

        XCTAssertNil(model.hotkeyConflictMessage)
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

    /// "Open Microphone Settings" (Security tab) must call the injectable opener seam exactly
    /// once per click — never a real `NSWorkspace` in tests.
    func testOpenMicrophoneSettingsDelegatesToInjectedOpenerExactlyOnce() {
        let opener = FakePrivacySettingsOpener()
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
        let loginItem = FakeLoginItemController(enabled: true)
        let model = makeModel(loginItem: loginItem)

        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testLaunchAtLoginEnabledReflectsServiceInitialStatusWhenDisabled() {
        let loginItem = FakeLoginItemController(enabled: false)
        let model = makeModel(loginItem: loginItem)

        XCTAssertFalse(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginOnRegistersAndUpdatesFlag() {
        let loginItem = FakeLoginItemController(enabled: false)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginOffUnregistersAndUpdatesFlag() {
        let loginItem = FakeLoginItemController(enabled: true)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(false)

        XCTAssertEqual(loginItem.setEnabledCalls, [false])
        XCTAssertFalse(model.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginFailureLeavesFlagMatchingActualStatusAndSurfacesMessage() {
        let loginItem = FakeLoginItemController(enabled: false, setEnabledError: TestError.loginItemFailed)
        let model = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.statusText, "Could not change launch-at-login.")
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

    func testSpeechBackendStatusesDeriveFromSettingsOrderEnabledFirstThenDisabled() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["b", "a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let c = FakeSTTBackend(id: "c", displayName: "C")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b, "c": c])
        await model.initialSpeechBackendRefresh?.value

        XCTAssertEqual(model.sttBackends.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(model.sttBackends.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(model.sttBackends.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(model.sttBackends.map(\.state), [.ready, .ready, .ready])
    }

    func testEnablingBackendAppendsItToOrderAndPersists() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(model.sttBackends.first { $0.id == "b" }?.isEnabled, true)
        XCTAssertEqual(model.sttBackends.first { $0.id == "b" }?.position, 1)
    }

    func testMovingEnabledBackendReordersSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a", "b"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.moveSTTBackend("b", up: true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["b", "a"])
        XCTAssertEqual(model.sttBackends.map(\.id), ["b", "a"])
    }

    func testCannotDisableTheLastEnabledBackend() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let model = makeModel(store: store, sttRegistry: ["a": a])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("a", false)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a"])
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(model.statusText, "At least one speech recognition backend must stay enabled.")
    }

    func testUnknownIDsInSettingsOrderAreIgnoredAndDroppedWhenPersisted() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["ghost", "a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        // "ghost" isn't in the registry, so "a" is treated as the first (and only) known
        // enabled backend, not the second.
        XCTAssertEqual(model.sttBackends.map(\.id), ["a", "b"])
        XCTAssertEqual(model.sttBackends.first { $0.id == "a" }?.position, 0)

        model.setSTTBackendEnabled("a", false)
        XCTAssertEqual(model.statusText, "At least one speech recognition backend must stay enabled.")

        model.setSTTBackendEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
    }

    func testDownloadSpeechModelReportsProgressThenBecomesReady() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setProgressToReport([0.5])
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelManagers: ["parakeet": downloader],
            diagnostics: diagnostics
        )
        await model.initialSpeechBackendRefresh?.value

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0.5)
        }

        await parakeet.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFinished(backendID: "parakeet"),
            .speechModelDownloadStarted(backendID: "parakeet"),
        ])
        XCTAssertNil(model.speechBackendMessage)
    }

    func testDownloadSpeechModelFailureSetsFailedStateFixedStatusTextAndDiagnostics() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setErrorToThrow(TestError.saveFailed)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelManagers: ["parakeet": downloader],
            diagnostics: diagnostics
        )
        await model.initialSpeechBackendRefresh?.value

        await model.downloadSpeechModel("parakeet")

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloadFailed)
        let expectedMessage = "Parakeet model download failed. Check your connection and try again."
        XCTAssertEqual(model.statusText, expectedMessage)
        XCTAssertEqual(model.speechBackendMessage, expectedMessage)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFailed(backendID: "parakeet"),
            .speechModelDownloadStarted(backendID: "parakeet"),
        ])
    }

    func testDownloadCanBeRetriedAfterAFailureWithoutGettingStuck() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setErrorToThrow(TestError.saveFailed)
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelManagers: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value

        await model.downloadSpeechModel("parakeet")
        XCTAssertEqual(model.sttBackends.first?.state, .downloadFailed)

        await downloader.setErrorToThrow(nil)
        await parakeet.setAvailability(.available)
        await model.downloadSpeechModel("parakeet")

        XCTAssertEqual(model.sttBackends.first?.state, .ready)
        XCTAssertNil(model.speechBackendMessage)
        let callCount = await downloader.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testSecondDownloadClickWhileDownloadingIsIgnored() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelManagers: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value

        let firstTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { await downloader.callCount > 0 }

        await model.downloadSpeechModel("parakeet")

        let callCountAfterSecondClick = await downloader.callCount
        XCTAssertEqual(callCountAfterSecondClick, 1)

        await downloader.resume()
        await firstTask.value
    }

    func testDownloadInsertsMissingRowWhenNoStatusExistsYet() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelManagers: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value
        model.sttBackends = [] // simulate a Download click before any status row exists

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { model.sttBackends.first(where: { $0.id == "parakeet" }) != nil }

        let row = model.sttBackends.first(where: { $0.id == "parakeet" })
        XCTAssertEqual(row?.displayName, "Parakeet")
        XCTAssertEqual(row?.state, .downloading(progress: 0))

        await downloader.resume()
        await downloadTask.value
    }

    func testConcurrentRefreshDuringADownloadDoesNotClobberDownloadingState() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelManagers: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value

        // Block availability() so a refresh started now is still awaiting mid-flight.
        await parakeet.setShouldBlockAvailability(true)
        let refreshTask = Task { await model.refreshSpeechBackendStatuses() }
        await waitUntil { await parakeet.availabilityCallCount > 0 }

        // A Download starts while that refresh is still suspended inside availability().
        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0)
        }

        await parakeet.resumeAvailability()
        await refreshTask.value

        // The refresh's now-stale "model not downloaded" snapshot must not have clobbered the
        // download that started while it was in flight.
        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloading(progress: 0))

        await parakeet.setShouldBlockAvailability(false)
        await parakeet.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
    }

    func testLateProgressCallbackAfterCompletionDoesNotChangeReadyState() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelManagers: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value
        await parakeet.setAvailability(.available)

        await model.downloadSpeechModel("parakeet")
        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)

        await downloader.reportProgress(1.0) // a tick arriving after the download already finished
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
    }

    func testOutOfOrderLowerProgressTickIsIgnored() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelManagers: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { await downloader.callCount > 0 }

        await downloader.reportProgress(0.7)
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0.7)
        }

        await downloader.reportProgress(0.3) // out of order: must not move progress backwards
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloading(progress: 0.7))

        await downloader.resume()
        await downloadTask.value
    }

    func testCanDownloadSpeechModelReflectsWhetherADownloaderIsRegistered() {
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let modelWithoutDownloader = makeModel(sttRegistry: ["a": a])
        XCTAssertFalse(modelWithoutDownloader.canDownloadSpeechModel("a"))

        let downloader = FakeSpeechModelManager()
        let modelWithDownloader = makeModel(sttRegistry: ["a": a], speechModelManagers: ["a": downloader])
        XCTAssertTrue(modelWithDownloader.canDownloadSpeechModel("a"))
    }

    func testRefreshSpeechModelsPopulatesRowsPerBackend() async {
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet")
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let parakeetManager = FakeMultiModelSpeechModelManager(backendID: "parakeet", models: [
            makeModelStatus(id: "parakeet-v2", isSelected: true),
        ])
        let whisperManager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny", isSelected: true),
            makeModelStatus(id: "whisper-base"),
        ])
        let model = makeModel(
            sttRegistry: ["parakeet": parakeet, "whisper": whisper],
            speechModelManagers: ["parakeet": parakeetManager, "whisper": whisperManager]
        )

        await model.refreshSpeechModels()

        XCTAssertEqual(model.speechModels["parakeet"]?.map(\.id), ["parakeet-v2"])
        XCTAssertEqual(model.speechModels["whisper"]?.map(\.id), ["whisper-tiny", "whisper-base"])
    }

    func testDownloadSpeechModelMarksOnlyThatModelDownloadingAndFinishesDownloaded() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
            makeModelStatus(id: "whisper-base"),
        ])
        await manager.setProgressToReport("whisper-tiny", [0.5])
        await manager.setShouldBlock("whisper-tiny", true)
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()

        let downloadTask = Task { await model.downloadSpeechModel(backendID: "whisper", modelID: "whisper-tiny") }
        await waitUntil {
            model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState == .downloading(progress: 0.5)
        }

        XCTAssertTrue(model.downloadingModelKeys.contains("whisper/whisper-tiny"))
        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-base" })?.installState, .notDownloaded)

        await manager.resumeDownload("whisper-tiny")
        await downloadTask.value

        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState, .downloaded)
        XCTAssertFalse(model.downloadingModelKeys.contains("whisper/whisper-tiny"))
        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-base" })?.installState, .notDownloaded)
    }

    func testDownloadProgressIsMonotonicPerModel() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
        ])
        await manager.setShouldBlock("whisper-tiny", true)
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()

        let downloadTask = Task { await model.downloadSpeechModel(backendID: "whisper", modelID: "whisper-tiny") }
        await waitUntil { await manager.downloadCallCount("whisper-tiny") > 0 }

        await manager.reportProgress("whisper-tiny", 0.7)
        await waitUntil {
            model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState == .downloading(progress: 0.7)
        }

        await manager.reportProgress("whisper-tiny", 0.3) // out of order: must not move progress backwards
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState,
            .downloading(progress: 0.7)
        )

        await manager.resumeDownload("whisper-tiny")
        await downloadTask.value
    }

    func testDownloadFailureMarksThatModelDownloadFailedWithoutTouchingSiblings() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
            makeModelStatus(id: "whisper-base", installState: .downloaded),
        ])
        await manager.setErrorToThrow("whisper-tiny", TestError.saveFailed)
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()

        await model.downloadSpeechModel(backendID: "whisper", modelID: "whisper-tiny")

        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState, .downloadFailed)
        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-base" })?.installState, .downloaded)
        XCTAssertFalse(model.downloadingModelKeys.contains("whisper/whisper-tiny"))
        XCTAssertEqual(model.statusText, "Whisper model download failed. Check your connection and try again.")
    }

    func testSelectSpeechModelUpdatesSelectedRowAndRefreshesAvailability() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny", isSelected: true),
            makeModelStatus(id: "whisper-base"),
        ])
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()
        let callCountBeforeSelect = await whisper.availabilityCallCount

        await model.selectSpeechModel(backendID: "whisper", modelID: "whisper-base")

        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.isSelected, false)
        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-base" })?.isSelected, true)
        let selectCalls = await manager.selectCalls
        XCTAssertEqual(selectCalls, ["whisper-base"])
        // F1: selecting a model must also re-derive `sttBackends` (via `backend.availability()`),
        // not just the per-model `speechModels` row -- otherwise `WhisperBackend.availability()`
        // (selected-model presence) goes stale on the backend-level surface after a selection.
        let callCountAfterSelect = await whisper.availabilityCallCount
        XCTAssertGreaterThan(callCountAfterSelect, callCountBeforeSelect)
    }

    func testRemoveSpeechModelDelegatesToManagerAndRefreshes() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny", installState: .downloaded),
        ])
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()
        let callCountBeforeRemove = await whisper.availabilityCallCount

        await model.removeSpeechModel(backendID: "whisper", modelID: "whisper-tiny")

        let removeCalls = await manager.removeCalls
        XCTAssertEqual(removeCalls, ["whisper-tiny"])
        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState, .notDownloaded)
        // F1: removing a model must also re-derive `sttBackends` -- a removed selected model
        // should be reflected in backend-level availability, not just the per-model row.
        let callCountAfterRemove = await whisper.availabilityCallCount
        XCTAssertGreaterThan(callCountAfterRemove, callCountBeforeRemove)
    }

    /// F1: a successful per-model download must also refresh `sttBackends` (via
    /// `backend.availability()`), so a backend whose availability derives from the just-downloaded
    /// model (e.g. Whisper, once the selected model is present on disk) doesn't stay stale on the
    /// backend-level surface until some unrelated refresh happens to run.
    func testDownloadSpeechModelRefreshesBackendAvailabilityOnSuccess() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
        ])
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()
        let callCountBeforeDownload = await whisper.availabilityCallCount

        await model.downloadSpeechModel(backendID: "whisper", modelID: "whisper-tiny")

        let callCountAfterDownload = await whisper.availabilityCallCount
        XCTAssertGreaterThan(callCountAfterDownload, callCountBeforeDownload)
    }

    /// F1 (failure path): a FAILED per-model download does not need a backend-availability
    /// refresh -- nothing about the backend's availability could have changed by a download that
    /// never landed any bytes -- so this pins that `downloadSpeechModel` only refreshes on
    /// success, matching the spec's "after a successful per-model download" wording exactly.
    func testDownloadSpeechModelFailureDoesNotRefreshBackendAvailability() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
        ])
        await manager.setErrorToThrow("whisper-tiny", TestError.saveFailed)
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])
        await model.refreshSpeechModels()
        let callCountBeforeDownload = await whisper.availabilityCallCount

        await model.downloadSpeechModel(backendID: "whisper", modelID: "whisper-tiny")

        let callCountAfterDownload = await whisper.availabilityCallCount
        XCTAssertEqual(callCountAfterDownload, callCountBeforeDownload)
    }

    func testConcurrentRefreshGenerationCounterKeepsLatest() async {
        let whisper = FakeSTTBackend(id: "whisper", displayName: "Whisper")
        let manager = FakeMultiModelSpeechModelManager(backendID: "whisper", models: [
            makeModelStatus(id: "whisper-tiny"),
        ])
        let model = makeModel(sttRegistry: ["whisper": whisper], speechModelManagers: ["whisper": manager])

        await manager.setShouldBlockModels(true)
        let staleTask = Task { await model.refreshSpeechModels() }
        await waitUntil { await manager.modelsCallCount > 0 }

        // A newer refresh starts and completes while the stale one is still suspended inside
        // models().
        await manager.setStatus("whisper-tiny", installState: .downloaded)
        await manager.setShouldBlockModels(false)
        await model.refreshSpeechModels()

        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState, .downloaded)

        // Resuming the stale refresh must not clobber the newer (already-applied) result.
        await manager.resumeModels()
        await staleTask.value

        XCTAssertEqual(model.speechModels["whisper"]?.first(where: { $0.id == "whisper-tiny" })?.installState, .downloaded)
    }

    func testSpeechBackendMessageIsSetOnRefusalAndClearedOnNextSuccessfulAction() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("a", false)
        XCTAssertEqual(model.speechBackendMessage, "At least one speech recognition backend must stay enabled.")

        model.setSTTBackendEnabled("b", true)
        XCTAssertNil(model.speechBackendMessage)
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
    /// `FakeSpeechCoordinator` the other tests in this file use) wired exactly like the
    /// production convenience `init()` wires PocketTTS, Apple, and Kokoro: `backendOrder` and the
    /// `TTSOptions.kokoroVoice`/`pocketVoice` fields all read from the same settings snapshot.
    /// This exercises the one-line options-closure edit the plan calls out as the easiest step to
    /// miss - if `kokoroVoice`/`pocketVoice` stopped reaching `TTSOptions`, the routing tests
    /// above would fail.
    private func makeTTSRoutingModel(
        pocketAvailability: BackendAvailability,
        kokoroAvailability: BackendAvailability
    ) -> (
        model: AppModel, hotkeys: FakeHotkeyManager, pocket: FakeTTSBackend, kokoro: FakeTTSBackend, apple: FakeTTSBackend
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
        let store = FakeSettingsStore(settings: settings)
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
        let hotkeys = FakeHotkeyManager()
        let model = AppModel(
            settingsStore: store,
            selectionReader: FakeSelectionReader(text: "hello"),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: coordinator,
            hotkeyManager: hotkeys,
            permissionService: FakePermissionService(snapshot: .init(inputMonitoringGranted: true, accessibilityGranted: true)),
            diagnostics: DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: nil,
            microphonePermissions: FakeMicrophonePermissionStatus(granted: true),
            privacySettingsOpener: FakePrivacySettingsOpener(),
            overlayModel: overlay,
            overlayPresenter: NoOpActivityOverlayPresenter(),
            sttRegistry: [:],
            speechModelManagers: [:],
            ttsRegistry: ["pocket-tts": pocket, "kokoro": kokoro, "apple-tts": apple]
        )
        return (model, hotkeys, pocket, kokoro, apple)
    }

    func testRefreshMapsBackendAvailabilityCasesToFixedStates() async {
        let cases: [(BackendAvailability, STTBackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedOS, .unsupported),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("some reason"), .unavailable),
            (.initializing, .unavailable),
            (.failed("boom"), .unavailable),
        ]

        for (availability, expected) in cases {
            let backend = FakeSTTBackend(id: "x", displayName: "X", availability: availability)
            let model = makeModel(sttRegistry: ["x": backend])
            await model.initialSpeechBackendRefresh?.value

            XCTAssertEqual(model.sttBackends.first?.state, expected, "availability: \(availability)")
        }
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
        store: FakeSettingsStore? = nil,
        selection: FakeSelectionReader? = nil,
        speech: FakeSpeechCoordinator? = nil,
        hotkeys: FakeHotkeyManager? = nil,
        permissions: FakePermissionService? = nil,
        dictation: FakeDictationCoordinator? = nil,
        microphone: FakeMicrophonePermissionStatus? = nil,
        opener: FakePrivacySettingsOpener? = nil,
        loginItem: FakeLoginItemController? = nil,
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
        AppModel(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            selectionReader: selection ?? FakeSelectionReader(text: "selected"),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: speech ?? FakeSpeechCoordinator(),
            hotkeyManager: hotkeys ?? FakeHotkeyManager(),
            permissionService: permissions ?? FakePermissionService(snapshot: .init(inputMonitoringGranted: true, accessibilityGranted: true)),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: dictation,
            microphonePermissions: microphone ?? FakeMicrophonePermissionStatus(granted: true),
            privacySettingsOpener: opener ?? FakePrivacySettingsOpener(),
            loginItemService: loginItem ?? FakeLoginItemController(enabled: false),
            overlayModel: overlayModel ?? ActivityOverlayModel(),
            overlayPresenter: overlayPresenter ?? NoOpActivityOverlayPresenter(),
            sttRegistry: sttRegistry,
            speechModelManagers: speechModelManagers,
            integrationManager: integrationManager,
            sessionRegistry: sessionRegistry ?? AgentSessionRegistry(),
            focusResolution: focusResolution ?? FocusResolutionService(
                registry: AgentSessionRegistry(),
                frontmostApps: FrontmostAppMonitor(),
                resolvers: []
            ),
            frontmostApps: frontmostApps ?? FrontmostAppMonitor(),
            // A real `ProcessInspector()` default would shell out to `/bin/ps` and, finding no
            // live process at this file's fabricated pids (e.g. 4242), prune `replayLast()`'s
            // fixture sessions before focus resolution ever runs. Default to a fake reporting
            // every fabricated pid alive; tests that specifically exercise pruning inject their
            // own.
            processInspector: processInspector ?? ProcessInspector(runner: AlwaysAliveProcessRunner())
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
private final class FakeLoginItemController: LoginItemControlling {
    private(set) var isEnabled: Bool
    private(set) var setEnabledCalls: [Bool] = []
    private let setEnabledError: Error?

    init(enabled: Bool, setEnabledError: Error? = nil) {
        isEnabled = enabled
        self.setEnabledError = setEnabledError
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let setEnabledError { throw setEnabledError }
        isEnabled = enabled
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
    case loginItemFailed
}

private actor FakeSTTBackend: SpeechToTextBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let capabilities = STTCapabilities([])
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

    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        Transcript(text: "", backendID: id)
    }
}

private func makeModelStatus(
    id: String,
    installState: SpeechModelInstallState = .notDownloaded,
    isSelected: Bool = false,
    isLoaded: Bool = false
) -> SpeechModelStatus {
    SpeechModelStatus(
        descriptor: SpeechModelDescriptor(id: id, displayName: id, detail: nil, approximateDownloadBytes: nil),
        capabilities: [.download, .select, .remove],
        installState: installState,
        isSelected: isSelected,
        isLoaded: isLoaded
    )
}

/// A multi-model `SpeechModelManaging` fake used by the per-model download/select/remove tests
/// (Whisper hasn't registered as a backend yet, so these tests exercise the new per-model surface
/// against a fake with more than one model). Mirrors `FakeSpeechModelManager`'s and
/// `FakeSTTBackend`'s blocking/continuation style, but keyed per model id so one model's download
/// (or `models()` call) can be held in flight independently of its siblings.
private actor FakeMultiModelSpeechModelManager: SpeechModelManaging {
    let backendID: String
    private var statuses: [String: SpeechModelStatus]
    private let order: [String]

    private(set) var modelsCallCount = 0
    private var shouldBlockModels = false
    private var modelsContinuation: CheckedContinuation<Void, Never>?

    private var downloadCallCounts: [String: Int] = [:]
    private var progressToReport: [String: [Double]] = [:]
    private var errorToThrow: [String: Error] = [:]
    private var shouldBlockDownload: Set<String> = []
    private var downloadContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var downloadResumeRequested: Set<String> = []
    private var capturedProgress: [String: @Sendable (Double) -> Void] = [:]

    private(set) var selectCalls: [String] = []
    private(set) var removeCalls: [String] = []

    init(backendID: String, models: [SpeechModelStatus]) {
        self.backendID = backendID
        order = models.map(\.id)
        statuses = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    }

    func models() async -> [SpeechModelStatus] {
        modelsCallCount += 1
        if shouldBlockModels {
            await withCheckedContinuation { modelsContinuation = $0 }
        }
        return order.compactMap { statuses[$0] }
    }

    /// Makes `models()` suspend on a continuation instead of returning immediately, so a test can
    /// deterministically hold a refresh mid-flight and interleave a second refresh before calling
    /// `resumeModels()`.
    func setShouldBlockModels(_ value: Bool) { shouldBlockModels = value }

    func resumeModels() {
        modelsContinuation?.resume()
        modelsContinuation = nil
    }

    func setStatus(_ id: String, installState: SpeechModelInstallState? = nil, isSelected: Bool? = nil) {
        guard var status = statuses[id] else { return }
        if let installState { status.installState = installState }
        if let isSelected { status.isSelected = isSelected }
        statuses[id] = status
    }

    func setProgressToReport(_ id: String, _ values: [Double]) { progressToReport[id] = values }
    func setErrorToThrow(_ id: String, _ error: Error?) { errorToThrow[id] = error }
    func setShouldBlock(_ id: String, _ value: Bool) {
        if value { shouldBlockDownload.insert(id) } else { shouldBlockDownload.remove(id) }
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCallCounts[id, default: 0] += 1
        capturedProgress[id] = progress
        for value in progressToReport[id] ?? [] {
            progress(value)
        }
        if shouldBlockDownload.contains(id) {
            if downloadResumeRequested.contains(id) {
                downloadResumeRequested.remove(id)
            } else {
                await withCheckedContinuation { downloadContinuations[id] = $0 }
            }
        }
        if let error = errorToThrow[id] {
            throw error
        }
    }

    /// Order-independent, per-model: resumes an already-blocked `downloadModel(id)` call, or --
    /// if none is blocked yet -- arms a per-id resume flag so that model's next `downloadModel`
    /// call skips blocking instead of hanging on a continuation nobody will resume.
    func resumeDownload(_ id: String) {
        if let continuation = downloadContinuations[id] {
            continuation.resume()
            downloadContinuations[id] = nil
        } else {
            downloadResumeRequested.insert(id)
        }
    }

    func reportProgress(_ id: String, _ value: Double) {
        capturedProgress[id]?(value)
    }

    func downloadCallCount(_ id: String) -> Int { downloadCallCounts[id, default: 0] }

    func removeModel(_ id: String) async throws {
        removeCalls.append(id)
        statuses[id]?.installState = .notDownloaded
    }

    func selectModel(_ id: String) async throws {
        selectCalls.append(id)
        for key in statuses.keys {
            statuses[key]?.isSelected = (key == id)
        }
    }
}

/// A one-model `SpeechModelManaging` fake. Both STT and TTS backends now use `SpeechModelManaging`
/// for model management. `models()` always reports a single model under `modelID`; `downloadModel` is the
/// method under test in every "download" test in this file, and reproduces the exact
/// progress/blocking/failure behavior the old `FakeSpeechModelDownloader.downloadModels` had, so
/// every existing assertion (progress ticks, retry after failure, single-flight, stale/late
/// progress) still holds unchanged against the new manager surface.
private actor FakeSpeechModelManager: SpeechModelManaging {
    let backendID: String
    private let modelID: String
    private(set) var callCount = 0
    private var progressToReport: [Double] = []
    private var errorToThrow: Error?
    private var shouldBlock = false
    private var continuation: CheckedContinuation<Void, Never>?
    /// True once `resume()` has been called with no `downloadModel` call currently blocked to
    /// resume. `downloadSpeechModel` now resolves the manager's model id via `models()` before
    /// calling `downloadModel` -- an extra actor hop versus the old direct `downloadModels` call
    /// -- so a caller that calls `resume()` the instant it observes the "downloading" row (before
    /// `downloadModel` has actually reached its blocking point) must not have that resume lost.
    /// This flag makes `resume()` order-independent: called early, it makes the *next*
    /// `downloadModel` call skip blocking entirely instead of arming a continuation nobody will
    /// ever resume.
    private var resumeRequested = false
    private var capturedProgress: (@Sendable (Double) -> Void)?

    init(backendID: String = "parakeet", modelID: String = "parakeet-v2") {
        self.backendID = backendID
        self.modelID = modelID
    }

    func setProgressToReport(_ values: [Double]) { progressToReport = values }
    func setErrorToThrow(_ error: Error?) { errorToThrow = error }
    func setShouldBlock(_ value: Bool) { shouldBlock = value }

    func models() async -> [SpeechModelStatus] {
        [
            SpeechModelStatus(
                descriptor: SpeechModelDescriptor(id: modelID, displayName: modelID, detail: nil, approximateDownloadBytes: nil),
                capabilities: [.download, .select, .remove],
                installState: .notDownloaded,
                isSelected: true,
                isLoaded: false
            ),
        ]
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        callCount += 1
        capturedProgress = progress
        for value in progressToReport {
            progress(value)
        }
        if shouldBlock {
            if resumeRequested {
                resumeRequested = false
            } else {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }

    func removeModel(_ id: String) async throws {}

    func selectModel(_ id: String) async throws {}

    /// Order-independent: resumes an already-blocked `downloadModel` call, or -- if none is
    /// blocked yet -- arms `resumeRequested` so the next `downloadModel` call skips blocking
    /// instead of hanging forever on a continuation nobody will resume.
    func resume() {
        if let continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            resumeRequested = true
        }
    }

    /// Invokes the progress closure captured from the most recent `downloadModel` call, letting
    /// a test simulate a tick arriving at an arbitrary time — including after completion, or out
    /// of order relative to an earlier tick.
    func reportProgress(_ value: Double) {
        capturedProgress?(value)
    }
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
    let speakError: Error?
    init(replayError: Error? = nil, speakError: Error? = nil) {
        self.replayError = replayError
        self.speakError = speakError
    }

    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
        if let speakError { throw speakError }
    }
    func stop() { stopCount += 1 }
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws { replayCount += 1; if let replayError { throw replayError } }
}

/// Reports `focusedSessionID` (when set) as confidently `.focused`; every other session, and
/// every session when `focusedSessionID` is `nil`, resolves as `.unknown`/low-confidence —
/// exactly what `AppModel.replayLast()`'s tier-1 loop treats as "not this one".
private struct StubSessionFocusResolver: SessionFocusResolving {
    let focusedSessionID: AgentSessionID?
    func resolve(session: AgentSession) async -> FocusDecision {
        guard let focusedSessionID, session.id == focusedSessionID else {
            return .unknown(resolverID: "stub", reason: "not the stubbed focused session")
        }
        return .focused(resolverID: "stub", reason: "stubbed focused session")
    }
}

/// Reports a fixed frontmost pid (or no frontmost application at all when `pid` is `nil`).
private struct StubFrontmostAppMonitor: FrontmostAppMonitoring {
    let pid: Int32?
    func current() async -> FrontmostApplication? {
        guard let pid else { return nil }
        return FrontmostApplication(pid: pid, bundleIdentifier: "com.test.terminal", localizedName: "TestTerminal")
    }
}

/// Reports every pid in a wide synthetic range as alive, standing in for a live process table so
/// this file's fabricated pids (e.g. `processAncestry: [4242]`) are never treated as dead by
/// `AppModel.replayLast()`'s prune-before-focus step.
private final class AlwaysAliveProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let lines = (1...10_000).map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
}

/// Reports an empty process table, so every pid looks dead — used to exercise
/// `AppModel.replayLast()`'s prune-before-focus step.
private final class AllProcessesDeadRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        ProcessResult(stdout: Data(), terminationStatus: 0)
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
