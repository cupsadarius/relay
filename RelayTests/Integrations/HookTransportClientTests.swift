import Darwin
import Foundation
import XCTest

@testable import Relay

final class HookTransportClientTests: XCTestCase {
    func testMissingSocketReturnsQuicklyWithoutHanging() {
        let start = Date()
        let client = HookTransportClient(socketPath: "/tmp/relay-nonexistent-\(UUID().uuidString).sock", totalDeadline: 0.4)
        _ = client.send(Data("{}".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testPeerThatNeverReadsDoesNotBlockPastDeadline() throws {
        let path = "/tmp/relay-slowpeer-\(UUID().uuidString).sock"
        let server = TestAcceptOnlyServer(path: path)
        defer { server.stop() }
        let start = Date()
        let client = HookTransportClient(socketPath: path, totalDeadline: 0.4)
        _ = client.send(Data(repeating: 0x41, count: 2 * 1024 * 1024))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testDeliversSuccessfullyToAReadingPeer() throws {
        let path = "/tmp/relay-goodpeer-\(UUID().uuidString).sock"
        let server = try ReadingTestServer(path: path)
        defer { server.stop() }
        let client = HookTransportClient(socketPath: path, totalDeadline: 0.4)
        let delivered = client.send(Data("hello".utf8))
        XCTAssertTrue(delivered)
        let received = server.waitForLine(timeout: 1.0)
        XCTAssertEqual(received, "hello")
    }
}

final class BoundedStdinReaderTests: XCTestCase {
    func testReadsInputUnderTheCapInFull() {
        let pipe = Pipe()
        let payload = Data("hello world".utf8)
        pipe.fileHandleForWriting.write(payload)
        try? pipe.fileHandleForWriting.close()

        let result = BoundedStdinReader.read(from: pipe.fileHandleForReading, maxBytes: 1_500 * 1_024)
        XCTAssertEqual(result, payload)
    }

    func testStopsAtCapWithoutBufferingTheEntireOversizedInput() {
        let pipe = Pipe()
        let maxBytes = 64 * 1024
        let oversized = Data(repeating: 0x41, count: 8 * 1024 * 1024) // far larger than the cap

        let writerThread = Thread {
            // A blocking pipe write large enough to exceed the pipe's
            // kernel buffer will itself block until drained; running it on
            // its own thread keeps the reader (and this test) from
            // deadlocking against it.
            _ = try? pipe.fileHandleForWriting.write(contentsOf: oversized)
            try? pipe.fileHandleForWriting.close()
        }
        writerThread.start()

        let start = Date()
        let result = BoundedStdinReader.read(from: pipe.fileHandleForReading, maxBytes: maxBytes)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertGreaterThan(result.count, maxBytes, "reader must detect the input exceeds the cap")
        XCTAssertLessThanOrEqual(result.count, maxBytes + 1, "reader must never buffer more than the cap plus one sentinel byte")
    }
}

/// Minimal `AF_UNIX` server used only by tests: binds, listens, accepts
/// connections on a background dispatch queue, and never reads from them —
/// used to simulate a hung/half-open Relay peer. Mirrors the socket setup in
/// `Relay/Integrations/Transport/UnixSocketServer.swift`.
final class TestAcceptOnlyServer {
    private let listenFD: Int32
    private let path: String
    private let queue = DispatchQueue(label: "test-accept-only-server")
    private var source: DispatchSourceRead?
    private var acceptedFDs: [Int32] = []

    init(path: String) {
        self.path = path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "failed to create test socket")
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.baseAddress!
            memset(base, 0, raw.count)
            pathBytes.withUnsafeBufferPointer { pathBuf in
                _ = memcpy(base, pathBuf.baseAddress, pathBuf.count)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bindResult == 0, "failed to bind test socket")
        precondition(listen(fd, 8) == 0, "failed to listen on test socket")

        self.listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break } // EAGAIN: nothing more pending.
            acceptedFDs.append(clientFD) // Intentionally never read from it.
        }
    }

    func stop() {
        queue.sync {
            for fd in acceptedFDs { close(fd) }
            acceptedFDs.removeAll()
        }
        source?.cancel()
        source = nil
        unlink(path)
    }
}

/// A test `AF_UNIX` server that reads one newline-delimited line and hands
/// it back to the test via `waitForLine`.
final class ReadingTestServer {
    private let listenFD: Int32
    private let path: String
    private let queue = DispatchQueue(label: "test-reading-server")
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private let semaphore = DispatchSemaphore(value: 0)
    private var line: String?

    init(path: String) throws {
        self.path = path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.baseAddress!
            memset(base, 0, raw.count)
            pathBytes.withUnsafeBufferPointer { pathBuf in
                _ = memcpy(base, pathBuf.baseAddress, pathBuf.count)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bindResult == 0)
        precondition(listen(fd, 8) == 0)
        self.listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { close(fd) }
        self.acceptSource = source
        source.resume()
    }

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            let readFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, readFlags | O_NONBLOCK)
            let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            readSource.setEventHandler { [weak self] in
                self?.handleReadable(clientFD)
            }
            readSource.setCancelHandler { close(clientFD) }
            self.readSource = readSource
            readSource.resume()
        }
    }

    private func handleReadable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, raw.count)
        }
        guard count > 0 else { return }
        buffer.append(contentsOf: chunk[0..<count])
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            line = String(decoding: buffer[buffer.startIndex..<newlineIndex], as: UTF8.self)
            semaphore.signal()
        }
    }

    func waitForLine(timeout: TimeInterval) -> String? {
        _ = semaphore.wait(timeout: .now() + timeout)
        return queue.sync { line }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }
}
