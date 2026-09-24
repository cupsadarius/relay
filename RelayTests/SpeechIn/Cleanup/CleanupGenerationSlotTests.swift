import XCTest

@testable import Relay

@MainActor
final class CleanupGenerationSlotTests: XCTestCase {
    func testRunsTheOperationAndFreesTheSlot() async throws {
        let slot = CleanupGenerationSlot()
        let output = try await slot.run(.production) { "ok" }
        XCTAssertEqual(output, "ok")
        let busy = await slot.isBusy
        XCTAssertFalse(busy)
    }

    func testProductionIsBusyWhileAnotherProductionRuns() async throws {
        let slot = CleanupGenerationSlot()
        let operation = ManualOperation(cooperative: true)
        let first = Task { try await slot.run(.production) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        do {
            _ = try await slot.run(.production) { "second" }
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .busy)
        }
        operation.finish(.success("first"))
        let firstOutput = try await first.value
        XCTAssertEqual(firstOutput, "first")
    }

    func testTestIsBusyWhileAnyGenerationRuns() async {
        let slot = CleanupGenerationSlot()
        let operation = ManualOperation(cooperative: true)
        let production = Task { try await slot.run(.production) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        do {
            _ = try await slot.run(.test) { "test" }
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .busy)
        }
        operation.finish(.success("done"))
        _ = try? await production.value
    }

    func testProductionPreemptsACooperativeTest() async throws {
        let sleeper = TestSleeper()
        let slot = CleanupGenerationSlot(sleep: sleeper.sleepFunction)
        let operation = ManualOperation(cooperative: true)
        let test = Task { try await slot.run(.test) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        let production = try await slot.run(.production) { "prod" }

        XCTAssertEqual(production, "prod")
        do {
            _ = try await test.value
            XCTFail("expected preempted")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .preempted)
        }
    }

    func testProductionFailsOpenWhenATestWillNotDrainIn150Milliseconds() async {
        let sleeper = TestSleeper()
        let slot = CleanupGenerationSlot(sleep: sleeper.sleepFunction)
        let operation = ManualOperation(cooperative: false)
        let test = Task { try await slot.run(.test) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        let production = Task { try await slot.run(.production) { "prod" } }
        await eventually { sleeper.pending(.milliseconds(150)) == 1 }
        sleeper.fire(.milliseconds(150))

        do {
            _ = try await production.value
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .busy)
        }
        operation.finish(.success("late"))
        do {
            _ = try await test.value
            XCTFail("expected preempted")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .preempted)
        }
    }

    func testCancelledCallerLeavesAZombieUntilTheOperationReturns() async {
        let slot = CleanupGenerationSlot()
        let operation = ManualOperation(cooperative: false)
        let caller = Task { try await slot.run(.production) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        caller.cancel()
        await eventually { await slot.hasZombie }
        do {
            _ = try await slot.run(.production) { "next" }
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .busy)
        }

        operation.finish(.success("late"))
        _ = try? await caller.value
        let busy = await slot.isBusy
        XCTAssertFalse(busy)
    }

    func testRetireTurnsTheActiveGenerationIntoAZombie() async {
        let slot = CleanupGenerationSlot()
        let operation = ManualOperation(cooperative: false)
        let caller = Task { try await slot.run(.production) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        await slot.retire()

        let zombie = await slot.hasZombie
        XCTAssertTrue(zombie)
        operation.finish(.success("late"))
        _ = try? await caller.value
    }

    func testCloseWaitsForTheActiveGenerationAndRejectsNewOnesUntilOpen() async throws {
        let slot = CleanupGenerationSlot()
        let operation = ManualOperation(cooperative: false)
        let caller = Task { try await slot.run(.production) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        let closing = Task { await slot.close() }
        await eventually { await slot.isClosed }
        do {
            _ = try await slot.run(.production) { "rejected" }
            XCTFail("expected closed")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .closed)
        }
        operation.finish(.success("done"))
        await closing.value
        _ = try? await caller.value

        await slot.open()
        let reopened = try await slot.run(.production) { "ok" }
        XCTAssertEqual(reopened, "ok")
    }
}
