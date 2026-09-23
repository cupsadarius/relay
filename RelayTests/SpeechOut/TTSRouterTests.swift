import XCTest

@testable import Relay

@MainActor
final class TTSRouterTests: XCTestCase {
    // MARK: Backend selection and fallback (before audible start)

    func testUsesCurrentBackendOrderForEveryRequest() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        let player = FakePlayer()
        var order = ["first", "second"]
        let router = makeRouter([first, second], player: player, order: { order })

        try await router.speak(text: "one", options: .init(), sessionID: UUID())
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init(), sessionID: UUID())

        XCTAssertEqual(first.spoken.map(\.text), ["one"])
        XCTAssertEqual(second.spoken.map(\.text), ["two"])
    }

    func testMakeAudioSourceFailureFallsThrough() async throws {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertTrue(first.spoken.isEmpty)
        XCTAssertEqual(second.spoken.map(\.text), ["hello"])
    }

    func testPreferredBackendUsesOnlyThatBackendWithoutFallback() async {
        let first = FakeTTSBackend(id: "first")
        let preferred = FakeTTSBackend(id: "preferred")
        preferred.error = SpeechBackendError.inferenceFailed("boom")
        let router = makeRouter([first, preferred])

        do {
            try await router.speak(
                text: "preview",
                options: .init(kokoroVoice: "am_adam"),
                sessionID: UUID(),
                preferredBackendID: "preferred"
            )
            XCTFail("Expected preferred backend failure")
        } catch {}

        XCTAssertTrue(first.spoken.isEmpty)
        XCTAssertTrue(preferred.spoken.isEmpty)
    }

    func testNewRequestSupersedesOlderRequestStillCreatingItsSource() async throws {
        let slow = FakeTTSBackend(id: "slow")
        slow.suspendSourceCreation = true
        let fast = FakeTTSBackend(id: "fast")
        let player = FakePlayer()
        let router = makeRouter([slow, fast], player: player)

        let older = Task {
            try await router.speak(
                text: "older",
                options: .init(),
                sessionID: UUID(),
                preferredBackendID: slow.id
            )
        }
        await waitUntil { slow.isSourceCreationSuspended }

        try await router.speak(
            text: "newer",
            options: .init(),
            sessionID: UUID(),
            preferredBackendID: fast.id
        )
        slow.resumeSourceCreation()

        do {
            try await older.value
            XCTFail("Expected superseded request cancellation")
        } catch is CancellationError {}

        XCTAssertTrue(slow.spoken.isEmpty)
        XCTAssertEqual(fast.spoken.map(\.text), ["newer"])
    }

    func testUnavailableBackendIsSkipped() async throws {
        let first = FakeTTSBackend(id: "first")
        first.availabilityValue = .modelNotDownloaded
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertTrue(first.spoken.isEmpty)
        XCTAssertEqual(second.spoken.map(\.text), ["hello"])
    }

    func testNonFallbackWorthyMakeAudioSourceErrorStopsRouting() async {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.invalidInput
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        do {
            try await router.speak(text: "hello", options: .init(), sessionID: UUID())
            XCTFail("Expected invalidInput to propagate without fallback")
        } catch let error as SpeechBackendError {
            XCTAssertEqual(error, .invalidInput)
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(second.spoken.isEmpty)
    }

    func testPreStartPlayerFailureFallsThrough() async throws {
        // The first backend produces a source, but the shared player fails BEFORE `.started`.
        // That is safe to treat as fallback-worthy, so the second backend takes over.
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        let player = FakePlayer()
        player.failNextStart = SpeechBackendError.inferenceFailed("player boom")
        let router = makeRouter([first, second], player: player)

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        // The first source was produced and cancelled; the second backend's source played.
        XCTAssertEqual(player.started.count, 2)
        XCTAssertEqual(second.spoken.map(\.text), ["hello"])
    }

    // MARK: Commit-on-started

    func testFirstStartedCommitsBackend() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let player = FakePlayer()
        let router = makeRouter([backend], player: player)

        var startedBackendIDs: [String?] = []
        router.setPlaybackEventHandler { event, backend in
            if case .started = event { startedBackendIDs.append(backend?.id) }
        }

        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        player.fireEvent(.started(sessionID: sessionID))

        XCTAssertEqual(startedBackendIDs, ["apple"])
    }

    func testStartedEventReportsCommittedBackendIdentity() async throws {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        let player = FakePlayer()
        let router = makeRouter([first, second], player: player)

        var identities: [String?] = []
        router.setPlaybackEventHandler { event, backend in
            switch event {
            case .started, .level, .finished:
                identities.append(backend?.id)
            default:
                break
            }
        }

        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        player.fireEvent(.started(sessionID: sessionID))
        player.fireEvent(.finished(sessionID: sessionID))

        // The fell-through first backend never appears; the committed second backend owns every
        // player-sourced event.
        XCTAssertEqual(identities, ["second", "second"])
    }

    func testPostStartFailureDoesNotFallThrough() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        let player = FakePlayer()
        let router = makeRouter([first, second], player: player)

        var terminalBackendIDs: [String?] = []
        router.setPlaybackEventHandler { event, backend in
            if case .failed = event { terminalBackendIDs.append(backend?.id) }
        }

        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        // Commit the first backend, then fail it. The router must NOT restart on the second.
        player.fireEvent(.started(sessionID: sessionID))
        player.fireEvent(.failed(sessionID: sessionID))

        XCTAssertEqual(first.spoken.map(\.text), ["hello"])
        XCTAssertTrue(second.spoken.isEmpty)
        XCTAssertEqual(terminalBackendIDs, ["first"])
    }

    // MARK: Stop / pause / resume delegate to the shared player

    func testStopCancelsPlayer() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let player = FakePlayer()
        let router = makeRouter([backend], player: player)

        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        router.stop()

        XCTAssertEqual(player.stopCount, 1)
    }

    func testSessionSpecificStopIgnoresStaleID() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let player = FakePlayer()
        let router = makeRouter([backend], player: player)

        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        player.fireEvent(.started(sessionID: sessionID))

        let didStopStale = router.stop(sessionID: UUID())
        XCTAssertFalse(didStopStale)
        XCTAssertEqual(player.stopCount, 0)

        let didStopMatching = router.stop(sessionID: sessionID)
        XCTAssertTrue(didStopMatching)
        XCTAssertEqual(player.stopCount, 1)
    }

    func testSessionSpecificStopDuringSourcePreparationCancelsTheRequest() async throws {
        let slow = FakeTTSBackend(id: "slow")
        slow.suspendSourceCreation = true
        let player = FakePlayer()
        let router = makeRouter([slow], player: player)
        let sessionID = UUID()

        let speaking = Task {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        }
        await waitUntil { slow.isSourceCreationSuspended }

        XCTAssertTrue(router.stop(sessionID: sessionID), "a stop for the session being prepared must match it")
        slow.resumeSourceCreation()

        do {
            try await speaking.value
            XCTFail("Expected the stopped request to be cancelled")
        } catch is CancellationError {}
        XCTAssertTrue(player.started.isEmpty, "a stopped request must never reach the player")
    }

    func testSessionSpecificStopDuringPreparationIgnoresOtherSessionIDs() async throws {
        let slow = FakeTTSBackend(id: "slow")
        slow.suspendSourceCreation = true
        let player = FakePlayer()
        let router = makeRouter([slow], player: player)
        let sessionID = UUID()

        let speaking = Task {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        }
        await waitUntil { slow.isSourceCreationSuspended }

        XCTAssertFalse(router.stop(sessionID: UUID()))
        slow.resumeSourceCreation()

        try await speaking.value
        XCTAssertEqual(player.started.count, 1)
    }

    func testRoutingSessionIsForgottenOnceRoutingFails() async {
        let backend = FakeTTSBackend(id: "only")
        backend.error = SpeechBackendError.invalidInput
        let router = makeRouter([backend])
        let sessionID = UUID()

        do {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected invalidInput")
        } catch {}

        XCTAssertFalse(router.stop(sessionID: sessionID))
    }

    // MARK: Helpers

    private func makeRouter(
        _ backends: [FakeTTSBackend],
        player: FakePlayer? = nil,
        order: (() -> [String])? = nil
    ) -> TTSRouter {
        let player = player ?? FakePlayer()
        backends.forEach { $0.player = player }
        let ids = backends.map(\.id)
        return TTSRouter(
            backends: Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) }),
            backendOrder: order ?? { ids },
            player: player
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

