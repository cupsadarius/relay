import Synchronization
import XCTest

@testable import Relay

@MainActor
final class MLXCleanupRuntimeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/relay-mlx-runtime-tests", isDirectory: true)
    private let present = LockedValue<Set<CleanupModelID>>([.qwen3_0_6b, .qwen3_1_7b])

    private func makeRuntime(engine: FakeMLXEngine, sleeper: TestSleeper = TestSleeper()) -> MLXCleanupRuntime {
        let root = root
        let present = present
        return MLXCleanupRuntime(
            engine: engine,
            directory: { root.appendingPathComponent($0.rawValue) },
            isPresent: { id in present.withLock { $0.contains(id) } },
            slot: CleanupGenerationSlot(sleep: sleeper.sleepFunction),
            idleUnloadAfter: .seconds(600),
            sleep: sleeper.sleepFunction
        )
    }

    private func request(_ id: CleanupModelID = .qwen3_0_6b) -> CleanupRequest {
        CleanupRequest(modelID: id, instructions: "I", input: "hello", maxOutputTokens: 32)
    }

    private func nextEvent(_ runtime: MLXCleanupRuntime) async -> MLXCleanupRuntimeEvent? {
        var iterator = runtime.events.makeAsyncIterator()
        return await iterator.next()
    }

    func testEnsureLoadedRefusesAbsentModelsWithoutLoading() async {
        present.withLock { $0 = [] }
        let engine = FakeMLXEngine()
        let runtime = makeRuntime(engine: engine)
        do {
            try await runtime.ensureLoaded(.qwen3_0_6b)
            XCTFail("expected notDownloaded")
        } catch {
            XCTAssertEqual(error as? MLXCleanupRuntimeError, .notDownloaded)
        }
        XCTAssertEqual(engine.loads, [])
    }

    func testEnsureLoadedLoadsFromTheVerifiedDirectoryOnce() async throws {
        let engine = FakeMLXEngine()
        let runtime = makeRuntime(engine: engine)

        try await runtime.ensureLoaded(.qwen3_0_6b)
        try await runtime.ensureLoaded(.qwen3_0_6b)

        XCTAssertEqual(engine.loads, [root.appendingPathComponent("mlx.qwen3-0.6b-4bit")])
        let readiness = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(readiness, .ready)
        guard case .loaded(.qwen3_0_6b, _) = await nextEvent(runtime) else { return XCTFail("expected a loaded event") }
    }

    func testConcurrentLoadsJoinAndReportLoading() async throws {
        let gate = ManualOperation(cooperative: false)
        let engine = FakeMLXEngine(loadGate: gate)
        let runtime = makeRuntime(engine: engine)

        let first = Task { try await runtime.ensureLoaded(.qwen3_0_6b) }
        await eventually { gate.startCount == 1 }
        let second = Task { try await runtime.ensureLoaded(.qwen3_0_6b) }
        let loading = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(loading, .loading)

        gate.finish(.success(""))
        try await first.value
        try await second.value
        XCTAssertEqual(engine.loads.count, 1)
    }

    func testFailedLoadReportsLoadFailedUntilALoadSucceeds() async throws {
        let engine = FakeMLXEngine()
        engine.failNextLoad()
        let runtime = makeRuntime(engine: engine)

        try? await runtime.ensureLoaded(.qwen3_0_6b)
        let failed = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(failed, .loadFailed)
        let other = await runtime.readiness(for: .qwen3_1_7b)
        XCTAssertEqual(other, .notLoaded)

        try await runtime.ensureLoaded(.qwen3_0_6b)
        let ready = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(ready, .ready)
    }

    func testGenerateRequiresTheRequestedModelToBeLoaded() async throws {
        let runtime = makeRuntime(engine: FakeMLXEngine(handler: { "cleaned \($0.input)" }))
        do {
            _ = try await runtime.generate(request(), priority: .production)
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? MLXCleanupRuntimeError, .notLoaded)
        }

        try await runtime.ensureLoaded(.qwen3_0_6b)
        let output = try await runtime.generate(request(), priority: .production)
        XCTAssertEqual(output, "cleaned hello")
        do {
            _ = try await runtime.generate(request(.qwen3_1_7b), priority: .production)
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? MLXCleanupRuntimeError, .notLoaded)
        }
    }

    func testUnloadDrainsAZombieGenerationBeforeUnloading() async throws {
        let operation = ManualOperation(cooperative: false)
        let engine = FakeMLXEngine(handler: { _ in try await operation.run() })
        let runtime = makeRuntime(engine: engine)
        try await runtime.ensureLoaded(.qwen3_0_6b)
        let caller = Task { try await runtime.generate(self.request(), priority: .production) }
        await eventually { operation.startCount == 1 }
        caller.cancel() // the generation keeps running: a zombie

        let unloading = Task { await runtime.unload(cause: .memoryPressure) }
        await eventually { await runtime.readiness(for: .qwen3_0_6b) == .unloading }
        XCTAssertEqual(engine.models.first?.unloadCount, 0)

        operation.finish(.success("late"))
        await unloading.value
        XCTAssertEqual(engine.models.first?.unloadCount, 1)
        XCTAssertEqual(engine.clearCacheCount, 1)
        let readiness = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(readiness, .notLoaded)
    }

    func testSwitchingModelsUnloadsTheOldOneWithSwitchCause() async throws {
        let engine = FakeMLXEngine()
        let runtime = makeRuntime(engine: engine)
        var events = runtime.events.makeAsyncIterator()
        try await runtime.ensureLoaded(.qwen3_0_6b)
        try await runtime.ensureLoaded(.qwen3_1_7b)

        guard case .loaded(.qwen3_0_6b, _) = await events.next() else { return XCTFail("expected loaded 0.6B") }
        let unloaded = await events.next()
        XCTAssertEqual(unloaded, .unloaded(.qwen3_0_6b, cause: .switchModel))
        guard case .loaded(.qwen3_1_7b, _) = await events.next() else { return XCTFail("expected loaded 1.7B") }
        XCTAssertEqual(engine.models.first?.unloadCount, 1)
    }

    func testIdleTimerUnloadsAndTouchRearmsIt() async throws {
        let sleeper = TestSleeper()
        let engine = FakeMLXEngine()
        let runtime = makeRuntime(engine: engine, sleeper: sleeper)
        try await runtime.ensureLoaded(.qwen3_0_6b)
        await eventually { sleeper.pending(.seconds(600)) == 1 }

        await runtime.touch()
        await eventually { sleeper.pending(.seconds(600)) == 1 && sleeper.requestCount(.seconds(600)) == 2 }

        sleeper.fire(.seconds(600))
        await eventually { await runtime.readiness(for: .qwen3_0_6b) == .notLoaded }
        XCTAssertEqual(engine.models.first?.unloadCount, 1)
    }

    func testUnloadIfInvolvingWaitsForAnInFlightLoadOfThatModel() async throws {
        let gate = ManualOperation(cooperative: false)
        let engine = FakeMLXEngine(loadGate: gate)
        let runtime = makeRuntime(engine: engine)
        let load = Task { try await runtime.ensureLoaded(.qwen3_0_6b) }
        await eventually { gate.startCount == 1 }

        let removal = Task { await runtime.unload(ifInvolving: .qwen3_0_6b) }
        gate.finish(.success(""))
        try await load.value
        await removal.value

        let readiness = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(readiness, .notLoaded)
        XCTAssertEqual(engine.models.first?.unloadCount, 1)
    }

    func testUnloadIfInvolvingIgnoresOtherModels() async throws {
        let engine = FakeMLXEngine()
        let runtime = makeRuntime(engine: engine)
        try await runtime.ensureLoaded(.qwen3_0_6b)

        await runtime.unload(ifInvolving: .qwen3_1_7b)

        let readiness = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(readiness, .ready)
    }

    func testRetireGenerationFailsTheCallerAndLetsUnloadProceedAfterItReturns() async throws {
        let operation = ManualOperation(cooperative: true)
        let runtime = makeRuntime(engine: FakeMLXEngine(handler: { _ in try await operation.run() }))
        try await runtime.ensureLoaded(.qwen3_0_6b)
        let caller = Task { try await runtime.generate(self.request(), priority: .test) }
        await eventually { operation.startCount == 1 }

        await runtime.retireGeneration()

        do {
            _ = try await caller.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await runtime.unload(ifInvolving: .qwen3_0_6b)
        let readiness = await runtime.readiness(for: .qwen3_0_6b)
        XCTAssertEqual(readiness, .notLoaded)
    }

    /// Controller decision: a cancelled caller's late zombie result must be discarded and never
    /// returned to anything still waiting on it. The engine is non-cooperative (a true zombie:
    /// `caller.cancel()` alone never resolves it), so the operation is finished immediately after
    /// cancelling — before awaiting `caller.value` — or `caller.value` would hang forever.
    func testCancelledCallerDiscardsALateZombieResult() async throws {
        let operation = ManualOperation(cooperative: false)
        let engine = FakeMLXEngine(handler: { _ in try await operation.run() })
        let runtime = makeRuntime(engine: engine)
        try await runtime.ensureLoaded(.qwen3_0_6b)
        let caller = Task { try await runtime.generate(self.request(), priority: .production) }
        await eventually { operation.startCount == 1 }

        caller.cancel()
        operation.finish(.success("late, must be discarded"))

        do {
            _ = try await caller.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
