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
///   (Foundation/Darwin only). Depends on `Shared/UnixSocketAddress.swift` and
///   `Shared/RelayPaths.swift`, which are compiled into both targets too.
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Prevent SIGPIPE from killing the process if the peer closes the connection mid-write;
        // short/failed writes are handled via return values instead.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let deadline = Date().addingTimeInterval(totalDeadline)
        // A missing socket (Relay not running), an overlong path, or a peer that never accepts
        // all fail here within the deadline.
        guard UnixSocketAddress.connect(fd, to: socketPath, withDeadline: deadline) else { return false }

        var outgoing = payload
        if outgoing.last != UInt8(ascii: "\n") {
            outgoing.append(UInt8(ascii: "\n"))
        }

        return outgoing.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var totalWritten = 0
            while totalWritten < rawBuf.count {
                guard UnixSocketAddress.waitWritable(fd: fd, deadline: deadline) else { return false }

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
}
