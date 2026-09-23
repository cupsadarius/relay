import XCTest
@testable import Relay

@MainActor
final class SpeechActionsTests: XCTestCase {
    private func makeActions(
        speech: SpySpeechCoordinator? = nil,
        selection: SpySelectionReader? = nil,
        store: SpySettingsStore? = nil,
        integrationManager: IntegrationManager? = nil,
        registry: AgentSessionRegistry = AgentSessionRegistry(),
        frontmostPID: Int32? = nil,
        focused: AgentSessionID? = nil
    ) -> (actions: SpeechActions, runtime: RelayRuntime) {
        let speech = speech ?? SpySpeechCoordinator()
        let selection = selection ?? SpySelectionReader()
        let store = store ?? SpySettingsStore()
        let runtime = RelayRuntime.testing(
            settingsStore: store,
            selectionReader: selection,
            speechCoordinator: speech,
            integrationManager: integrationManager,
            sessionRegistry: registry,
            frontmostApps: StubFrontmostAppMonitor(pid: frontmostPID),
            focusResolution: StubSessionFocusResolver(focusedSessionID: focused)
        )
        let catalog = SpeechVoiceCatalog(
            appleVoices: [], kokoroVoices: ["af_heart", "am_adam"], recommendedKokoroVoice: "af_heart", pocketVoice: "alba"
        )
        return (SpeechActions(runtime: runtime, voiceCatalog: catalog), runtime)
    }

