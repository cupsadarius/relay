import XCTest

@testable import Relay

@MainActor
final class CleanupDeadlineTests: XCTestCase {
    func testReturnsTheValueBeforeTheDeadline() async throws {
        let sleeper = TestSleeper()
        let outcome = try await withCleanupDeadline(.seconds(1), sleep: sleeper.sleepFunction) { "ok" }
        guard case let .value(value) = outcome else { return XCTFail("expected a value") }
        XCTAssertEqual(value, "ok")
    }

    func testReportsTheOperationFailure() async throws {
        let sleeper = TestSleeper()
        let outcome = try await withCleanupDeadline(.seconds(1), sleep: sleeper.sleepFunction) { () async throws -> String in
            throw CleanupTestError()
        }
        guard case let .failure(error) = outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(error is CleanupTestError)
    }

    func testTimesOutAtTheDeadlineEvenWhenTheOperationIgnoresCancellation() async throws {
        let sleeper = TestSleeper()
        let operation = ManualOperation(cooperative: false)
        let race = Task { try await withCleanupDeadline(.milliseconds(2500), sleep: sleeper.sleepFunction) { try await operation.run() } }
        await eventually { operation.startCount == 1 && sleeper.pending(.milliseconds(2500)) == 1 }

        sleeper.fire(.milliseconds(2500))
        let outcome = try await race.value

        guard case .timedOut = outcome else { return XCTFail("expected a timeout") }
        operation.finish(.success("late"))
    }

    func testCallerCancellationThrowsCancellationError() async {
        let sleeper = TestSleeper()
        let operation = ManualOperation(cooperative: false)
        let race = Task { try await withCleanupDeadline(.seconds(10), sleep: sleeper.sleepFunction) { try await operation.run() } }
        await eventually { operation.startCount == 1 }

        race.cancel()

        do {
            _ = try await race.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        operation.finish(.success("late"))
    }
}
