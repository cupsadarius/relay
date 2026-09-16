import XCTest
@testable import Relay

final class HerdrHostOwnershipCheckerTests: XCTestCase {
    /// Verifies the `lsof` watchdog fires (and returns `false` rather than hanging) when the
    /// underlying command never exits/produces EOF. `sleep 30` writes nothing and doesn't close its
    /// stdout until it exits 30s later, standing in for a hung/misbehaving `lsof` deterministically.
    /// Uses a fake `ps`-replacement (via `ProcessInspector`'s own injectable init) so the frontmost
    /// process has a synthetic "herdr" descendant without touching the real process table, and a
    /// short injected `lsof` timeout so the test stays fast. No real sockets or `~/.claude`/`~/.codex`
    /// paths are touched.
    func testHangingLsofTimesOutAndReturnsFalsePromptly() async throws {
        let fakePS = ProcessInspector(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["1 0 ?? launchd\n100 1 ttys001 herdr"],
            timeout: 5
        )
        let checker = HerdrHostOwnershipChecker(
            processInspector: fakePS,
            lsofExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
            lsofArguments: { _ in ["30"] },
            lsofTimeout: 0.2
        )

        let expectation = expectation(description: "frontmostAppOwnsClient returns")
        nonisolated(unsafe) var result: Bool?
        Task {
            result = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/does-not-matter.sock")
            expectation.fulfill()
        }

        // Well above the checker's own 0.2s watchdog: if this expectation times out, the watchdog
        // itself has regressed (or the drain-order fix has been undone), and we want a clear test
        // failure rather than an indefinite CI hang.
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertEqual(result, false)
    }
}
