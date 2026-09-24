import XCTest

@testable import Relay

@MainActor
final class DictationCleanupTesterTests: XCTestCase {
    private let instant = ContinuousClock.now

    private func makeTester(
        apple: FakeAppleCleanup = FakeAppleCleanup(),
        mlx: FakeMLXRuntime = FakeMLXRuntime(),
        sleeper: TestSleeper = TestSleeper()
    ) -> DictationCleanupTester {
        let instant = instant
        return DictationCleanupTester(apple: apple, mlx: mlx, sleep: sleeper.sleepFunction, now: { instant })
    }

    private func finished(_ tester: DictationCleanupTester) async {
        await eventually { !tester.phase.isRunning && tester.phase != .idle }
    }

    func testDefaultSampleIsTheSpecSample() {
        XCTAssertEqual(
            makeTester().input,
            "uh change the user service no wait the auth service to use refresh tokens and don't change the API"
        )
    }

    func testWarmMLXRunReportsRawOutputVerdictAndTimings() async {
        let mlx = FakeMLXRuntime(handler: { _, _ in "Change the auth service to use refresh tokens. Don't change the API." })
        let tester = makeTester(mlx: mlx)

        tester.run(model: .qwen3_0_6b)
        await finished(tester)

        guard case let .finished(report) = tester.phase else { return XCTFail("expected finished") }
        XCTAssertEqual(report.rawOutput, "Change the auth service to use refresh tokens. Don't change the API.")
        XCTAssertEqual(report.verdict, "Would insert")
        XCTAssertEqual(report.wouldInsert, "Change the auth service to use refresh tokens. Don't change the API.")
        XCTAssertNil(report.loadTime)
        let priorities = await mlx.generatePriorities
        XCTAssertEqual(priorities, [.test])
    }

    func testColdMLXRunLoadsFirstAndReportsLoadTime() async {
        let mlx = FakeMLXRuntime(readiness: .notLoaded)
        let tester = makeTester(mlx: mlx)

        tester.run(model: .qwen3_1_7b)
        await finished(tester)

        let loads = await mlx.ensureLoadedCalls
        XCTAssertEqual(loads, [.qwen3_1_7b])
        guard case let .finished(report) = tester.phase else { return XCTFail("expected finished") }
        XCTAssertNotNil(report.loadTime)
    }

    func testRejectedOutputShowsTheFallbackVerdict() async {
        let tester = makeTester(mlx: FakeMLXRuntime(handler: { _, _ in "Set the port to 3." }))
        tester.input = "set the port to 3, no, 4"

        tester.run(model: .qwen3_0_6b)
        await finished(tester)

        guard case let .finished(report) = tester.phase else { return XCTFail("expected finished") }
        XCTAssertEqual(report.verdict, "Would fall back: literal missing")
        XCTAssertEqual(report.wouldInsert, "set the port to 3, no, 4")
    }

    func testTimesOutAfterTenSeconds() async {
        let sleeper = TestSleeper()
        let operation = ManualOperation(cooperative: false)
        let tester = makeTester(mlx: FakeMLXRuntime(handler: { _, _ in try await operation.run() }), sleeper: sleeper)

        tester.run(model: .qwen3_0_6b)
        await eventually { sleeper.pending(.seconds(10)) == 1 }
        sleeper.fire(.seconds(10))
        await finished(tester)

        XCTAssertEqual(tester.phase, .timedOut)
        XCTAssertEqual(tester.phase.title, "Timed out")
        operation.finish(.success("late"))
    }

    func testPreemptionShowsCancelledByDictation() async {
        let tester = makeTester(mlx: FakeMLXRuntime(handler: { _, _ in throw CleanupSlotError.preempted }))
        tester.run(model: .qwen3_0_6b)
        await finished(tester)
        XCTAssertEqual(tester.phase, .cancelledByDictation)
        XCTAssertEqual(tester.phase.title, "Cancelled by dictation")
    }

    func testBusyShowsDictationInProgress() async {
        let tester = makeTester(apple: FakeAppleCleanup(handler: { _, _ in throw CleanupSlotError.busy }))
        tester.run(model: .appleSystem)
        await finished(tester)
        XCTAssertEqual(tester.phase, .busy)
        XCTAssertEqual(tester.phase.title, "Busy: dictation in progress")
    }

    func testUnavailableModelsShowModelUnavailable() async {
        let apple = makeTester(apple: FakeAppleCleanup(availability: .unavailable(.appleIntelligenceNotEnabled)))
        apple.run(model: .appleSystem)
        await finished(apple)
        XCTAssertEqual(apple.phase, .modelUnavailable)

        let mlx = makeTester(mlx: FakeMLXRuntime(present: []))
        mlx.run(model: .qwen3_0_6b)
        await finished(mlx)
        XCTAssertEqual(mlx.phase.title, "Model unavailable")
    }

    func testModelRemovalCancelsARunningTest() async {
        let operation = ManualOperation(cooperative: false)
        let tester = makeTester(mlx: FakeMLXRuntime(handler: { _, _ in try await operation.run() }))
        tester.run(model: .qwen3_0_6b)
        await eventually { operation.startCount == 1 }

        tester.cancelRunningTest(reason: .modelRemoved)
        await finished(tester)

        XCTAssertEqual(tester.phase, .cancelledModelRemoved)
        XCTAssertEqual(tester.phase.title, "Cancelled: model removed")
        operation.finish(.success("late"))
    }

    func testASecondRunWhileRunningIsIgnored() async {
        let operation = ManualOperation(cooperative: false)
        let mlx = FakeMLXRuntime(handler: { _, _ in try await operation.run() })
        let tester = makeTester(mlx: mlx)
        tester.run(model: .qwen3_0_6b)
        await eventually { operation.startCount == 1 }

        tester.run(model: .qwen3_0_6b)
        operation.finish(.success("Done."))
        await finished(tester)

        let requests = await mlx.generateRequests
        XCTAssertEqual(requests.count, 1)
    }
}
