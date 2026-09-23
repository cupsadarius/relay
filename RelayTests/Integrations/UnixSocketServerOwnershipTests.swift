import Darwin
import Foundation
import XCTest

@testable import Relay

/// Exercises the ownership-hardening behavior added to `UnixSocketServer`:
/// a live-listener probe before unlinking a stale-looking socket path, and a
/// single-instance `flock` guard so two Relay processes (or, here, two
/// in-process `UnixSocketServer` instances) can never both believe they own
/// the same socket path.
final class UnixSocketServerOwnershipTests: XCTestCase {
    /// A short, unique socket path under a freshly created per-test directory
    /// `/tmp/relay-test-<uuid8>/relay.sock` — not `NSTemporaryDirectory()`
    /// (the per-process temp directory on macOS is already long enough that
    /// adding a lockfile sibling risks tipping AF_UNIX's ~104-byte `sun_path`
    /// limit) and not a bare path directly under `/tmp` shared by every test
    /// (every `UnixSocketServer.start()` also opens `<socketDir>/relay.lock`,
    /// so sharing a directory would mean sharing that lockfile too, and two
    /// concurrent test-suite runs — e.g. parallel CI — would contend on it
    /// and could spuriously fail the flock-guard tests). Giving each test its
    /// own directory makes its lockfile unique as well, while still letting
    /// a single test start two servers against the *same* (per-test) path to
    /// exercise the flock guard.
    private func uniqueSocketPath() -> String {
        let suffix = UUID().uuidString.prefix(8)
        let directory = "/tmp/relay-test-\(suffix)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        testDirectories.append(directory)
        return directory + "/relay.sock"
    }

    private var serversToStop: [UnixSocketServer] = []
    private var testDirectories: [String] = []

    override func tearDown() {
        // Stop servers first so every `relay.lock` flock is released before
        // its directory (lockfile, socket file, and all) is swept away.
        for server in serversToStop {
            server.stop()
        }
        serversToStop.removeAll()

        for directory in testDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        testDirectories.removeAll()

        super.tearDown()
    }

    /// Exercises `probeLiveListener` directly (as opposed to the flock
    /// single-instance guard exercised by `testSecondInstanceCannotStartWhileFirstListens`):
    /// a raw `bind()` + `listen()` socket held open here, outside of
    /// `UnixSocketServer`, never takes the `relay.lock` flock — so when a
    /// `UnixSocketServer.start()` on the same path is refused, it can only be
    /// because the probe connect reached this live listener.
    func testProbeDetectsLiveListenerAndRefusesToUnlink() async throws {
        let path = uniqueSocketPath()

        let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenerFD, 0)
        defer { close(listenerFD) }
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
                Darwin.bind(listenerFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(listenerFD, 8), 0)

        // A `UnixSocketServer.start()` on the same path must probe, find this
        // live listener, and refuse to unlink it.
        let server = UnixSocketServer()
        XCTAssertThrowsError(try server.start(path: path) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketServerError, .activeListenerPresent)
        }
        XCTAssertFalse(server.isListening)

        // The raw listener's socket file must still exist and still accept
        // connections — `start()` must not have unlinked it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let fd = try await UnixSocketTestClient.connectAndHold(to: path)
        close(fd)
    }

    func testStaleSocketAfterCrashIsRecovered() throws {
        let path = uniqueSocketPath()

        // Leave behind a stale (bound but never listened-on, then closed)
        // socket file, simulating a crash that skipped `stop()`.
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
        close(staleFD) // The socket file remains on disk after closing the fd; nothing is listening.

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let server = UnixSocketServer()
        try server.start(path: path) { _ in }
        serversToStop.append(server)
        XCTAssertTrue(server.isListening)
    }

    func testForeignNonSocketPathNeverDeleted() throws {
        let path = uniqueSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = UnixSocketServer()
        XCTAssertThrowsError(try server.start(path: path) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketServerError, .unsafeStaleSocket)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "not a socket")
    }

    func testSecondInstanceCannotStartWhileFirstListens() throws {
        let path = uniqueSocketPath()

        let serverA = UnixSocketServer()
        try serverA.start(path: path) { _ in }
        serversToStop.append(serverA)

        let serverB = UnixSocketServer()
        XCTAssertThrowsError(try serverB.start(path: path) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketServerError, .activeListenerPresent)
        }

        XCTAssertTrue(serverA.isListening)
        XCTAssertFalse(serverB.isListening)
    }
}
