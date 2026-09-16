import Darwin
import Foundation
import XCTest
@testable import Relay

/// Minimal blocking AF_UNIX client used only by tests to exercise
/// `UnixSocketServer` over a real loopback connection.
enum UnixSocketTestClient {
    struct ClientError: Error {
        let operation: String
        let errno: Int32
    }

    /// Sends `text` to the Unix-domain socket at `path`.
    ///
    /// The actual (blocking) socket I/O runs on a dedicated `Thread`, not
    /// directly on the calling task. A payload larger than the kernel's
    /// small AF_UNIX send buffer (a few KiB) would otherwise block inside
    /// `write` until the server drains it; blocking a Swift Concurrency
    /// cooperative-pool thread like that can itself starve the very GCD
    /// queue that needs to run to drain the socket. Suspending via a
    /// continuation instead keeps the pool free while the dedicated thread
    /// waits on the kernel.
    static func send(_ text: String, to path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                do {
                    try sendBlocking(text, to: path)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    private static func sendBlocking(_ text: String, to path: String) throws {
        let fd = try connectBlocking(to: path)
        defer { close(fd) }

        // Widen the send buffer so a large test payload (e.g. an
        // oversized-line fixture) can be handed to the kernel in a handful
        // of writes rather than trickling in at the OS default buffer size.
        var sendBufferSize = Int32(4 * 1024 * 1024)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, socklen_t(MemoryLayout<Int32>.size))

        let bytes = Array(text.utf8)
        var totalWritten = 0
        while totalWritten < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: totalWritten), raw.count - totalWritten)
            }
            guard written > 0 else { throw ClientError(operation: "write", errno: errno) }
            totalWritten += written
        }
    }

    /// Opens a connection to the Unix-domain socket at `path` and returns
    /// its raw file descriptor without writing anything, so a test can hold
    /// it open (e.g. to fill the server's connection table) or immediately
    /// probe whether the server closed it.
    ///
    /// The connect itself runs on a dedicated `Thread`, matching `send`'s
    /// rationale: keep the Swift Concurrency cooperative pool free.
    static func connectAndHold(to path: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let thread = Thread {
                do {
                    let fd = try connectBlocking(to: path)
                    continuation.resume(returning: fd)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Waits up to `timeout` seconds for the peer to close `fd` (EOF).
    /// Returns `true` if EOF arrived within the window, `false` if the
    /// window elapsed with the connection still open (or data arrived
    /// instead). Uses `SO_RCVTIMEO` for a single bounded blocking `read` —
    /// no polling loop — and runs on a dedicated `Thread` so it never blocks
    /// the Swift Concurrency cooperative pool.
    static func waitForEOF(fd: Int32, timeout: TimeInterval) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let thread = Thread {
                var tv = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
                )
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var byte: UInt8 = 0
                let bytesRead = read(fd, &byte, 1)
                continuation.resume(returning: bytesRead == 0)
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    private static func connectBlocking(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError(operation: "socket", errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base.update(repeating: 0, count: raw.count)
            for (index, byte) in pathBytes.enumerated() {
                base[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let capturedErrno = errno
            close(fd)
            throw ClientError(operation: "connect", errno: capturedErrno)
        }
        return fd
    }
}

final class UnixSocketServerTests: XCTestCase {
    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    func testServerReceivesOneJSONLine() async throws {
        let path = temporarySocketPath()
        let received = expectation(description: "received")
        let server = UnixSocketServer()
        try server.start(path: path) { line in
            XCTAssertTrue(line.contains("schemaVersion"))
            received.fulfill()
        }
        defer { server.stop() }

        try await UnixSocketTestClient.send(#"{"schemaVersion":1}"# + "\n", to: path)
        await fulfillment(of: [received], timeout: 1)
    }

    func testIsListeningReflectsStartAndStopLifecycle() throws {
        let path = temporarySocketPath()
        let server = UnixSocketServer()

        XCTAssertFalse(server.isListening)

        try server.start(path: path) { _ in }
        XCTAssertTrue(server.isListening)

        server.stop()
        XCTAssertFalse(server.isListening)
    }

    func testStopUnlinksTheSocketPath() throws {
        let path = temporarySocketPath()
        let server = UnixSocketServer()
        try server.start(path: path) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStartCreatesMissingParentDirectoryWithRestrictedPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("relay.sock").path
        let server = UnixSocketServer()
        try server.start(path: path) { _ in }
        defer { server.stop() }

        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testStartRefusesAndPreservesANonSocketFileAtThePath() throws {
        let path = temporarySocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))

        let server = UnixSocketServer()
        XCTAssertThrowsError(try server.start(path: path) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketServerError, .unsafeStaleSocket)
        }

        // The offending file must never be deleted or chmod'd away.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "not a socket")
    }

    func testStartReplacesAStaleSocketFileOwnedByTheCurrentUser() throws {
        let path = temporarySocketPath()

        // Leave behind a stale (unbound-by-us) socket file, simulating a
        // crash that skipped `stop()`.
        let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(staleFD, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base.update(repeating: 0, count: raw.count)
            for (index, byte) in pathBytes.enumerated() { base[index] = byte }
        }
        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(staleFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        close(staleFD) // The socket file remains on disk after closing the fd.

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let server = UnixSocketServer()
        try server.start(path: path) { _ in }
        server.stop()
    }

    func testOversizedLineIsDroppedAndConnectionIsClosedWithoutHangingTheServer() async throws {
        let path = temporarySocketPath()
        let receivedShortLine = expectation(description: "received short line after oversized one")
        let receivedOversizedLine = expectation(description: "oversized line delivered")
        receivedOversizedLine.isInverted = true

        let server = UnixSocketServer()
        try server.start(path: path) { line in
            if line.utf8.count > UnixSocketServer.maxLineBytes {
                receivedOversizedLine.fulfill()
            } else {
                receivedShortLine.fulfill()
            }
        }
        defer { server.stop() }

        // No trailing newline: the server must bound its buffer instead of
        // growing it forever, and close the connection.
        let oversized = String(repeating: "a", count: UnixSocketServer.maxLineBytes + 1)
        try await UnixSocketTestClient.send(oversized, to: path)

        await fulfillment(of: [receivedOversizedLine], timeout: 0.3)

        // The listener must still be healthy for subsequent connections.
        try await UnixSocketTestClient.send(#"{"schemaVersion":1}"# + "\n", to: path)
        await fulfillment(of: [receivedShortLine], timeout: 1)
    }

    func testConnectionsBeyondTheCapAreDroppedWhileWithinCapClientsAreStillServed() async throws {
        let path = temporarySocketPath()
        let server = UnixSocketServer()
        let cap = UnixSocketServer.maxConcurrentConnections
        let overflowCount = 3
        let totalConnections = cap + overflowCount

        let received = expectation(description: "line received once a slot freed under the cap")
        try server.start(path: path) { line in
            XCTAssertTrue(line.contains("schemaVersion"))
            received.fulfill()
        }
        defer { server.stop() }

        // Open more silent, long-lived connections than the cap allows.
        // Sequentially: AF_UNIX `connect()` (unlike TCP) can fail outright
        // with ECONNREFUSED if the listen backlog is full, so a concurrent
        // burst risks spurious connect failures unrelated to what this test
        // checks. One at a time keeps at most one pending connection ahead
        // of the server's accept loop.
        var fds: [Int32] = []
        for _ in 0..<totalConnections {
            fds.append(try await UnixSocketTestClient.connectAndHold(to: path))
        }
        defer { for fd in fds { close(fd) } }

        // Give the server's serial queue a brief, bounded moment to finish
        // draining its accept backlog before probing outcomes — not a spin
        // loop, just a settle window ahead of the real (also bounded)
        // per-connection EOF probes below.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Probe every connection concurrently for whether the server closed
        // it (dropped, over the cap) or left it open (tracked, within the
        // cap). This checks aggregate counts rather than assuming which
        // specific connections landed within vs. beyond the cap — accept
        // ordering under concurrency is not under this test's control.
        let openStates: [(fd: Int32, isOpen: Bool)] = try await withThrowingTaskGroup(
            of: (Int32, Bool).self
        ) { group in
            for fd in fds {
                group.addTask {
                    let hitEOF = try await UnixSocketTestClient.waitForEOF(fd: fd, timeout: 0.5)
                    return (fd, !hitEOF)
                }
            }
            var results: [(Int32, Bool)] = []
            for try await result in group { results.append(result) }
            return results
        }

        let openCount = openStates.filter(\.isOpen).count
        let droppedCount = openStates.count - openCount
        XCTAssertEqual(openCount, cap, "server should keep exactly the capped number of connections open")
        XCTAssertEqual(droppedCount, overflowCount, "connections beyond the cap should be dropped")

        // Freeing a slot must let the server accept and serve a new client
        // again — the cap is a live limit, not a one-shot lockout. Close a
        // connection the server actually still has open, to free a real
        // slot (closing an already-dropped one wouldn't free anything).
        guard let openFD = openStates.first(where: \.isOpen)?.fd else {
            XCTFail("expected at least one open connection to free")
            return
        }
        close(openFD)
        fds.removeAll { $0 == openFD }

        try await UnixSocketTestClient.send(#"{"schemaVersion":1}"# + "\n", to: path)
        await fulfillment(of: [received], timeout: 1)
    }

    func testMalformedNonJSONLineIsForwardedVerbatimByTheTransportLayer() async throws {
        // UnixSocketServer itself has no notion of JSON; it must simply
        // forward whatever line arrives without crashing.
        let path = temporarySocketPath()
        let received = expectation(description: "received")
        let server = UnixSocketServer()
        try server.start(path: path) { line in
            XCTAssertEqual(line, "not json at all")
            received.fulfill()
        }
        defer { server.stop() }

        try await UnixSocketTestClient.send("not json at all\n", to: path)
        await fulfillment(of: [received], timeout: 1)
    }

    func testClientDisconnectMidWriteDiscardsThePartialLineAndServerStaysHealthy() async throws {
        // A peer can vanish (crash, killed, network drop) partway through a
        // line, well under the size cap and with no trailing newline. The
        // server must treat the resulting EOF like `closeConnection` for any
        // other reason: drop the unterminated partial bytes without ever
        // invoking `onLine` for them, and keep accepting/serving later
        // clients rather than wedging on the half-written connection.
        let path = temporarySocketPath()
        let receivedPartialLine = expectation(description: "partial line delivered")
        receivedPartialLine.isInverted = true
        let receivedFollowUpLine = expectation(description: "later client still served")

        let server = UnixSocketServer()
        try server.start(path: path) { line in
            if line.contains("incomple") {
                receivedPartialLine.fulfill()   // inverted guard: trips only if the partial is wrongly delivered
            } else {
                receivedFollowUpLine.fulfill()
            }
        }
        defer { server.stop() }

        // No trailing newline: `send` still closes the connection once the
        // bytes are flushed to the kernel, modeling a peer that disconnects
        // mid-message rather than one that simply pauses.
        try await UnixSocketTestClient.send(#"{"schemaVersion":1,"incomple"#, to: path)

        await fulfillment(of: [receivedPartialLine], timeout: 0.3)

        // The listener must still be healthy for a subsequent, complete
        // connection — the aborted peer must not have wedged anything.
        try await UnixSocketTestClient.send(#"{"schemaVersion":1}"# + "\n", to: path)
        await fulfillment(of: [receivedFollowUpLine], timeout: 1)
    }
}
