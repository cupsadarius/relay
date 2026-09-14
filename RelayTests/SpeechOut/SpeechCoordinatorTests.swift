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

    private func makeCoordinator(
        backend: FakeTTSBackend,
        options: @escaping () -> TTSOptions = { .init() }
    ) -> SpeechCoordinator {
        let router = TTSRouter(
            backends: [backend.id: backend],
            backendOrder: { [backend.id] }
        )
        return SpeechCoordinator(router: router, options: options)
    }

    private func request(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: .selection, mode: mode, sessionID: nil)
    }
}
