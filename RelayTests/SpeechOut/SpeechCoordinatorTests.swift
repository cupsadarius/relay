import XCTest
@testable import Relay

@MainActor
final class SpeechCoordinatorTests: XCTestCase {
    func testUserRequestedSpeechReplacesActiveSpeech() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let coordinator = makeCoordinator(backend: backend)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        try await coordinator.speak(request(text: "second", mode: .userRequested))

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.spoken.map(\.text), ["first", "second"])
    }

    func testAutomaticSpeechDoesNotReplaceActiveSpeech() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let coordinator = makeCoordinator(backend: backend)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        try await coordinator.speak(request(text: "second", mode: .automatic))

        XCTAssertEqual(backend.stopCount, 0)
    }

    func testReplayUsesLastSuccessfulRequestAndCurrentOptions() async throws {
        let backend = FakeTTSBackend(id: "apple")
        var options = TTSOptions(voiceIdentifier: "first-voice", rate: 0.4)
        let coordinator = makeCoordinator(backend: backend, options: { options })

        try await coordinator.speak(request(text: "remember me", mode: .automatic))
        backend.error = SpeechBackendError.invalidInput
        try? await coordinator.speak(request(text: "do not remember", mode: .automatic))
        backend.error = nil
        options = TTSOptions(voiceIdentifier: "new-voice", rate: 0.7)
        try await coordinator.replayLast()

        XCTAssertEqual(backend.spoken.map(\.text), ["remember me", "remember me"])
        XCTAssertEqual(backend.spoken.last?.options, options)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testReplayBeforeSuccessfulSpeechDoesNothing() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let coordinator = makeCoordinator(backend: backend)

        try await coordinator.replayLast()

        XCTAssertTrue(backend.spoken.isEmpty)
        XCTAssertEqual(backend.stopCount, 0)
    }

    func testOverlayStartsOnlyWhenBackendReportsStarted() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "hello", mode: .userRequested))
        XCTAssertTrue(overlay.state.isHidden)

        backend.emitStarted()
        guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
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

    private func makeCoordinator(
        backend: FakeTTSBackend,
        overlay: ActivityOverlayModel? = nil,
        options: @escaping () -> TTSOptions = { .init() }
    ) -> SpeechCoordinator {
        let overlay = overlay ?? ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let router = TTSRouter(
            backends: [backend.id: backend],
            backendOrder: { [backend.id] }
        )
        return SpeechCoordinator(router: router, options: options, overlay: overlay)
    }

    private func request(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: .selection, mode: mode, sessionID: nil)
    }
}
