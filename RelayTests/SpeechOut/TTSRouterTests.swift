import XCTest
@testable import Relay

@MainActor
final class TTSRouterTests: XCTestCase {
    func testUsesCurrentBackendOrderForEveryRequest() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        var order = ["first", "second"]
        let router = TTSRouter(
            backends: ["first": first, "second": second],
            backendOrder: { order }
        )

        try await router.speak(text: "one", options: .init(), sessionID: UUID())
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init(), sessionID: UUID())

        XCTAssertEqual(first.spoken.map(\.text), ["one"])
        XCTAssertEqual(second.spoken.map(\.text), ["two"])
    }

    func testFallsBackAfterFallbackWorthyFailure() async throws {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(second.spoken.map(\.text), ["hello"])
    }

    func testStopsRoutingAfterNonFallbackError() async {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.invalidInput
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        do {
            try await router.speak(text: "hello", options: .init(), sessionID: UUID())
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertTrue(second.spoken.isEmpty)
    }

    func testNonFallbackErrorEmitsFailedEventWithoutErrorText() async {
        let backend = FakeTTSBackend(id: "apple")
        backend.error = SpeechBackendError.invalidInput
        let router = makeRouter([backend])
        var events: [TTSPlaybackEvent] = []
        router.setPlaybackEventHandler { event, _ in events.append(event) }
        let sessionID = UUID()

        _ = try? await router.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(events, [.failed(sessionID: sessionID)])
    }

    func testExhaustingAllFallbackCandidatesEmitsFailedEvent() async {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        second.error = SpeechBackendError.inferenceFailed("boom again")
        let router = makeRouter([first, second])
        var events: [TTSPlaybackEvent] = []
        router.setPlaybackEventHandler { event, _ in events.append(event) }
        let sessionID = UUID()

        do {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected failure")
        } catch {
            // expected
        }

        XCTAssertEqual(events, [.failed(sessionID: sessionID)])
    }

    func testSkipsMissingAndUnavailableEntries() async throws {
        let unavailable = FakeTTSBackend(id: "unavailable")
        unavailable.availabilityValue = .unavailable("disabled")
        let available = FakeTTSBackend(id: "available")
        let router = TTSRouter(
            backends: ["unavailable": unavailable, "available": available],
            backendOrder: { ["missing", "unavailable", "available"] }
        )

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertTrue(unavailable.spoken.isEmpty)
        XCTAssertEqual(available.spoken.map(\.text), ["hello"])
    }

    func testTransportControlsTargetOnlyActiveBackend() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init(), sessionID: UUID())
        router.pause()
        router.resume()
        router.stop()
        router.pause()
        router.resume()

        XCTAssertEqual(first.pauseCount, 1)
        XCTAssertEqual(first.resumeCount, 1)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.pauseCount, 0)
        XCTAssertEqual(second.resumeCount, 0)
        XCTAssertEqual(second.stopCount, 0)
    }

    func testSwitchingBackendsStopsThePreviouslyActiveBackend() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        var events: [String] = []
        first.onStop = { events.append("first stopped") }
        second.onSpeak = { events.append("second spoke") }
        var order = ["first", "second"]
        let router = TTSRouter(
            backends: ["first": first, "second": second],
            backendOrder: { order }
        )

        try await router.speak(text: "one", options: .init(), sessionID: UUID())
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init(), sessionID: UUID())
        router.stop()

        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(first.spoken.map(\.text), ["one"])
        XCTAssertEqual(second.spoken.map(\.text), ["two"])
        XCTAssertEqual(events, ["first stopped", "second spoke"])
    }

    func testStopWithSessionIDNoOpsForStaleSession() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let router = makeRouter([backend])
        try await router.speak(text: "hello", options: .init(), sessionID: UUID())

        router.stop(sessionID: UUID())

        XCTAssertEqual(backend.stopCount, 0)
    }

    func testStopWithSessionIDStopsMatchingSession() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let router = makeRouter([backend])
        let sessionID = UUID()
        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)

        router.stop(sessionID: sessionID)

        XCTAssertEqual(backend.stopCount, 1)
    }

    func testOnlyActiveBackendAndSessionEventsAreForwarded() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        var order = ["first", "second"]
        let router = TTSRouter(
            backends: ["first": first, "second": second],
            backendOrder: { order }
        )
        var events: [TTSPlaybackEvent] = []
        router.setPlaybackEventHandler { event, _ in events.append(event) }

        try await router.speak(text: "one", options: .init(), sessionID: UUID())
        let firstSessionID = first.lastSessionID!
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init(), sessionID: UUID())
        let secondSessionID = second.lastSessionID!

        first.emit(.started(sessionID: firstSessionID))
        second.emit(.started(sessionID: secondSessionID))

        XCTAssertEqual(events, [.started(sessionID: secondSessionID)])
    }

    func testEventsEmittedSynchronouslyDuringSpeakAreForwarded() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let router = makeRouter([backend])
        var events: [TTSPlaybackEvent] = []
        router.setPlaybackEventHandler { event, _ in events.append(event) }
        let sessionID = UUID()
        backend.duringSpeak = { sessionID in
            backend.emit(.scheduled(sessionID: sessionID))
            backend.emit(.started(sessionID: sessionID))
        }

        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(events, [.scheduled(sessionID: sessionID), .started(sessionID: sessionID)])
    }

    func testEventEmittedAfterSuspensionDuringSpeakIsForwarded() async throws {
        let backend = FakeTTSBackend(id: "apple")
        backend.yieldBeforeEmitting = true
        let router = makeRouter([backend])
        var events: [TTSPlaybackEvent] = []
        router.setPlaybackEventHandler { event, _ in events.append(event) }
        let sessionID = UUID()
        backend.duringSpeak = { sessionID in
            backend.emit(.started(sessionID: sessionID))
        }

        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(events, [.started(sessionID: sessionID)])
    }

    func testForwardedEventsIncludeTheEmittingBackend() async throws {
        let backend = FakeTTSBackend(id: "apple")
        let router = makeRouter([backend])
        var receivedBackendIDs: [String?] = []
        router.setPlaybackEventHandler { _, receivedBackend in
            receivedBackendIDs.append((receivedBackend as? FakeTTSBackend)?.id)
        }
        let sessionID = UUID()

        try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        backend.emit(.started(sessionID: sessionID))

        XCTAssertEqual(receivedBackendIDs, ["apple"])
    }

    func testNonFallbackFailureCarriesNilBackend() async {
        let backend = FakeTTSBackend(id: "apple")
        backend.error = SpeechBackendError.invalidInput
        let router = makeRouter([backend])
        var receivedBackends: [(any TextToSpeechBackend)?] = []
        router.setPlaybackEventHandler { _, receivedBackend in
            receivedBackends.append(receivedBackend)
        }

        _ = try? await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(receivedBackends.count, 1)
        XCTAssertNil(receivedBackends[0])
    }

    func testExhaustedFallbackFailureCarriesNilBackend() async {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        second.error = SpeechBackendError.inferenceFailed("boom again")
        let router = makeRouter([first, second])
        var receivedBackends: [(any TextToSpeechBackend)?] = []
        router.setPlaybackEventHandler { _, receivedBackend in
            receivedBackends.append(receivedBackend)
        }

        _ = try? await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(receivedBackends.count, 1)
        XCTAssertNil(receivedBackends[0])
    }

    func testFailureWithNoAvailableBackendPassesNilBackend() async {
        let unavailable = FakeTTSBackend(id: "unavailable")
        unavailable.availabilityValue = .unavailable("disabled")
        let router = makeRouter([unavailable])
        var receivedBackends: [(any TextToSpeechBackend)?] = []
        router.setPlaybackEventHandler { _, receivedBackend in
            receivedBackends.append(receivedBackend)
        }

        _ = try? await router.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(receivedBackends.count, 1)
        XCTAssertNil(receivedBackends[0])
    }

    private func makeRouter(_ backends: [FakeTTSBackend]) -> TTSRouter {
        TTSRouter(
            backends: Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) }),
            backendOrder: { backends.map(\.id) }
        )
    }
}