// MARK: - Shared TTS test fakes

/// Trivial pull-based source that carries the request that produced it (and the backend that
/// produced it), so the fake player can record exactly what each backend dispatched.
final class FakeTTSAudioSource: TTSAudioSource, @unchecked Sendable {
    let backendID: String
    let text: String
    let options: TTSOptions
    private(set) var cancelled = false

    init(backendID: String, text: String, options: TTSOptions) {
        self.backendID = backendID
        self.text = text
        self.options = options
    }

    func next() async throws -> TTSAudioFrame? { nil }
    func cancel() async { cancelled = true }
}

/// Stand-in for the single shared `StreamingAudioPlayer`. It records what it was asked to play and
/// lets tests drive lifecycle events, control pre-`.started` failures, and simulate a streaming
/// player whose `startPlayback` only returns once stopped.
@MainActor
final class FakePlayer: StreamingAudioPlaying {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    private(set) var started: [(source: any TTSAudioSource, sessionID: UUID)] = []
    private(set) var stopCount = 0

    /// Thrown from the next `startPlayback`, simulating a pre-`.started` player failure.
    var failNextStart: Error?
    /// Invoked synchronously inside `startPlayback`, after the session is recorded, with the session
    /// being played - lets tests drive lifecycle events (e.g. `.started`/`.finished`) mid-call.
    var duringStart: (@MainActor (UUID) -> Void)?
    /// When true, `startPlayback` suspends until `stop()` resumes it, mirroring the real player's
    /// streaming completion continuation.
    var suspendUntilStopped = false
    /// Invoked synchronously inside `stop()` (only when something is playing), before it returns -
    /// lets tests simulate a player whose stop reentrantly emits a synchronous terminal event.
    var onStop: (@MainActor () -> Void)?

