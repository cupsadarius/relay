import XCTest

@testable import Relay

final class TmuxClientBoundsTests: XCTestCase {
    private final class FakeRunner: ProcessRunning, @unchecked Sendable {
        var lastTimeout: TimeInterval?
        var lastMaxOutputBytes: Int?
        func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
            lastTimeout = timeout
            lastMaxOutputBytes = maxOutputBytes
            return ProcessResult(stdout: Data("main\t123\n".utf8), terminationStatus: 0)
        }
    }
    func testListClientsRoutesThroughBoundedRunner() async throws {
        let runner = FakeRunner()
        let client = TmuxClient(executable: "/opt/homebrew/bin/tmux", runner: runner, timeout: 3)
        let listing = try await client.listClients(socketPath: "/tmp/s")
        XCTAssertEqual(listing, [TmuxClientListing(name: "main", pid: 123)])
        XCTAssertEqual(runner.lastTimeout, 3)
        XCTAssertNotNil(runner.lastMaxOutputBytes)
    }
}
