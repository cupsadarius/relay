import XCTest
@testable import Relay

@MainActor
final class ActivityOverlayActionDispatcherTests: XCTestCase {
    func testCancelDictationActionReachesDictationCoordinatorWithSameSessionID() async {
        let dictation = FakeDispatchedDictationCoordinator()
        let speech = FakeDispatchedSpeechCoordinator()
        let dispatcher = ActivityOverlayActionDispatcher(dictation: dictation, speech: speech)
        let sessionID = UUID()

        dispatcher.perform(.cancelDictation(sessionID: sessionID))
        await Task.yield()

        XCTAssertEqual(dictation.cancelledSessionIDs, [sessionID])
        XCTAssertTrue(speech.stoppedSessionIDs.isEmpty)
    }

    func testStopSpeechActionReachesSpeechCoordinatorWithSameSessionID() {
        let dictation = FakeDispatchedDictationCoordinator()
        let speech = FakeDispatchedSpeechCoordinator()
        let dispatcher = ActivityOverlayActionDispatcher(dictation: dictation, speech: speech)
        let sessionID = UUID()

        dispatcher.perform(.stopSpeech(sessionID: sessionID))

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
    func stop() {}
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws {}
}
