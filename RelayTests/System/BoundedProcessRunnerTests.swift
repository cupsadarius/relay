import Darwin
import XCTest

@testable import Relay

final class BoundedProcessRunnerTests: XCTestCase {
    private let runner = BoundedProcessRunner()

    private func expectError(_ expected: BoundedProcessError, _ body: () async throws -> ProcessResult) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, expected)
        }
    }

    func testSuccessReturnsStdoutAndZeroStatus() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }

    func testNonZeroExitReportsStatusNotThrow() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 3)
    }

    func testOversizedOutputThrows() async {
        await expectError(.outputTooLarge) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ABCDEFGH | head -c 1000000"], timeout: 5, maxOutputBytes: 4096)
        }
    }

    func testBlockedProcessTimesOut() async {
        let start = Date()
        await expectError(.timedOut) {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3, maxOutputBytes: 1024)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// A child that traps SIGTERM would otherwise outlive `run(_:)`'s own timeout indefinitely.
    /// `ChildProcess.terminate()` escalates to SIGKILL ~0.2s after SIGTERM if the process is
    /// still alive, so this asserts the pid it wrote for itself is gone shortly afterward.
    func testHardKillsAChildThatIgnoresSIGTERM() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        await expectError(.timedOut) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \(pidFile.path); trap '' TERM; sleep 30"],
                timeout: 0.3, maxOutputBytes: 1024
            )
        }

        // Grace period (0.2s) plus margin for the kernel to actually reap the process.
        try await Task.sleep(nanoseconds: 700_000_000)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(pidText))
        XCTAssertNotEqual(kill(pid, 0), 0, "child that traps SIGTERM should have been force-killed with SIGKILL")
    }

    func testStderrFloodDoesNotDeadlock() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ERR | head -c 200000 1>&2; echo done"], timeout: 5, maxOutputBytes: 4096)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }

    func testMissingExecutableThrowsLaunchFailedInsteadOfCrashing() async {
        await expectError(.launchFailed) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/nonexistent/definitely-not-a-binary-\(UUID().uuidString)"),
                arguments: [], timeout: 5, maxOutputBytes: 1024
            )
        }
    }

    /// With the old semaphore-based runner, each run pinned a cooperative-pool thread, so
    /// 3x-pool-width concurrent `sleep 0.5`s took >= 3 rounds (~1.5 s). Suspending runs overlap.
    /// Capped at 24 so that even on a many-core machine this stays well below any OS or GCD
    /// thread limit (each run owns one drain `Thread` while its child sleeps).
    func testConcurrentRunsDoNotSerialiseOnTheCooperativePool() async throws {
        let runner = BoundedProcessRunner()
        let count = min(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.5"], timeout: 5, maxOutputBytes: 64)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.4)
    }
}
