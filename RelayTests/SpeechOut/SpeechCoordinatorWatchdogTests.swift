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
        return SpeechCoordinator(
            router: router,
            options: options,
            overlay: overlay,
            watchdogTimeout: watchdogTimeout
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