    /// Drives one event through a real `IntegrationManager` consume loop so `latestResponse`
    /// and its store agree, exactly as the socket pipeline keeps them.
    private func drivenManager(
        latest: AgentResponseEvent,
        store: LatestAgentResponseStore,
        speech: SpySpeechCoordinator
    ) async -> IntegrationManager {
        await store.set(latest)
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [StubDecodingIntegration(provider: .claudeCode, event: latest)],
            store: store,
            speechCoordinator: speech
        )
        manager.start()
        continuation.yield(HookEnvelope(
            schemaVersion: 1, provider: .claudeCode, rawPayload: "{}",
            parentPID: 100, environment: [:], capturedAt: latest.capturedAt
        ))
        let deadline = Date().addingTimeInterval(2)
        while manager.latestResponse == nil, Date() < deadline { await Task.yield() }
        manager.stop()
        return manager
    }

    func testReadSelectionPreprocessesAndSpeaksAUserRequest() async {
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(
            speech: speech,
            selection: SpySelectionReader(text: "Intro\n```swift\nsecret()\n```\nEnd")
        )

        await actions.readSelection()

        XCTAssertEqual(speech.requests, [SpeechRequest(
            text: "Intro There is a code block on screen. Please read it there. End",
            source: .selection, mode: .userRequested, sessionID: nil
        )])
        XCTAssertEqual(runtime.status.message, "Ready")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsSubmitted)
    }

    func testFocusedSessionReplaySpeaksThatSessionsReply() async {
        let registry = AgentSessionRegistry()
        let sessionA = await registry.upsert(response: .fixture(providerSessionID: "session-a", text: "Reply A"), processAncestry: [], tty: nil)
        let speech = SpySpeechCoordinator()
        let (actions, _) = makeActions(speech: speech, registry: registry, focused: sessionA.id)

        await actions.replayLast()

        XCTAssertEqual(speech.requests.first?.sessionID, "claude-code:session-a")
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertEqual(speech.replayCount, 0)
    }

    func testGlobalLatestReplaySpeaksTheLatestAgentResponse() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(response: .fixture(providerSessionID: "session-a"), processAncestry: [4242], tty: nil)
        let speech = SpySpeechCoordinator()
        let manager = await drivenManager(
            latest: .fixture(providerSessionID: "global-latest", text: "Global reply"),
            store: LatestAgentResponseStore(),
            speech: speech
        )
        let (actions, _) = makeActions(speech: speech, integrationManager: manager, registry: registry, frontmostPID: 4242)

        await actions.replayLast()

        XCTAssertEqual(speech.requests.map(\.sessionID), ["claude-code:global-latest"])
        XCTAssertEqual(speech.replayCount, 0)
    }

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let (actions, runtime) = makeActions(speech: SpySpeechCoordinator(replayError: SpeechBoom()))

        await actions.replayLast()

        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsFailed)
    }

    /// Plan 1: a cancelled speak (Stop, or a newer press) is intentional, not a failure.
    func testCancelledReplayIsNotReportedAsFailure() async {
        let (actions, runtime) = makeActions(speech: SpySpeechCoordinator(replayError: CancellationError()))

        await actions.replayLast()

        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(runtime.status.message, "Ready")
    }

    func testCancelledReadSelectionIsNotReportedAsFailure() async {
        let speech = SpySpeechCoordinator(speakError: CancellationError())
        let (actions, runtime) = makeActions(speech: speech)

        await actions.readSelection()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(runtime.status.message, "Ready")
    }

    /// A replay whose task was cancelled while focus was resolving never speaks.
    func testReplayInACancelledTaskSpeaksNothing() async {
        let speech = SpySpeechCoordinator()
        let (actions, _) = makeActions(speech: speech)

        let task = Task { await actions.replayLast() }
        task.cancel()
        await task.value

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testStopSpeechStopsAndAnnounces() {
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(speech: speech)

        actions.stopSpeech()

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(runtime.status.message, "Speech stopped")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsStopped)
    }

    func testPreviewVoiceUsesClickedProviderAndCurrentRateWithoutPersisting() async {
        var settings = AppSettings.defaults
        settings.voiceByBackend["kokoro"] = "af_heart"
        settings.ttsRate = 0.75
        let store = SpySettingsStore(settings: settings)
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(speech: speech, store: store)

        await actions.previewVoice(backendID: "kokoro", voiceID: "kokoro:am_adam")

        XCTAssertEqual(speech.previews.first?.backendID, "kokoro")
        XCTAssertEqual(speech.previews.first?.options.kokoroVoice, "am_adam")
        XCTAssertEqual(speech.previews.first?.options.rate, 0.75)
        XCTAssertEqual(speech.previews.first?.text, SpeechActions.previewSampleText)
        XCTAssertEqual(runtime.settingsController.current.voiceByBackend["kokoro"], "af_heart")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testSpeakLatestAgentResponseFailureIsSurfaced() async {
        let store = LatestAgentResponseStore()
        await store.set(.fixture(provider: .codex, providerSessionID: "session-2"))
        let speech = SpySpeechCoordinator(speakError: SpeechBoom())
        let manager = IntegrationManager(events: AsyncStream { _ in }, integrations: [], store: store, speechCoordinator: speech)
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)

        await actions.speakLatestAgentResponse()

        XCTAssertEqual(runtime.status.message, "Could not speak the latest agent response.")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsFailed)
    }

    /// Moved from plan 1's `AppModelIntegrationsTests`: nothing to speak is not a submission.
    func testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission() async {
        let speech = SpySpeechCoordinator()
        let manager = IntegrationManager(
            events: AsyncStream<HookEnvelope> { _ in },
            integrations: [],
            store: LatestAgentResponseStore(),
            speechCoordinator: speech
        )
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)

        await actions.speakLatestAgentResponse()

        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsSubmitted })
        XCTAssertEqual(runtime.status.message, "No agent response to speak yet.")
    }

    /// Moved from `AppModelIntegrationsTests`: a successful speak clears a stale failure message.
    func testSpeakLatestAgentResponseSuccessClearsAStaleStatusText() async {
        let store = LatestAgentResponseStore()
        await store.set(.fixture(providerSessionID: "session-3", text: "Done."))
        let speech = SpySpeechCoordinator()
        let manager = IntegrationManager(events: AsyncStream { _ in }, integrations: [], store: store, speechCoordinator: speech)
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)
        runtime.status.post("Could not speak the latest agent response.")

        await actions.speakLatestAgentResponse()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(runtime.status.message, "Ready")
    }
}

private struct SpeechBoom: Error {}

private struct StubDecodingIntegration: RelayIntegration {
    let provider: AgentProvider
    let event: AgentResponseEvent
    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent { event }
}
