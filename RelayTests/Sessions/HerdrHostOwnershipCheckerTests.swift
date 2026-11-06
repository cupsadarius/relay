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

    func testNoHerdrDescendantMeansNoLsofAtAll() async throws {
        let snapshot = ProcessSnapshot.parse("1 0 launchd\n100 1 zsh")
        let runner = CountingRunner()
        let checker = HerdrHostOwnershipChecker(runner: runner)

        let owns = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/x.sock", processSnapshot: snapshot)

        XCTAssertFalse(owns)
        XCTAssertEqual(runner.runCount, 0)
    }
}