@MainActor
final class FakeTTSBackend: TextToSpeechBackend {
    let id: String
    let displayName: String
    let capabilities = TTSCapabilities([])
    var availabilityValue: BackendAvailability = .available
    var error: Error?
    var spoken: [(text: String, options: TTSOptions, sessionID: UUID)] = []
    var stopCount = 0
    var pauseCount = 0
    var resumeCount = 0
    var onSpeak: (() -> Void)?
    var onStop: (() -> Void)?
    /// Called from inside `speak`, after any configured suspension, with the
    /// session ID being routed - lets tests emit events before `speak`
    /// returns to exercise the router's mid-call event forwarding.
    var duringSpeak: (@MainActor (UUID) -> Void)?
    /// When true, `speak` suspends (`Task.yield()`) before invoking
    /// `duringSpeak`, so tests can prove events survive an actor suspension.
    var yieldBeforeEmitting = false
    private(set) var lastSessionID: UUID?
    private var playbackEventHandler: (@MainActor (TTSPlaybackEvent) -> Void)?

    init(id: String) {
        self.id = id
        displayName = id
    }

    func availability() async -> BackendAvailability { availabilityValue }

    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void) {
        playbackEventHandler = handler
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        lastSessionID = sessionID
        if let error { throw error }
        if yieldBeforeEmitting { await Task.yield() }
        duringSpeak?(sessionID)
        onSpeak?()
        spoken.append((text, options, sessionID))
    }

    func stop() {
        stopCount += 1
        onStop?()
    }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    /// Test helper: manually fires a playback event as if it came from the
    /// underlying real backend.
    func emit(_ event: TTSPlaybackEvent) {
        playbackEventHandler?(event)
    }

    func emitStarted() {
        guard let lastSessionID else { return }
        emit(.started(sessionID: lastSessionID))
    }
}
