import XCTest
@testable import Relay

private final class ReturnedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

final class CaptureCallbackGateTests: XCTestCase {
    private enum Boom: Error, Equatable { case first, second }

    func testEnterIsRefusedUntilOpened() {
        let gate = CaptureCallbackGate()
        XCTAssertFalse(gate.enter())
        gate.open()
        XCTAssertTrue(gate.enter())
        gate.leave()
    }

    func testCloseWaitsForAnInFlightCallbackToLeave() {
        let gate = CaptureCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())

        let returned = ReturnedFlag()
        DispatchQueue.global().async {
            _ = gate.close()
            returned.set()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(returned.value, "close must not return while a callback is delivering samples")

        gate.leave()
        let deadline = Date().addingTimeInterval(2)
        while !returned.value, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(returned.value, "close must return once the in-flight callback leaves")
    }

    func testNoCallbackIsAdmittedAfterClose() {
        let gate = CaptureCallbackGate()
        gate.open()
        _ = gate.close()
        XCTAssertFalse(gate.enter())
    }

    func testOnlyTheFirstFailureIsRecordedAndCloseReturnsItOnce() {
        let gate = CaptureCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())

        XCTAssertTrue(gate.fail(Boom.first), "fail must not wait for the callback that is calling it")
        XCTAssertFalse(gate.fail(Boom.second))
        XCTAssertFalse(gate.enter())
        gate.leave()

        XCTAssertEqual(gate.close() as? Boom, .first)
        XCTAssertNil(gate.close())
    }

    func testOpenClearsAPreviousFailure() {
        let gate = CaptureCallbackGate()
        gate.open()
        _ = gate.fail(Boom.first)
        gate.open()
        XCTAssertNil(gate.close())
    }
}
