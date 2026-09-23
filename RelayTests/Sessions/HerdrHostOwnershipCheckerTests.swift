import XCTest

@testable import Relay

final class HerdrHostOwnershipCheckerTests: XCTestCase {
    private final class CountingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var runCount: Int { lock.withLock { count } }
        func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
            lock.withLock { count += 1 }
            return ProcessResult(stdout: Data(), terminationStatus: 0)
        }
    }

    /// `sleep 30` stands in for a hung `lsof`: the checker must give up after its own short
    /// timeout and report "not owned" rather than hang the focus path.
    func testHangingLsofTimesOutAndReturnsFalsePromptly() async throws {
        let snapshot = try ProcessSnapshot.parse("1 0 ?? launchd\n100 1 ttys001 herdr")
        let checker = HerdrHostOwnershipChecker(
            lsofExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
            lsofArguments: { _ in ["30"] },
            lsofTimeout: 0.2
        )
        let start = Date()

        let owns = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/does-not-matter.sock", processSnapshot: snapshot)

        XCTAssertFalse(owns)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNoHerdrDescendantMeansNoLsofAtAll() async throws {
        let snapshot = try ProcessSnapshot.parse("1 0 ?? launchd\n100 1 ttys001 zsh")
        let runner = CountingRunner()
        let checker = HerdrHostOwnershipChecker(runner: runner)

        let owns = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/x.sock", processSnapshot: snapshot)

        XCTAssertFalse(owns)
        XCTAssertEqual(runner.runCount, 0)
    }
}
