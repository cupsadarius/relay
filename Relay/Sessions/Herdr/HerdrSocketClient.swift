import Darwin
import Foundation

protocol HerdrQuerying: Sendable {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo
}

struct HerdrSocketClient: HerdrQuerying {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo {
        let request = #"{"id":"relay_focus","method":"pane.current","params":{}}"# + "\n"
        let line = try await UnixLineRequest.send(path: socketPath, line: request, timeoutMilliseconds: 400)
        let response = try JSONDecoder().decode(HerdrResponse.self, from: Data(line.utf8))
        guard let pane = response.result?.pane else { throw HerdrQueryError.invalidResponse }
        return HerdrPaneInfo(paneID: pane.paneID, focused: pane.focused, agentSession: pane.agentSession)
    }
}

enum HerdrQueryError: Error { case invalidResponse, socketFailure, pathTooLong, responseTooLarge, timedOut }

enum UnixLineRequest {
    /// Upper bound on total request duration, comfortably above the per-recv
    /// timeout, so a peer that dribbles bytes without a trailing newline
    /// cannot hold the detached I/O thread indefinitely.
    private static let totalDeadlineNanoseconds: UInt64 = 1_000_000_000 // 1 second

    /// Dedicated queue for the blocking socket I/O in `sendBlocking`, so a slow herdr peer ties
    /// up one of this queue's threads instead of a Swift Concurrency cooperative-pool thread
    /// (which `Task.detached` would have used).
    private static let ioQueue = DispatchQueue(
        label: "dev.relaymac.Relay.UnixLineRequest",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func send(path: String, line: String, timeoutMilliseconds: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(
                    with: Result {
                        try sendBlocking(path: path, line: line, timeoutMilliseconds: timeoutMilliseconds)
                    })
            }
        }
    }

    private static func sendBlocking(path: String, line: String, timeoutMilliseconds: Int32) throws -> String {
        let deadline = DispatchTime.now() + .nanoseconds(Int(totalDeadlineNanoseconds))
        guard (try? UnixSocketAddress.make(path: path)) != nil else {
            throw HerdrQueryError.pathTooLong
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrQueryError.socketFailure }
        defer { Darwin.close(fd) }

        // Prevent SIGPIPE from killing Relay if herdr closes the connection mid-write; short/
        // failed writes are handled via return values instead (as HookTransportClient does).
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let connectDeadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        guard UnixSocketAddress.connect(fd, to: path, withDeadline: connectDeadline) else {
            throw HerdrQueryError.socketFailure
        }
        // Back to blocking I/O; each read/write below is bounded by SO_RCVTIMEO/SO_SNDTIMEO and
        // the whole request by `deadline`.
        UnixSocketAddress.setNonBlocking(fd, false)

        var tv = receiveTimeout(milliseconds: timeoutMilliseconds)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        let bytes = Array(line.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            guard wrote > 0 else { throw HerdrQueryError.socketFailure }
            sent += wrote
        }

        let maxResponseBytes = 64 * 1024
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while response.count <= maxResponseBytes {
            guard DispatchTime.now() < deadline else { throw HerdrQueryError.timedOut }

            let toRead = min(chunk.count, maxResponseBytes - response.count + 1)
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, toRead)
            }
            guard count > 0 else { throw HerdrQueryError.socketFailure }

            if let newlineIndex = chunk[0..<count].firstIndex(of: 0x0A) {
                response.append(contentsOf: chunk[0..<newlineIndex])
                return String(decoding: response, as: UTF8.self)
            }
            response.append(contentsOf: chunk[0..<count])
        }
        throw HerdrQueryError.responseTooLarge
    }

    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` value for `milliseconds`, split into whole seconds plus the
    /// microsecond remainder (`tv_usec` must stay below 1_000_000).
    static func receiveTimeout(milliseconds: Int32) -> timeval {
        timeval(tv_sec: Int(milliseconds / 1_000), tv_usec: Int32((milliseconds % 1_000) * 1_000))
    }
}
