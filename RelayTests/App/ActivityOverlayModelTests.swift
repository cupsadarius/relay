import XCTest
@testable import Relay

@MainActor
final class ActivityOverlayModelTests: XCTestCase {
    func testStaleCallbacksCannotMutateNewerSession() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let old = UUID(), new = UUID()

        model.begin(sessionID: old)
        model.listen(sessionID: old, startedAt: .distantPast)
        model.begin(sessionID: new)
        model.listen(sessionID: new, startedAt: .now)
        model.updateLevel(0.9, sessionID: old)
        model.complete(sessionID: old)

        XCTAssertEqual(model.state.sessionID, new)
    }

    func testMatchingCompletionHidesAfterGracePeriod() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()

        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: .now)
        model.complete(sessionID: session)

        XCTAssertFalse(model.state.isHidden)
        scheduler.run(after: .milliseconds(180))
        XCTAssertTrue(model.state.isHidden)
    }

    func testOldErrorDismissalCannotHideNewActivity() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let old = UUID(), new = UUID()

        model.begin(sessionID: old)
        model.fail(sessionID: old, category: .speechPlayback, message: "Speech playback failed.")
        model.begin(sessionID: new)
        model.listen(sessionID: new, startedAt: .now)
        scheduler.run(after: .milliseconds(2_500))

        XCTAssertEqual(model.state.sessionID, new)
    }

    func testLateFailureCannotResurrectCompletedSession() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()

        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: .now)
        model.complete(sessionID: session)
        scheduler.run(after: .milliseconds(180))
        model.fail(sessionID: session, category: .speechPlayback, message: "Speech playback failed.")

        XCTAssertTrue(model.state.isHidden)
    }

    func testListeningLevelIsClampedToUnitInterval() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.listen(sessionID: session, startedAt: startedAt)

        model.updateLevel(1.4, sessionID: session)
        XCTAssertEqual(model.state, .listening(sessionID: session, startedAt: startedAt, level: 1))
        model.updateLevel(-0.2, sessionID: session)
        XCTAssertEqual(model.state, .listening(sessionID: session, startedAt: startedAt, level: 0))
    }

    func testProcessingRetainsListeningStartTime() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.listen(sessionID: session, startedAt: startedAt)

        model.process(sessionID: session)

        XCTAssertEqual(model.state, .processing(sessionID: session, startedAt: startedAt))
    }

    func testMatchingCancellationHidesActivity() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        model.begin(sessionID: session)
        model.listen(sessionID: session)

        model.cancel(sessionID: session)

        XCTAssertTrue(model.state.isHidden)
    }

    func testStateDerivesCancelAndStopActions() {
        let session = UUID()

        XCTAssertEqual(ActivityOverlayState.listening(sessionID: session, startedAt: .now, level: 0).action, .cancelDictation(sessionID: session))
        XCTAssertEqual(ActivityOverlayState.processing(sessionID: session, startedAt: .now).action, .cancelDictation(sessionID: session))
        XCTAssertEqual(ActivityOverlayState.speaking(sessionID: session, startedAt: .now).action, .stopSpeech(sessionID: session))
        XCTAssertNil(ActivityOverlayState.hidden.action)
    }
}

@MainActor
private final class FakeOverlayScheduler: ActivityOverlayScheduling {
    private var operations: [(delay: Duration, operation: @MainActor () -> Void)] = []

    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        operations.append((delay, operation))
    }

    func run(after delay: Duration) {
        let index = operations.firstIndex { $0.delay == delay }!
        operations.remove(at: index).operation()
    }
}
