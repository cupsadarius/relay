import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Sends a single newline-delimited line over a local `AF_UNIX` stream socket.
///
/// This helper is intentionally minimal: it opens a connection, writes one
/// line, and closes. Any failure (Relay not running, socket missing, etc.)
/// is surfaced as a thrown error so the caller can swallow it silently.
struct HookTransportClient {
    enum TransportError: Error {
        case pathTooLong
        case socketCreationFailed
        case connectFailed
        case writeIncomplete
    }

    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Default Relay socket location: `~/Library/Application Support/Relay/relay.sock`.
    static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Relay/relay.sock")
            .path
    }

    /// Connects to the socket, writes `line` (appending `\n` if missing), then closes.
    func send(line: String) throws {
        let pathBytes = Array(socketPath.utf8)

        var addr = sockaddr_un()
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathCapacity else {
            throw TransportError.pathTooLong
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.socketCreationFailed
        }
        defer { close(fd) }

        // Prevent SIGPIPE from killing the process if the peer closes the
        // connection mid-write; we handle short/failed writes via return
        // values instead.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            let base = rawBuf.baseAddress!
            memset(base, 0, rawBuf.count)
            pathBytes.withUnsafeBufferPointer { pathBuf in
                _ = memcpy(base, pathBuf.baseAddress, pathBuf.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw TransportError.connectFailed
        }

        var payload = Array(line.utf8)
        if payload.last != UInt8(ascii: "\n") {
            payload.append(UInt8(ascii: "\n"))
        }

        var totalWritten = 0
        try payload.withUnsafeBufferPointer { buf -> Void in
            guard let base = buf.baseAddress else { return }
            while totalWritten < buf.count {
                let written = write(fd, base + totalWritten, buf.count - totalWritten)
                if written <= 0 {
                    throw TransportError.writeIncomplete
                }
                totalWritten += written
            }
        }
    }
}
