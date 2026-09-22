import XCTest
@testable import Relay

/// Covers the independent playback watchdog: a defense-in-depth timer started the moment a
/// session is handed to the router, which self-heals a wedged session (one whose backend never
/// delivers a terminal event) without requiring any further request to arrive. See
/// `SpeechCoordinator`'s `staleInFlightTimeout`/`isInFlightSessionStale()` doc comments for the
/// older, request-driven self-heal this backstops.
@MainActor
final class SpeechCoordinatorWatchdogTests: XCTestCase {
    /// Real wall-clock timeout used across these tests - short enough to keep the suite fast,
    /// long enough to keep it non-flaky on CI.
    private let watchdogTimeout: TimeInterval = 0.05

    func testWedgedSessionSelfHealsWithNoNewRequest() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "wedged", mode: .automatic))
        let wedged = backend.lastSessionID!
        backend.emit(.started(sessionID: wedged))
        // No terminal event is ever emitted for "wedged" - simulating a backend that silently
        // dropped it. Queue a second automatic request behind it.
        try await coordinator.speak(request(text: "queued", mode: .automatic))
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged"])

        // Unlike "wedged", let whatever the queue drains next finish normally - this test is
        // only about the watchdog recovering the ORIGINAL wedged session on its own, not about
        // a second independent wedge.
        backend.duringSpeak = { sessionID in
            backend.emit(.started(sessionID: sessionID))
            backend.emit(.finished(sessionID: sessionID))
        }

        await waitPastWatchdog()

        // The watchdog fires on its own - no new request is needed - stopping the backend and
        // draining the queue.
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged", "queued"])
    }

    func testTerminalEventCancelsWatchdog() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let scheduler = FakeOverlayScheduler()
        let overlay = ActivityOverlayModel(scheduler: scheduler)
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "first", mode: .automatic))
        let first = backend.lastSessionID!
        backend.emit(.started(sessionID: first))
        backend.emit(.finished(sessionID: first))
        await pumpMainActor()
        scheduler.runAll()

        XCTAssertTrue(overlay.state.isHidden)

        await waitPastWatchdog()

        // The watchdog must never fire for a session that already finished normally: no
        // spurious stop(), and no error state clobbering the already-hidden overlay.
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertTrue(overlay.state.isHidden)
    }

    func testPlaybackProgressExtendsWatchdogDeadline() async throws {
        let timeout: TimeInterval = 0.2
        let backend = FakeTTSBackend(id: "kokoro")
        let coordinator = makeCoordinator(backend: backend, watchdogTimeout: timeout)

        try await coordinator.speak(request(text: "long-form", mode: .automatic))
        let sessionID = backend.lastSessionID!
        backend.emit(.started(sessionID: sessionID))

        // Progress arrives before the original deadline. Wait until after that original deadline,
        // but before a fresh inactivity deadline measured from this progress event.
        try await Task.sleep(nanoseconds: 120_000_000)
        backend.emit(.level(sessionID: sessionID, level: 0.5))
        try await Task.sleep(nanoseconds: 120_000_000)
        await pumpMainActor()

        XCTAssertEqual(backend.stopCount, 0)

        // Retire the session normally so no watchdog task survives the test.
        backend.emit(.finished(sessionID: sessionID))
    }

    func testWatchdogDoesNotDoubleFire() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "wedged", mode: .automatic))
        let wedged = backend.lastSessionID!
        backend.emit(.started(sessionID: wedged))

        await waitPastWatchdog()
        XCTAssertEqual(backend.stopCount, 1)

        // A late terminal event for the session the watchdog already gave up on must be a
        // no-op: it must not trigger a second stop, a second `.failed`, or dequeue twice.
        backend.emit(.finished(sessionID: wedged))
        await pumpMainActor()

        XCTAssertEqual(backend.stopCount, 1)

        // Queue continues normally afterwards: a fresh request starts immediately.
        try await coordinator.speak(request(text: "after", mode: .automatic))
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged", "after"])
    }

    /// Regression test: on some backends (`StreamingAudioPlayer`/`PocketTTS`), `stop()` emits its
    /// terminal event SYNCHRONOUSLY and reentrantly, from inside `stop()` itself, before it
    /// returns - unlike AppleTTS, whose delegate callback arrives later, asynchronously. If the
    /// watchdog called `router.stop()` before retiring its own session tracking, that reentrant
    /// `.cancelled` would race ahead of the watchdog's own `.failed` report: it clears the
    /// overlay's active session (silently no-oping the subsequent `overlay.fail(...)`) and
    /// dequeues the next automatic request itself (so the watchdog's own drain would double it).
    /// The user-visible outcome must be `.failed`, not a silently-swallowed `.cancelled`, on every
    /// backend regardless of whether its `stop()` reports synchronously or asynchronously.
    func testWatchdogSurfacesFailedWhenBackendStopEmitsSynchronousTerminal() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let coordinator = makeCoordinator(backend: backend, overlay: overlay)

        try await coordinator.speak(request(text: "wedged", mode: .automatic))
        let wedged = backend.lastSessionID!
        backend.emit(.started(sessionID: wedged))
        // Queue a second automatic request behind the wedged one, to prove the watchdog's own
        // drain fires exactly once even with a reentrant terminal in the mix.
        try await coordinator.speak(request(text: "queued", mode: .automatic))

        // Simulate a synchronous-terminal backend: stop() reentrantly emits `.cancelled` for the
        // session being stopped, before returning.
        backend.onStop = { backend.emit(.cancelled(sessionID: wedged)) }

        // Wait for exactly one watchdog cycle: long enough for "wedged"'s timer to fire and the
        // queue to drain, but short of the freshly-dequeued "queued" session's OWN watchdog (it
        // never receives a terminal event here either, so it must not be allowed to also expire
        // within this wait - that would be a second, unrelated recovery muddying the assertions).
        try await Task.sleep(nanoseconds: UInt64(watchdogTimeout * 1.5 * 1_000_000_000))
        await pumpMainActor()

        // Exactly one stop, exactly one dequeue ("queued" reached the backend - proof isSpeaking
        // was actually cleared to false by the watchdog rather than left wedged).
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.spoken.map(\.text), ["wedged", "queued"])

        // The user-visible outcome is the watchdog's own `.failed`, not the reentrant backend's
        // `.cancelled` racing ahead of it and clearing the overlay first.
        guard case let .error(sessionID, category, _) = overlay.state else {
            return XCTFail("Expected overlay to end on .failed, got \(overlay.state)")
        }
        XCTAssertEqual(sessionID, wedged)
        XCTAssertEqual(category, .speechPlayback)
    }

    private func makeCoordinator(
        backend: FakeTTSBackend,
        overlay: ActivityOverlayModel? = nil,
        options: @escaping () -> TTSOptions = { .init() },
        watchdogTimeout: TimeInterval? = nil
    ) -> SpeechCoordinator {
        let overlay = overlay ?? ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let player = FakePlayer()
        backend.player = player
        let router = TTSRouter(
            backends: [backend.id: backend],
            backendOrder: { [backend.id] },
            player: player
        )
        return SpeechCoordinator(
            router: router,
            options: options,
            overlay: overlay,
            watchdogTimeout: watchdogTimeout ?? self.watchdogTimeout
        )
    }

    private func request(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: .selection, mode: mode, sessionID: nil)
    }

    /// Sleeps past the injected watchdog timeout with margin, then lets any `Task` the watchdog
    /// spawned on expiry actually run.
    private func waitPastWatchdog() async {
        try? await Task.sleep(nanoseconds: UInt64(watchdogTimeout * 4 * 1_000_000_000))
        await pumpMainActor()
    }

    private func pumpMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }
}
