import XCTest
@testable import Relay

@MainActor
final class ActivityOverlayActionsTests: XCTestCase {
    func testCancelDictationActionReachesDictationCoordinatorWithSameSessionID() async {
        let dictation = FakeDispatchedDictationCoordinator()
        let speech = FakeDispatchedSpeechCoordinator()
        let sessionID = UUID()

        await ActivityOverlayActions.perform(.cancelDictation(sessionID: sessionID), dictation: dictation, speech: speech)

        XCTAssertEqual(dictation.cancelledSessionIDs, [sessionID])
        XCTAssertTrue(speech.stoppedSessionIDs.isEmpty)
    }

    func testStopSpeechActionReachesSpeechCoordinatorWithSameSessionID() async {
        let dictation = FakeDispatchedDictationCoordinator()
        let speech = FakeDispatchedSpeechCoordinator()
        let sessionID = UUID()

        await ActivityOverlayActions.perform(.stopSpeech(sessionID: sessionID), dictation: dictation, speech: speech)

        XCTAssertEqual(speech.stoppedSessionIDs, [sessionID])
        XCTAssertTrue(dictation.cancelledSessionIDs.isEmpty)
    }
}

@MainActor
private final class FakeDispatchedDictationCoordinator: DictationCoordinating {
    private(set) var cancelledSessionIDs: [UUID] = []
    func start() async {}
    func finish() async {}
    func cancel(sessionID: UUID) async { cancelledSessionIDs.append(sessionID) }
    func toggle() async {}
}

@MainActor
private final class FakeDispatchedSpeechCoordinator: SpeechCoordinating {
    private(set) var stoppedSessionIDs: [UUID] = []
    func speak(_ request: SpeechRequest) async throws {}
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {}
    func stop() {}
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws {}
}
