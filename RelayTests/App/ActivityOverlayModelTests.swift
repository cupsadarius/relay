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

    func testFailureDuringCompletionGraceIsIgnoredUntilCompletionHides() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: startedAt)
        model.complete(sessionID: session)

        model.fail(sessionID: session, category: .speechPlayback, message: "Speech playback failed.")

        XCTAssertEqual(model.state, .speaking(sessionID: session, startedAt: startedAt, level: nil))
        scheduler.run(at: 0)
        XCTAssertTrue(model.state.isHidden)
    }

    func testSupersededErrorDismissalCannotHideLaterErrorEarly() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()
        model.begin(sessionID: session)

        model.fail(sessionID: session, category: .speechPlayback, message: "First failure")
        model.fail(sessionID: session, category: .insertion, message: "Second failure")

        scheduler.run(at: 0)
        XCTAssertEqual(model.state, .error(sessionID: session, category: .insertion, message: "Second failure"))
        scheduler.run(at: 0)
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

    func testCancellingClearsInterimTextSoTheNextSessionStartsCompact() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let first = UUID()
        model.begin(sessionID: first)
        model.listen(sessionID: first)
        model.updateInterimText("a fairly long run of interim text from the first session", sessionID: first)

        model.cancel(sessionID: first)

        let second = UUID()
        model.begin(sessionID: second)
        model.listen(sessionID: second)

        guard case let .listening(sessionID, _, _, interimText) = model.state else {
            XCTFail("Expected .listening")
            return
        }
        XCTAssertEqual(sessionID, second)
        XCTAssertEqual(interimText, "")
    }

    func testUpdateSpeakingLevelSetsLevelWhileSpeakingForMatchingSession() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: startedAt)

        model.updateSpeakingLevel(0.75, sessionID: session)

        XCTAssertEqual(model.state, .speaking(sessionID: session, startedAt: startedAt, level: 0.75))
    }

    func testUpdateSpeakingLevelIsClampedToUnitInterval() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: startedAt)

        model.updateSpeakingLevel(1.6, sessionID: session)
        XCTAssertEqual(model.state, .speaking(sessionID: session, startedAt: startedAt, level: 1))
        model.updateSpeakingLevel(-1, sessionID: session)
        XCTAssertEqual(model.state, .speaking(sessionID: session, startedAt: startedAt, level: 0))
    }

    func testUpdateSpeakingLevelIgnoresStaleSession() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.speak(sessionID: session, startedAt: startedAt)

        model.updateSpeakingLevel(0.5, sessionID: UUID())

        XCTAssertEqual(model.state, .speaking(sessionID: session, startedAt: startedAt, level: nil))
    }

    func testUpdateSpeakingLevelIgnoresNonSpeakingState() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        model.begin(sessionID: session)
        model.listen(sessionID: session, startedAt: startedAt)

        model.updateSpeakingLevel(0.5, sessionID: session)

        XCTAssertEqual(model.state, .listening(sessionID: session, startedAt: startedAt, level: 0))
    }

    func testSetBackendNameOnlyAppliesToActiveSession() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        model.begin(sessionID: session)
        model.listen(sessionID: session)

        model.setBackendName("Stale Backend", sessionID: UUID())
        XCTAssertNil(model.backendName)

        model.setBackendName("Apple Speech", sessionID: session)
        XCTAssertEqual(model.backendName, "Apple Speech")
    }

    func testBackendNameIsClearedOnBegin() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        model.begin(sessionID: session)
        model.listen(sessionID: session)
        model.setBackendName("Apple Speech", sessionID: session)
        XCTAssertEqual(model.backendName, "Apple Speech")

        let nextSession = UUID()
        model.begin(sessionID: nextSession)

        XCTAssertNil(model.backendName)
    }

    func testBackendNameIsClearedWhenStateBecomesHidden() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()
        model.begin(sessionID: session)
        model.listen(sessionID: session)
        model.setBackendName("Apple Speech", sessionID: session)

        model.cancel(sessionID: session)

        XCTAssertNil(model.backendName)
    }

    func testBackendNameIsClearedWhenTheCompletionGracePeriodTimerHides() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()
        model.begin(sessionID: session)
        model.speak(sessionID: session)
        model.setBackendName("Apple System Voice", sessionID: session)

        model.complete(sessionID: session)
        XCTAssertEqual(model.backendName, "Apple System Voice")

        scheduler.run(after: .milliseconds(180))

        XCTAssertNil(model.backendName)
    }

    func testBackendNameIsClearedWhenTheErrorDismissalTimerHides() {
        let scheduler = FakeOverlayScheduler()
        let model = ActivityOverlayModel(scheduler: scheduler)
        let session = UUID()
        model.begin(sessionID: session)
        model.listen(sessionID: session)
        model.setBackendName("Apple Speech", sessionID: session)

        model.fail(sessionID: session, category: .speechPlayback, message: "Speech playback failed.")
        XCTAssertEqual(model.backendName, "Apple Speech")

        scheduler.run(after: .milliseconds(2_500))

        XCTAssertNil(model.backendName)
    }

    func testStateDerivesCancelAndStopActions() {
        let session = UUID()

        XCTAssertEqual(ActivityOverlayState.listening(sessionID: session, startedAt: .now, level: 0).action, .cancelDictation(sessionID: session))
        XCTAssertEqual(ActivityOverlayState.processing(sessionID: session, startedAt: .now).action, .cancelDictation(sessionID: session))
        XCTAssertEqual(ActivityOverlayState.speaking(sessionID: session, startedAt: .now, level: nil).action, .stopSpeech(sessionID: session))
        XCTAssertEqual(ActivityOverlayState.preparingSpeech(sessionID: session, startedAt: .now).action, .stopSpeech(sessionID: session))
        XCTAssertNil(ActivityOverlayState.hidden.action)
    }

    func testPrepareSpeakingAfterBeginSetsPreparingSpeech() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)

        model.begin(sessionID: session)
        model.prepareSpeaking(sessionID: session, startedAt: startedAt)

        XCTAssertEqual(model.state, .preparingSpeech(sessionID: session, startedAt: startedAt))
        XCTAssertFalse(model.state.isHidden)
    }

    func testPrepareSpeakingIsNoOpForNonActiveSession() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()

        model.begin(sessionID: session)
        model.prepareSpeaking(sessionID: UUID())

        XCTAssertEqual(model.state, .hidden)
    }

    func testPrepareSpeakingThenSpeakTransitionsToSpeaking() {
        let model = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
        let session = UUID()

        model.begin(sessionID: session)
        model.prepareSpeaking(sessionID: session)
        model.speak(sessionID: session)

        guard case let .speaking(sessionID, _, level) = model.state else {
            return XCTFail("Expected speaking, got \(model.state)")
        }
        XCTAssertEqual(sessionID, session)
        XCTAssertNil(level)
    }
}

/// Deterministic stand-in for `ActivityOverlayModel`'s real scheduler so
/// tests can control the completion/error grace-period timers explicitly.
/// Shared across overlay/speech test files.
@MainActor
final class FakeOverlayScheduler: ActivityOverlayScheduling {
    private var operations: [(delay: Duration, operation: @MainActor () -> Void)] = []

    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        operations.append((delay, operation))
    }

    func run(after delay: Duration) {
        let index = operations.firstIndex { $0.delay == delay }!
        run(at: index)
    }

    func run(at index: Int) {
        operations.remove(at: index).operation()
    }

    func runAll() {
        while !operations.isEmpty {
            operations.removeFirst().operation()
        }
    }
}
