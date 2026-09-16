import XCTest
@testable import Relay

final class BoundedProcessRunnerTests: XCTestCase {
    private let runner = BoundedProcessRunner()

    func testSuccessReturnsStdoutAndZeroStatus() throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }
    func testNonZeroExitReportsStatusNotThrow() throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 3)
    }
    func testOversizedOutputThrows() {
        XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ABCDEFGH | head -c 1000000"], timeout: 5, maxOutputBytes: 4096)) { error in
            XCTAssertEqual(error as? BoundedProcessError, .outputTooLarge)
        }
    }
    func testBlockedProcessTimesOut() {
        let start = Date()
        XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3, maxOutputBytes: 1024)) { error in
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testStderrFloodDoesNotDeadlock() throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ERR | head -c 200000 1>&2; echo done"], timeout: 5, maxOutputBytes: 4096)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }
}
