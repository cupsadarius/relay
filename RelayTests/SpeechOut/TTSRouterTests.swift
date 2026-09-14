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

        try await router.speak(text: "one", options: .init())
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init())

        XCTAssertEqual(first.spoken.map(\.text), ["one"])
        XCTAssertEqual(second.spoken.map(\.text), ["two"])
    }

    func testFallsBackAfterFallbackWorthyFailure() async throws {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.inferenceFailed("boom")
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init())

        XCTAssertEqual(second.spoken.map(\.text), ["hello"])
    }

    func testStopsRoutingAfterNonFallbackError() async {
        let first = FakeTTSBackend(id: "first")
        first.error = SpeechBackendError.invalidInput
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        do {
            try await router.speak(text: "hello", options: .init())
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertTrue(second.spoken.isEmpty)
    }

    func testSkipsMissingAndUnavailableEntries() async throws {
        let unavailable = FakeTTSBackend(id: "unavailable")
        unavailable.availabilityValue = .unavailable("disabled")
        let available = FakeTTSBackend(id: "available")
        let router = TTSRouter(
            backends: ["unavailable": unavailable, "available": available],
            backendOrder: { ["missing", "unavailable", "available"] }
        )

        try await router.speak(text: "hello", options: .init())

        XCTAssertTrue(unavailable.spoken.isEmpty)
        XCTAssertEqual(available.spoken.map(\.text), ["hello"])
    }

    func testTransportControlsTargetOnlyActiveBackend() async throws {
        let first = FakeTTSBackend(id: "first")
        let second = FakeTTSBackend(id: "second")
        let router = makeRouter([first, second])

        try await router.speak(text: "hello", options: .init())
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

        try await router.speak(text: "one", options: .init())
        order = ["second", "first"]
        try await router.speak(text: "two", options: .init())
        router.stop()

        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(first.spoken.map(\.text), ["one"])
        XCTAssertEqual(second.spoken.map(\.text), ["two"])
        XCTAssertEqual(events, ["first stopped", "second spoke"])
    }

    func testAppleBackendReportsSupportedCapabilities() {
        let backend = AppleTTSBackend()

        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.pauseResume))
        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
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
    var spoken: [(text: String, options: TTSOptions)] = []
    var stopCount = 0
    var pauseCount = 0
    var resumeCount = 0
    var onSpeak: (() -> Void)?
    var onStop: (() -> Void)?

    init(id: String) {
        self.id = id
        displayName = id
    }

    func availability() async -> BackendAvailability { availabilityValue }

    func speak(text: String, options: TTSOptions) async throws {
        if let error { throw error }
        onSpeak?()
        spoken.append((text, options))
    }

    func stop() {
        stopCount += 1
        onStop?()
    }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
}
