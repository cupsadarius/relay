import Darwin
import Foundation
import XCTest
@testable import Relay

/// Exercises `UnixLineRequest` over a real loopback AF_UNIX connection. The
/// test-only server below is a minimal hand-rolled listener (not
/// `UnixSocketServer`, which only reads from clients and never writes a
/// response line back).
final class HerdrSocketClientTests: XCTestCase {
    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    func testSendReturnsFirstLineFromServer() async throws {
        let path = temporarySocketPath()
        let listenerFD = try LoopbackServer.bindAndListen(path: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let serverThread = Thread {
            guard let clientFD = LoopbackServer.accept(listenerFD) else { return }
            defer { Darwin.close(clientFD) }
            LoopbackServer.write("pong\n", to: clientFD)
        }
        serverThread.stackSize = 1 << 20
        serverThread.start()

        let line = try await UnixLineRequest.send(path: path, line: "ping\n", timeoutMilliseconds: 400)
        XCTAssertEqual(line, "pong")
    }

    func testSendTimesOutWhenPeerDribblesBytesWithoutANewline() async throws {
        let path = temporarySocketPath()
        let listenerFD = try LoopbackServer.bindAndListen(path: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let serverThread = Thread {
            guard let clientFD = LoopbackServer.accept(listenerFD) else { return }
            defer { Darwin.close(clientFD) }
            // Dribble one byte at a time, comfortably under the per-recv
            // timeout, and never send a newline: the slow-loris shape the
            // total request deadline exists to bound.
            for _ in 0..<40 {
                guard LoopbackServer.write("x", to: clientFD) else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        serverThread.stackSize = 1 << 20
        serverThread.start()

        let start = DispatchTime.now()
        do {
            _ = try await UnixLineRequest.send(path: path, line: "ping\n", timeoutMilliseconds: 400)
            XCTFail("expected the total deadline to fire")
        } catch HerdrQueryError.timedOut {
            // expected
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertLessThan(
            elapsedSeconds, 2.0,
            "a peer that keeps every individual recv alive must still be bounded by the total deadline"
        )
    }
}

/// Minimal blocking AF_UNIX listener used only by tests, mirroring the style
/// of `UnixSocketTestClient` in `UnixSocketServerTests.swift`.
private enum LoopbackServer {
    static func bindAndListen(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrQueryError.socketFailure }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base.update(repeating: 0, count: raw.count)
            for (index, byte) in pathBytes.enumerated() { base[index] = byte }
        }

        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw HerdrQueryError.socketFailure
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw HerdrQueryError.socketFailure
        }
        return fd
    }

    static func accept(_ listenerFD: Int32) -> Int32? {
        let clientFD = Darwin.accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return nil }
        // Prevent SIGPIPE from tearing down the test process if the client
        // has already closed its end (e.g. after the deadline test's client
        // gives up) by the time this thread writes again.
        var one: Int32 = 1
        _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return clientFD
    }

    @discardableResult
    static func write(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { raw -> Int in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
        return written == bytes.count
    }
}

extension HerdrSocketClientTests {
    func testReceiveTimeoutSplitsMillisecondsIntoSecondsAndMicroseconds() {
        let long = UnixLineRequest.receiveTimeout(milliseconds: 1_500)
        XCTAssertEqual(long.tv_sec, 1)
        XCTAssertEqual(long.tv_usec, 500_000)

        let short = UnixLineRequest.receiveTimeout(milliseconds: 400)
        XCTAssertEqual(short.tv_sec, 0)
        XCTAssertEqual(short.tv_usec, 400_000)
    }

    func testSendRejectsAnOverlongSocketPath() async {
        do {
            _ = try await UnixLineRequest.send(path: "/" + String(repeating: "a", count: 200), line: "x\n", timeoutMilliseconds: 400)
            XCTFail("expected pathTooLong")
        } catch HerdrQueryError.pathTooLong {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
