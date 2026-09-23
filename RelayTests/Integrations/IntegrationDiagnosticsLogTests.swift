import Foundation
import XCTest

@testable import Relay

final class IntegrationDiagnosticsLogTests: XCTestCase {
    func testAppendThenSnapshotReturnsNewestFirst() {
        let log = IntegrationDiagnosticsLog()

        log.append(stage: "receiver", outcome: "line-received", detail: "10 bytes")
        log.append(stage: "receiver", outcome: "envelope-decoded", detail: "provider=claude-code")
        log.append(stage: "manager", outcome: "event-accepted", detail: "provider=claude-code")

        let snapshot = log.snapshot()

        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot[0].outcome, "event-accepted")
        XCTAssertEqual(snapshot[1].outcome, "envelope-decoded")
        XCTAssertEqual(snapshot[2].outcome, "line-received")
    }

    func testCapacityEvictsOldestEntriesFirst() {
        let log = IntegrationDiagnosticsLog(capacity: 5)

        for i in 0..<10 {
            log.append(stage: "receiver", outcome: "line-received", detail: "\(i) bytes")
        }

        let snapshot = log.snapshot()

        XCTAssertEqual(snapshot.count, 5)
        // Newest first: the last five appended (index 9 down to 5) should remain.
        XCTAssertEqual(snapshot.map(\.detail), ["9 bytes", "8 bytes", "7 bytes", "6 bytes", "5 bytes"])
    }

    func testClearRemovesAllEntries() {
        let log = IntegrationDiagnosticsLog()
        log.append(stage: "receiver", outcome: "line-received", detail: "1 bytes")
        XCTAssertEqual(log.snapshot().count, 1)

        log.clear()

        XCTAssertTrue(log.snapshot().isEmpty)
    }

    /// Concurrent-append smoke test: many appends from multiple queues never crash and end with a
    /// sane, capped count.
    func testConcurrentAppendsDoNotCrashAndRespectCapacity() {
        let log = IntegrationDiagnosticsLog(capacity: 200)
        let iterations = 500
        let queues = (0..<4).map { DispatchQueue(label: "diagnostics-log-test-\($0)") }
        let group = DispatchGroup()

        for queue in queues {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    log.append(stage: "receiver", outcome: "line-received", detail: "\(i) bytes")
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success)

        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.count, 200)
    }
}
