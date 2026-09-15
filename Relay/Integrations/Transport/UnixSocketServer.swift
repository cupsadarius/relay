import Darwin
import Foundation

/// Errors surfaced by `UnixSocketServer.start(path:onLine:)`.
///
/// The associated `Int32` values are the `errno` captured at the point of
/// failure, when applicable.
enum UnixSocketServerError: Error, Equatable {
    case alreadyStarted
    case pathTooLong
    case directoryCreationFailed(Int32)
    case staleSocketCheckFailed(Int32)
    /// A file already exists at the socket path and is either not a Unix
    /// domain socket or is not owned by the current user. Relay must never
    /// delete or `chmod` such a path.
    case unsafeStaleSocket
    case staleSocketRemovalFailed(Int32)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case chmodFailed(Int32)
    case listenFailed(Int32)
}

/// A minimal local Unix-domain socket server for receiving newline-delimited
/// UTF-8 JSON lines from the bundled `RelayHook` helper.
///
/// All mutable state is confined to `queue`, a dedicated serial
/// `DispatchQueue`. The listening socket and every accepted client
/// connection are driven by non-blocking `DispatchSourceRead` readers
/// registered on that same queue, so no thread ever blocks inside `accept`
/// or `read`. This keeps `start`/`stop` free of deadlocks while still
/// satisfying "accept clients on the server queue".
///
/// - Important: never logs or otherwise surfaces line contents. Callers are
///   responsible for keeping their `onLine` closures privacy-safe as well.
final class UnixSocketServer: @unchecked Sendable {
    /// Maximum size, in bytes, of a single newline-delimited line. Matches
    /// the Relay hook transport's global 2 MiB envelope limit.
    static let maxLineBytes = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "dev.relaymac.Relay.UnixSocketServer")

    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketPath: String?
    private var onLine: (@Sendable (String) -> Void)?
    private var connections: [Int32: ClientConnection] = [:]

    init() {}

    /// Starts listening on the Unix-domain socket at `path`.
    ///
    /// - Parameters:
    ///   - path: filesystem path for the socket, e.g.
    ///     `~/Library/Application Support/Relay/relay.sock`.
    ///   - onLine: invoked once per newline-delimited line received from a
    ///     client, on the server's private serial queue. Must be
    ///     `Sendable`-safe; it is never invoked concurrently with itself.
    func start(path: String, onLine: @escaping @Sendable (String) -> Void) throws {
        try queue.sync {
            guard listenDescriptor < 0 else {
                throw UnixSocketServerError.alreadyStarted
            }

            let directory = (path as NSString).deletingLastPathComponent
            try Self.ensureParentDirectoryExists(directory)
            try Self.removeStaleSocketIfSafe(at: path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw UnixSocketServerError.socketCreationFailed(errno)
            }
            Self.setNonBlocking(fd)

            do {
                try Self.bind(fd: fd, toPath: path)
            } catch {
                close(fd)
                throw error
            }

            guard chmod(path, 0o600) == 0 else {
                let capturedErrno = errno
                close(fd)
                unlink(path)
                throw UnixSocketServerError.chmodFailed(capturedErrno)
            }

            guard listen(fd, 8) == 0 else {
                let capturedErrno = errno
                close(fd)
                unlink(path)
                throw UnixSocketServerError.listenFailed(capturedErrno)
            }

            listenDescriptor = fd
            socketPath = path
            self.onLine = onLine

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptPendingConnections(listenFD: fd)
            }
            source.setCancelHandler {
                close(fd)
            }
            acceptSource = source
            source.resume()
        }
    }

    /// Stops listening, closes every open connection, and unlinks the
    /// socket path this instance created — never any other path.
    func stop() {
        queue.sync {
            for (_, connection) in connections {
                connection.source?.cancel()
            }
            connections.removeAll()

            acceptSource?.cancel()
            acceptSource = nil

            if let path = socketPath {
                unlink(path)
            }

            listenDescriptor = -1
            socketPath = nil
            onLine = nil
        }
    }

    // MARK: - Accept loop

    private func acceptPendingConnections(listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                break // EAGAIN/EWOULDBLOCK (no more pending) or a transient error.
            }
            Self.setNonBlocking(clientFD)
            Self.growReceiveBuffer(clientFD)
            beginReading(clientFD: clientFD)
        }
    }

    private func beginReading(clientFD: Int32) {
        let connection = ClientConnection(fd: clientFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable(clientFD: clientFD)
        }
        source.setCancelHandler {
            close(clientFD)
        }
        connection.source = source
        connections[clientFD] = connection
        source.resume()
    }

    private func handleReadable(clientFD: Int32) {
        guard let connection = connections[clientFD] else { return }

        var readBuffer = [UInt8](repeating: 0, count: 256 * 1024)
        let bytesRead = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
            read(clientFD, rawBuffer.baseAddress, rawBuffer.count)
        }

        if bytesRead > 0 {
            let shouldClose = connection.append(
                bytes: readBuffer[0..<bytesRead],
                onLine: onLine
            )
            if shouldClose {
                closeConnection(clientFD)
            }
        } else if bytesRead == 0 {
            closeConnection(clientFD) // EOF
        } else {
            let capturedErrno = errno
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                return
            }
            closeConnection(clientFD)
        }
    }

    private func closeConnection(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.source?.cancel()
    }

    // MARK: - Setup helpers

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Widens the kernel receive buffer on an accepted connection so a
    /// legitimate envelope near the 2 MiB limit can arrive in a handful of
    /// `read` calls instead of many small ones. Best-effort: a failure here
    /// is not fatal, it just falls back to the OS default buffer size.
    private static func growReceiveBuffer(_ fd: Int32) {
        var size = Int32(maxLineBytes)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func ensureParentDirectoryExists(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw UnixSocketServerError.directoryCreationFailed(errno)
        }
    }

    /// Removes a stale socket file at `path` only when it is verifiably a
    /// Unix-domain socket owned by the current user. Any other kind of file
    /// (or a socket owned by someone else) is left untouched and surfaced
    /// as an error instead.
    private static func removeStaleSocketIfSafe(at path: String) throws {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT {
                return // Nothing there; nothing to remove.
            }
            throw UnixSocketServerError.staleSocketCheckFailed(errno)
        }

        let isSocket = (info.st_mode & S_IFMT) == S_IFSOCK
        let ownedByCurrentUser = info.st_uid == getuid()
        guard isSocket, ownedByCurrentUser else {
            throw UnixSocketServerError.unsafeStaleSocket
        }

        guard unlink(path) == 0 else {
            throw UnixSocketServerError.staleSocketRemovalFailed(errno)
        }
    }

    private static func bind(fd: Int32, toPath path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw UnixSocketServerError.pathTooLong
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            let base = rawPath.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base.update(repeating: 0, count: rawPath.count)
            for (index, byte) in pathBytes.enumerated() {
                base[index] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            throw UnixSocketServerError.bindFailed(errno)
        }
    }
}

/// Per-connection buffering state, confined to `UnixSocketServer`'s serial
/// queue. Not `Sendable`: never touch it off that queue.
private final class ClientConnection {
    let fd: Int32
    var source: DispatchSourceRead?
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    /// Appends newly read bytes, emitting one `onLine` call per
    /// newline-delimited line found. Returns `true` when the connection
    /// must be closed because a line exceeded the maximum size without a
    /// newline ever arriving — this bounds memory growth instead of
    /// buffering an unbounded amount of data.
    func append(bytes: ArraySlice<UInt8>, onLine: (@Sendable (String) -> Void)?) -> Bool {
        buffer.append(contentsOf: bytes)

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = buffer[buffer.startIndex..<newlineIndex]
            defer { buffer.removeSubrange(buffer.startIndex...newlineIndex) }

            guard lineBytes.count <= UnixSocketServer.maxLineBytes else {
                continue // Oversized but newline-terminated: drop silently.
            }
            if let line = String(bytes: lineBytes, encoding: .utf8) {
                onLine?(line)
            }
        }

        if buffer.count > UnixSocketServer.maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
            return true
        }
        return false
    }
}
