import XCTest

@testable import Relay

@MainActor
final class SpeechCoordinatorTests: XCTestCase {
    func testVoicePreviewInterruptsAndUsesExactBackendOptions() async throws {
        let first = FakeTTSBackend(id: "first")
        let preferred = FakeTTSBackend(id: "preferred")
        let player = FakePlayer()
        first.player = player
        preferred.player = player
        let router = TTSRouter(
            backends: [first.id: first, preferred.id: preferred],
            backendOrder: { [first.id, preferred.id] },
            player: player
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: { .init() },
            overlay: ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        )
        let options = TTSOptions(rate: 0.8, kokoroVoice: "am_adam")

        try await coordinator.speak(request(text: "first", mode: .userRequested))
        try await coordinator.previewVoice(text: "preview", backendID: "preferred", options: options)

        XCTAssertEqual(first.spoken.map(\.text), ["first"])
        XCTAssertEqual(preferred.spoken.map(\.text), ["preview"])
        XCTAssertEqual(preferred.spoken.first?.options, options)
        XCTAssertEqual(player.stopCount, 1)
    }

    func testUserRequestedSpeechReplacesActiveSpeech() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let coordinator = makeCoordinator(backend: backend)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        try await coordinator.speak(request(text: "second", mode: .userRequested))

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "second"])
    }

    func testAutomaticSpeechEnqueuesBehindActivePlaybackAndStartsOnFinish() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        guard case let .speaking(startedSession, _, _) = overlay.state, startedSession == first else {
            return XCTFail("Expected first session speaking, got \(overlay.state)")
        }

        try await coordinator.speak(request(text: "second", mode: .automatic))

        // The second automatic request must be enqueued, not dispatched, while the first plays.
        XCTAssertEqual(backend.spoken.map(\.text), ["first"])
        // The overlay must keep showing the first session - queuing a second
        // automatic utterance behind it must not hide the capsule.
        guard case let .speaking(stillFirst, _, _) = overlay.state, stillFirst == first else {
            return XCTFail("Expected overlay to still show first session, got \(overlay.state)")
        }

        backend.emit(.finished(sessionID: first))
        await pumpMainActor()

        XCTAssertEqual(backend.spoken.map(\.text), ["first", "second"])
        let second = backend.lastSessionID!
        XCTAssertNotEqual(second, first)

        backend.emit(.started(sessionID: second))
        guard case let .speaking(nowSecond, _, _) = overlay.state, nowSecond == second else {
            return XCTFail("Expected overlay to show second session, got \(overlay.state)")
        }
    }

    func testQueueCapDropsOldestBeyondEightPending() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "playing", mode: .automatic))
        let playing = backend.lastSessionID!
        backend.emit(.started(sessionID: playing))

        for index in 1...9 {
            try await coordinator.speak(request(text: "queued-\(index)", mode: .automatic))
        }

        backend.emit(.finished(sessionID: playing))
        await pumpMainActor()

        // 9 requests were enqueued behind a cap of 8; the oldest ("queued-1") must be dropped, so
        // the next one dispatched is "queued-2".
        XCTAssertEqual(backend.spoken.last?.text, "queued-2")
    }

    func testUserRequestedClearsQueuedAutomaticRequests() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        try await coordinator.speak(request(text: "manual", mode: .userRequested))
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "manual"])

        backend.emit(.finished(sessionID: backend.lastSessionID!))
        await pumpMainActor()

        // The queued automatic request was cleared by the userRequested interruption and must
        // never play, even after the manual request finishes.
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "manual"])
    }

    func testStopClearsQueueAndResetsBusyState() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        coordinator.stop()

        try await coordinator.speak(request(text: "after-stop", mode: .automatic))

        // "after-stop" starts immediately since stop() reset the busy flag, and "queued" must
        // never play since stop() cleared it.
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "after-stop"])
    }

    func testStopSessionIDClearsQueueWhenItStopsTheCurrentSession() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        coordinator.stop(sessionID: first)

        try await coordinator.speak(request(text: "after-stop", mode: .automatic))

        XCTAssertEqual(backend.spoken.map(\.text), ["first", "after-stop"])
    }

    func testReplayLastClearsQueuedAutomaticRequests() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        try await coordinator.replayLast()
        backend.emit(.finished(sessionID: backend.lastSessionID!))
        await pumpMainActor()

        // Replay is a manual action: it must clear the pending queue so "queued" never plays.
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "first"])
    }

    func testLastRequestReflectsStartedRequestNotMerelyQueued() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))

        try await coordinator.speak(request(text: "queued", mode: .automatic))
        // "queued" was only enqueued (never started), so it must not have reached the backend.
        XCTAssertEqual(backend.spoken.map(\.text), ["first"])

        try await coordinator.replayLast()

        // Replay must still target "first" - the actually-started request - not "queued".
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "first"])
    }

    func testReplayUsesLastSuccessfulRequestAndCurrentOptions() async throws {
        let backend = FakeTTSBackend(id: "apple")
        var options = TTSOptions(voiceIdentifier: "first-voice", rate: 0.4)
        let coordinator = makeCoordinator(backend: backend, options: { options })

        try await coordinator.speak(request(text: "remember me", mode: .automatic))
        // Let the busy flag clear so the next automatic call actually reaches the backend
        // (and its induced failure) instead of merely enqueuing behind this one.
        backend.emit(.finished(sessionID: backend.lastSessionID!))

        backend.error = SpeechBackendError.invalidInput
        try? await coordinator.speak(request(text: "do not remember", mode: .automatic))
        backend.error = nil
        options = TTSOptions(voiceIdentifier: "new-voice", rate: 0.7)
        try await coordinator.replayLast()

        // The failed "do not remember" attempt must never overwrite lastRequest: replay still
        // targets "remember me".
        XCTAssertEqual(backend.spoken.map(\.text), ["remember me", "remember me"])
        XCTAssertEqual(backend.spoken.last?.options, options)
        // By the time replayLast() runs, nothing is actually playing: "remember me" already
        // delivered its .finished terminal event (which clears the router's active playback),
        // and "do not remember" failed before ever starting. replayLast()'s router.stop() is
        // therefore a legitimate no-op here rather than reaching a stale backend.
        XCTAssertEqual(backend.stopCount, 0)
    }

    func testReplayBeforeSuccessfulSpeechDoesNothing() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let coordinator = makeCoordinator(backend: backend)

        try await coordinator.replayLast()

        XCTAssertTrue(backend.spoken.isEmpty)
        XCTAssertEqual(backend.stopCount, 0)
    }

    func testOverlayShowsPreparingSpeechBeforeBackendReportsStarted() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        guard case .preparingSpeech = overlay.state else {
            return XCTFail("Expected preparingSpeech before playback started, got \(overlay.state)")
        }

        backend.emitStarted()
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
    }

    func testAutomaticSpeechDoesNotShowPreparingSpeechBeforeStarted() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .automatic))
        XCTAssertTrue(overlay.state.isHidden)

        backend.emitStarted()
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
    }

    func testReplayLastShowsPreparingSpeechBeforeBackendReportsStarted() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        backend.emitStarted()
        backend.emit(.finished(sessionID: backend.lastSessionID!))

        try await coordinator.replayLast()
        guard case .preparingSpeech = overlay.state else {
            return XCTFail("Expected preparingSpeech before replay playback started, got \(overlay.state)")
        }

        backend.emitStarted()
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
    }

    func testStartedEventSetsOverlayBackendNameFromBackend() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        backend.emitStarted()

        XCTAssertEqual(overlay.backendName, "apple")
    }

    func testLevelEventUpdatesOverlaySpeakingLevel() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))
        backend.emit(.level(sessionID: sessionID, level: 0.8))

        guard case let .speaking(_, _, level) = overlay.state else {
            return XCTFail("Expected speaking")
        }
        XCTAssertEqual(level, 0.8)
    }

    func testStaleLevelEventForReplacedSessionIsIgnored() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .userRequested))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "second", mode: .userRequested))
        let second = backend.lastSessionID!
        backend.emit(.started(sessionID: second))

        backend.emit(.level(sessionID: first, level: 0.9))

        guard case let .speaking(sessionID, _, level) = overlay.state else {
            return XCTFail("Expected speaking")
        }
        XCTAssertEqual(sessionID, second)
        XCTAssertNil(level)
    }

    func testLateFinishFromStoppedSessionCannotHideReplacement() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .userRequested))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "second", mode: .userRequested))
        let second = backend.lastSessionID!
        backend.emit(.started(sessionID: second))
        backend.emit(.finished(sessionID: first))

        XCTAssertEqual(overlay.state.sessionID, second)
    }

    func testMatchingFinishCompletesOverlay() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let scheduler = FakeOverlayScheduler()
        let overlay = ActivityOverlayModel(scheduler: scheduler)
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))
        backend.emit(.finished(sessionID: sessionID))
        scheduler.runAll()

        XCTAssertTrue(overlay.state.isHidden)
    }

    func testMatchingFailureReportsSpeechPlaybackErrorWithoutRawText() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.failed(sessionID: sessionID))

        guard case let .error(_, category, message) = overlay.state else {
            return XCTFail("Expected error state")
        }
        XCTAssertEqual(category, .speechPlayback)
        XCTAssertEqual(message, "Speech playback failed.")
    }

    func testMatchingCancellationHidesOverlay() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))
        backend.emit(.cancelled(sessionID: sessionID))

        XCTAssertTrue(overlay.state.isHidden)
    }

    func testStaleInteractiveStopCannotStopReplacementSpeech() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .userRequested))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "second", mode: .userRequested))
        let second = backend.lastSessionID!
        backend.emit(.started(sessionID: second))

        coordinator.stop(sessionID: first)

        XCTAssertEqual(overlay.state.sessionID, second)
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
        // The only stop() delivered to the backend was the userRequested
        // replacement above; the stale stop(sessionID: first) must be a no-op.
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testMismatchedStopLeavesOverlaySpeaking() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))

        coordinator.stop(sessionID: UUID())

        XCTAssertEqual(backend.stopCount, 0)
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
    }

    func testMatchingInteractiveStopStopsRouterAndHidesOverlay() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))

        coordinator.stop(sessionID: sessionID)

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertTrue(overlay.state.isHidden)
    }

    func testUnconditionalStopCancelsActiveOverlaySession() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))

        coordinator.stop()

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertTrue(overlay.state.isHidden)
    }

    func testDuplicateTerminalEventForSameSessionDequeuesOnlyOnce() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued-a", mode: .automatic))
        try await coordinator.speak(request(text: "queued-b", mode: .automatic))

        // Two terminal events for the same session - a duplicate `.finished`, or a `.cancelled`
        // followed by a late `.finished` - must dequeue the next automatic request only once.
        backend.emit(.finished(sessionID: first))
        backend.emit(.finished(sessionID: first))
        await pumpMainActor()

        XCTAssertEqual(backend.spoken.map(\.text), ["first", "queued-a"])
    }

    func testCancelledThenLateFinishForSameSessionDequeuesOnlyOnce() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued-a", mode: .automatic))
        try await coordinator.speak(request(text: "queued-b", mode: .automatic))

        backend.emit(.cancelled(sessionID: first))
        backend.emit(.finished(sessionID: first)) // late, stale terminal for the same session
        await pumpMainActor()

        XCTAssertEqual(backend.spoken.map(\.text), ["first", "queued-a"])
    }

    func testStartFailureOnADequeuedRequestResetsBusyStateAndKeepsDraining() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        // "first" finishes, "queued" is dequeued, and its start immediately fails. TTSRouter
        // emits `.failed` synchronously before throwing, so this must still reset the busy flag.
        backend.error = SpeechBackendError.invalidInput
        backend.emit(.finished(sessionID: first))
        await pumpMainActor()
        backend.error = nil

        // A fresh automatic request must start immediately rather than queueing behind a call
        // that already failed and will never produce a terminal event of its own.
        try await coordinator.speak(request(text: "after-failure", mode: .automatic))

        XCTAssertEqual(backend.spoken.map(\.text), ["first", "after-failure"])
    }

    func testStuckInFlightSessionSelfHealsAfterStaleTimeout() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        var clock = Date(timeIntervalSince1970: 0)
        let coordinator = makeCoordinator(backend: backend, overlay: overlay, now: { clock })

        try await coordinator.speak(request(text: "wedged", mode: .automatic))
        backend.emit(.started(sessionID: backend.lastSessionID!))
        // No terminal event ever arrives for "wedged" - simulating a backend that dropped it.

        clock = clock.addingTimeInterval(60)
        try await coordinator.speak(request(text: "too-soon", mode: .automatic))
        // Still within the generous bound: enqueued, not dispatched.
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged"])

        clock = clock.addingTimeInterval(300)
        try await coordinator.speak(request(text: "self-heal", mode: .automatic))

        // Past the stale bound: the wedged session is abandoned and this request starts
        // immediately, ahead of "too-soon" (still queued behind it).
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged", "self-heal"])
    }

    private func makeCoordinator(
        backend: FakeTTSBackend,
        overlay: ActivityOverlayModel? = nil,
        options: @escaping () -> TTSOptions = { .init() },
        now: @escaping () -> Date = Date.init
    ) -> SpeechCoordinator {
        let overlay = overlay ?? ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let player = FakePlayer()
        backend.player = player
        let router = TTSRouter(
            backends: [backend.id: backend],
            backendOrder: { [backend.id] },
            player: player
        )
        return SpeechCoordinator(router: router, options: options, overlay: overlay, now: now)
    }

    private func request(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: .selection, mode: mode, sessionID: nil)
    }

    /// Lets any `Task` spawned from a synchronous playback-event callback (e.g. the speech
    /// queue's dequeue-next-on-finish) actually run before assertions inspect its effects.
    private func pumpMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }
}
