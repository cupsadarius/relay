import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Sends a single newline-delimited line over a local `AF_UNIX` stream
/// socket, bounded end-to-end (connect + write) by `totalDeadline`.
///
/// Hook delivery is optional: Relay must never make the calling coding
/// agent less reliable. If the peer is unreachable, half-open, or simply
/// not draining its receive buffer, `send` gives up cleanly once the
/// deadline elapses instead of blocking the caller indefinitely.
///
/// - Important: this file is compiled into both the `RelayHook` executable
///   target and the `Relay` app target (see `project.yml`) so it can be
///   unit tested via `@testable import Relay`. Keep it self-contained
///   (Foundation/Darwin only).
struct HookTransportClient {
    let socketPath: String
    let totalDeadline: TimeInterval

    init(socketPath: String, totalDeadline: TimeInterval = 0.4) {
        self.socketPath = socketPath
        self.totalDeadline = totalDeadline
    }

    /// The socket for the running helper, derived from this executable's own location
    /// (`<support>/bin/RelayHook` -> `<support>/relay.sock`), else the Release socket. Only
    /// meaningful inside `RelayHook`; in the app target it always yields the Release socket.
    static var defaultSocketPath: String {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
        return RelayPaths.socketPath(forHelperExecutablePath: executablePath)
    }

    /// Attempts to deliver `payload` (appending a trailing `\n` if missing)
    /// within `totalDeadline`. Returns `true` once the full payload has
    /// been handed to the kernel, `false` on any failure or timeout.
    ///
    /// Never throws and never blocks past the deadline: a missing socket,
    /// a peer that never accepts, or a peer that accepts but never drains
    /// its receive buffer all resolve to `false` within `totalDeadline`.
    @discardableResult
    func send(_ payload: Data) -> Bool {
        let pathBytes = Array(socketPath.utf8)
        var addr = sockaddr_un()
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathCapacity else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Prevent SIGPIPE from killing the process if the peer closes the
        // connection mid-write; short/failed writes are handled via return
        // values instead.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        Self.setNonBlocking(fd)

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            let base = rawBuf.baseAddress!
            memset(base, 0, rawBuf.count)
            pathBytes.withUnsafeBufferPointer { pathBuf in
                _ = memcpy(base, pathBuf.baseAddress, pathBuf.count)
            }
        }

        let deadline = Date().addingTimeInterval(totalDeadline)

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        if connectResult != 0 {
            // Non-blocking connect: in progress is expected. Anything else
            // (e.g. ENOENT/ECONNREFUSED because Relay isn't running) fails
            // immediately, which is the common and expected case.
            guard errno == EINPROGRESS else { return false }
            guard Self.waitWritable(fd: fd, deadline: deadline) else { return false }

            // poll(POLLOUT) fires on a failed connect too; confirm success.
            var socketError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            let status = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)
            guard status == 0, socketError == 0 else { return false }
        }

        var outgoing = payload
        if outgoing.last != UInt8(ascii: "\n") {
            outgoing.append(UInt8(ascii: "\n"))
        }

        return outgoing.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var totalWritten = 0
            while totalWritten < rawBuf.count {
                guard Self.waitWritable(fd: fd, deadline: deadline) else { return false }

                let written = write(fd, base + totalWritten, rawBuf.count - totalWritten)
                if written > 0 {
                    totalWritten += written
                    continue
                }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue // Spurious wake or interrupt; poll again with the remaining budget.
                }
                return false
            }
            return true
        }
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Waits, via `poll()`, for `fd` to become writable, bounded by the
    /// time remaining until `deadline`. Returns `false` once the deadline
    /// has elapsed, or if `poll` reports the descriptor is in error/hung up.
    private static func waitWritable(fd: Int32, deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remainingMilliseconds = remaining * 1000
            let timeoutMilliseconds = Int32(min(remainingMilliseconds, Double(Int32.max - 1)))
            let result = poll(&pfd, 1, max(timeoutMilliseconds, 0))

            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if result == 0 { return false } // Timed out.

            let badEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if (pfd.revents & badEvents) != 0 { return false }
            return (pfd.revents & Int16(POLLOUT)) != 0
        }
    }
}
