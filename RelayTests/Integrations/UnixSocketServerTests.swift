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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError(operation: "socket", errno: errno) }
        defer { close(fd) }

        // Widen the send buffer so a large test payload (e.g. an
        // oversized-line fixture) can be handed to the kernel in a handful
        // of writes rather than trickling in at the OS default buffer size.
        var sendBufferSize = Int32(4 * 1024 * 1024)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, socklen_t(MemoryLayout<Int32>.size))

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
        guard connectResult == 0 else { throw ClientError(operation: "connect", errno: errno) }

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
}