    /// The session currently being played, cleared on a terminal event or an effective `stop()`.
    /// Modelled so `stop()` is a no-op (as on the real idle player) when nothing is playing.
    private var activeSessionID: UUID?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    var lastSessionID: UUID? { started.last?.sessionID }

    /// What each backend dispatched, in play order, for tests that read via the backend proxy.
    var spoken: [(backendID: String, text: String, options: TTSOptions, sessionID: UUID)] {
        started.compactMap { entry in
            (entry.source as? FakeTTSAudioSource).map {
                ($0.backendID, $0.text, $0.options, entry.sessionID)
            }
        }
    }

    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws {
        started.append((source, sessionID))
        if let failNextStart {
            self.failNextStart = nil
            throw failNextStart
        }
        activeSessionID = sessionID
        duringStart?(sessionID)
        if suspendUntilStopped {
            await withCheckedContinuation { stopContinuation = $0 }
        }
    }

    func stop() {
        guard activeSessionID != nil else { return }
        activeSessionID = nil
        stopCount += 1
        onStop?()
        if let stopContinuation {
            self.stopContinuation = nil
            stopContinuation.resume()
        }
    }

    /// Fires a lifecycle event through the router's installed handler, updating the fake's own
    /// active-session tracking so a subsequent idle `stop()` correctly no-ops.
    func fireEvent(_ event: TTSPlaybackEvent) {
        switch event {
        case .finished, .cancelled, .failed:
            if activeSessionID == event.sessionID { activeSessionID = nil }
        default:
            break
        }
        onEvent?(event)
    }
}

/// A pure audio-producer backend. `makeAudioSource` records nothing itself (it has no session ID);
/// the shared `FakePlayer` is the single source of truth for what played. Playback state and event
/// injection are exposed here as proxies so characterization tests can keep reading and driving via
/// the backend, exactly as they did when backends owned playback.
@MainActor
final class FakeTTSBackend: TextToSpeechBackend {
    let id: String
    let displayName: String
    var availabilityValue: BackendAvailability = .available
    /// Thrown from `makeAudioSource`.
    var error: Error?
    var suspendSourceCreation = false
    private(set) var isSourceCreationSuspended = false
    private var sourceCreationContinuation: CheckedContinuation<Void, Never>?
    /// The router's shared player; set by the test helper before the router is used.
    var player: FakePlayer!

    init(id: String) {
        self.id = id
        displayName = id
    }

    func availability() async -> BackendAvailability { availabilityValue }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        if let error { throw error }
        if suspendSourceCreation {
            isSourceCreationSuspended = true
            await withCheckedContinuation { sourceCreationContinuation = $0 }
            isSourceCreationSuspended = false
        }
        return FakeTTSAudioSource(backendID: id, text: text, options: options)
    }

    func resumeSourceCreation() {
        sourceCreationContinuation?.resume()
        sourceCreationContinuation = nil
    }

    // MARK: Playback proxies (this backend's slice of the shared player's state)

    var spoken: [(text: String, options: TTSOptions, sessionID: UUID)] {
        player.spoken.filter { $0.backendID == id }.map { ($0.text, $0.options, $0.sessionID) }
    }

    var lastSessionID: UUID? {
        player.spoken.last { $0.backendID == id }?.sessionID
    }

    var stopCount: Int { player.stopCount }

    var duringSpeak: (@MainActor (UUID) -> Void)? {
        get { player.duringStart }
        set { player.duringStart = newValue }
    }

    var onStop: (@MainActor () -> Void)? {
        get { player.onStop }
        set { player.onStop = newValue }
    }

    var suspendUntilStopped: Bool {
        get { player.suspendUntilStopped }
        set { player.suspendUntilStopped = newValue }
    }

    func emit(_ event: TTSPlaybackEvent) { player.fireEvent(event) }

    func emitStarted() {
        guard let lastSessionID else { return }
        emit(.started(sessionID: lastSessionID))
    }
}
