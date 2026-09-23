import Darwin
import Foundation

enum UnixSocketAddressError: Error, Equatable {
    case pathTooLong
}

/// `sockaddr_un` construction and bounded, non-blocking `connect` for local `AF_UNIX` stream
/// sockets — the single copy of code that used to be duplicated four times across
/// `UnixSocketServer`, `HookTransportClient`, and `UnixLineRequest`.
///
/// Compiled into BOTH the `Relay` app target and the `RelayHook` helper target. Darwin/Foundation
/// only.
enum UnixSocketAddress {
    /// Builds a fully initialised `sockaddr_un` for `path`: `sun_len`, `sun_family`, and a
    /// NUL-terminated `sun_path`. Throws `.pathTooLong` when `path` plus its terminator does not
    /// fit in `sun_path` (104 bytes on Darwin).
    static func make(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw UnixSocketAddressError.pathTooLong }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            rawPath.copyBytes(from: pathBytes)
        }
        return address
    }

    /// Calls `body` with `address` viewed as a generic `sockaddr` plus its length, for
    /// `bind`/`connect`.
    static func withSockaddr<Result>(
        _ address: sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    /// Connects `fd` to the socket at `path` without ever blocking past `deadline`. Leaves `fd`
    /// in NON-blocking mode; callers that want blocking I/O afterwards call
    /// `setNonBlocking(fd, false)`. Returns `true` only once the peer has accepted.
    static func connect(_ fd: Int32, to path: String, withDeadline deadline: Date) -> Bool {
        guard let address = try? make(path: path) else { return false }
        setNonBlocking(fd, true)
        let result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        guard waitWritable(fd: fd, deadline: deadline) else { return false }

        // poll(POLLOUT) also fires for a failed connect; confirm success explicitly.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    /// Sets or clears `O_NONBLOCK` on `fd`. Best-effort.
    static func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }

    /// Waits, via `poll()`, for `fd` to become writable, bounded by `deadline`. Returns `false`
    /// once the deadline has elapsed, or if `poll` reports error/hang-up.
    static func waitWritable(fd: Int32, deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }

            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let timeoutMilliseconds = Int32(min(remaining * 1000, Double(Int32.max - 1)))
            let result = poll(&descriptor, 1, max(timeoutMilliseconds, 0))

            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if result == 0 { return false }

            let badEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if (descriptor.revents & badEvents) != 0 { return false }
            return (descriptor.revents & Int16(POLLOUT)) != 0
        }
    }
}
