import XCTest
@testable import Relay

final class ProcessInspectorTests: XCTestCase {
    func testParsesSnapshotAndWalksAncestry() throws {
        let fixture = """
          1     0 ??       launchd
         20     1 ??       Ghostty
        101    20 ttys001  zsh
        202   101 ttys001  claude
        303   202 ttys001  RelayHook
        """
        let snapshot = try ProcessSnapshot.parse(fixture)
        XCTAssertEqual(snapshot.ancestry(from: 303).map(\.pid), [303, 202, 101, 20, 1])
        XCTAssertEqual(snapshot.record(pid: 303)?.tty, "ttys001")
    }

    func testDescendantsAreComputedFromParentEdges() throws {
        let snapshot = try ProcessSnapshot.parse("""
          20 1 ?? Ghostty
         100 20 ttys001 zsh
         101 20 ttys002 zsh
         200 100 ttys001 herdr
        """)
        XCTAssertEqual(Set(snapshot.descendants(of: 20).map(\.pid)), [100, 101, 200])
    }

    /// Regression test for the drain-order deadlock: `snapshot()` used to call
    /// `waitUntilExit()` before draining stdout, which deadlocks once `/bin/ps` writes more than
    /// the pipe's 64KB kernel buffer (routine on a busy machine with a large process table).
    /// This exercises the *real* `/bin/ps` drain path end-to-end and asserts the call actually
    /// returns, wrapped in an `XCTestExpectation` with a hard timeout so a regression re-hang fails
    /// the test instead of hanging CI.
    func testSnapshotReturnsAndIncludesCurrentProcessAncestry() throws {
        let expectation = expectation(description: "snapshot() returns")
        let inspector = ProcessInspector()
        nonisolated(unsafe) var result: Result<ProcessSnapshot, Error>?

        DispatchQueue.global().async {
            result = Result { try inspector.snapshot() }
            expectation.fulfill()
        }

        // Well above the inspector's own 5s watchdog: if this expectation times out, the watchdog
        // itself has regressed (or the drain-order fix has been undone), and we want a clear test
        // failure rather than an indefinite CI hang.
        wait(for: [expectation], timeout: 10)

        let snapshot = try XCTUnwrap(try result?.get())
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotNil(snapshot.record(pid: ownPID), "snapshot should include the current test process")
        XCTAssertFalse(snapshot.ancestry(from: ownPID).isEmpty)
    }

    /// Verifies the watchdog fires (and throws rather than hanging) when the underlying command
    /// never exits/produces EOF. `sleep 30` writes nothing and doesn't close its stdout until it
    /// exits 30s later, which stands in for a hung/misbehaving `ps` deterministically (no dependence
    /// on the test process's own stdin, unlike e.g. `cat`). Uses a short injected timeout so the
    /// test itself stays fast; `snapshot()` doesn't wait for the terminated process to actually die
    /// before throwing, so this returns promptly rather than waiting out the full 30s.
    func testSnapshotThrowsTimedOutWhenProcessHangs() throws {
        let inspector = ProcessInspector(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.2
        )
        XCTAssertThrowsError(try inspector.snapshot()) { error in
            XCTAssertEqual(error as? ProcessInspectionError, .timedOut)
        }
    }
}
