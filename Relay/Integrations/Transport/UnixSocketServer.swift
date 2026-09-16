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
    /// Another live process already owns this socket path — either a probe
    /// connect reached a real listener, or the single-instance lockfile is
    /// already held by another process. Relay must never unlink or rebind
    /// over an active owner.
    case activeListenerPresent
    /// The single-instance lockfile could not be opened/created for a
    /// reason other than it already being held (see `activeListenerPresent`
    /// for that case).
    case lockAcquisitionFailed(Int32)
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

    /// Maximum number of simultaneously open client connections. Beyond this,
    /// newly accepted file descriptors are closed immediately instead of
    /// tracked, so a same-user process cannot exhaust file descriptors or
    /// pin N x 2 MiB of per-connection receive buffers.
    static let maxConcurrentConnections = 32

    /// Backoff applied before re-arming the accept source after `accept`
    /// fails with `EMFILE`/`ENFILE`. Without this, a readable listen socket
    /// with fds exhausted would cause the dispatch source to re-fire and
    /// re-fail in a tight CPU spin.
    private static let acceptBackoff: DispatchTimeInterval = .milliseconds(100)

    /// Short poll deadline used by `probeLiveListener` when checking whether
    /// a peer is actually accepting on a candidate stale socket path. Kept
    /// well under a second so `start()` never stalls noticeably even when
    /// probing a completely unresponsive path.
    private static let probeDeadline: Int32 = 200 // milliseconds

    private let queue = DispatchQueue(label: "dev.relaymac.Relay.UnixSocketServer")
    private let diagnostics: IntegrationDiagnosticsLog

    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var acceptSourceSuspended = false
    private var socketPath: String?
    private var onLine: (@Sendable (String) -> Void)?
    private var connections: [Int32: ClientConnection] = [:]

    /// File descriptor for the single-instance lockfile (`<socketDir>/relay.lock`),
    /// held via `flock(LOCK_EX | LOCK_NB)` for the server's entire lifetime.
    /// `-1` when not held (not started, or already torn down).
    private var lockDescriptor: Int32 = -1

    init(diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()) {
        self.diagnostics = diagnostics
    }

    /// Whether the server currently holds an open listening socket. Reads
    /// are serialized through the same queue that owns `listenDescriptor`,
    /// so this never races `start`/`stop`.
    var isListening: Bool {
        queue.sync { listenDescriptor >= 0 }
    }

    /// Safety net for instances dropped without an explicit `stop()` call
    /// (e.g. a crash path, or a caller that simply forgets). Tears down
    /// dispatch sources and closes file descriptors so nothing leaks.
    ///
    /// - Important: `stop()` synchronizes onto `queue` via `queue.sync`.
    ///   `deinit` can, in principle, run synchronously *on* `queue` itself —
    ///   for example if a queue-scheduled closure holding the last strong
    ///   reference to this instance releases it as that closure returns.
    ///   Calling `stop()` (and its `queue.sync`) from such a `deinit` would
    ///   deadlock. Since no other reference to `self` can exist once `deinit`
    ///   runs, there is no concurrent access to guard against here, so
    ///   `deinit` calls the shared teardown directly, off `queue`, instead.
    deinit {
        performTeardown()
    }

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

            let acquiredLockFD = try acquireSingleInstanceLock(inDirectory: directory)

            do {
                try removeStaleSocketIfSafe(at: path)
            } catch {
                close(acquiredLockFD)
                throw error
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                close(acquiredLockFD)
                throw UnixSocketServerError.socketCreationFailed(errno)
            }
            Self.setNonBlocking(fd)

            do {
                try Self.bind(fd: fd, toPath: path)
            } catch {
                close(fd)
                close(acquiredLockFD)
                throw error
            }

            guard chmod(path, 0o600) == 0 else {
                let capturedErrno = errno
                close(fd)
                unlink(path)
                close(acquiredLockFD)
                throw UnixSocketServerError.chmodFailed(capturedErrno)
            }

            guard listen(fd, 8) == 0 else {
                let capturedErrno = errno
                close(fd)
                unlink(path)
                close(acquiredLockFD)
                throw UnixSocketServerError.listenFailed(capturedErrno)
            }

            listenDescriptor = fd
            socketPath = path
            lockDescriptor = acquiredLockFD
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
            performTeardown()
        }
    }

    /// Cancels every dispatch source, closes the listen/client file
    /// descriptors, and unlinks the socket path. Idempotent: safe to call
    /// when already stopped (or never started).
    ///
    /// - Important: must only be called while already confined to `queue`
    ///   (via `stop()`'s `queue.sync`) or from a context — such as `deinit`
    ///   — where no concurrent access to this instance's state is possible.
    ///   Never call this directly from arbitrary code still holding a
    ///   reference to the instance.
    private func performTeardown() {
        if acceptSourceSuspended {
            // Balance the suspend from the EMFILE/ENFILE backoff before
            // cancelling — cancelling a still-suspended dispatch source is
            // not guaranteed safe.
            acceptSource?.resume()
            acceptSourceSuspended = false
        }

        for (_, connection) in connections {
            connection.source?.cancel()
        }
        connections.removeAll()

        acceptSource?.cancel()
        acceptSource = nil

        if let path = socketPath {
            unlink(path)
        }

        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }

        listenDescriptor = -1
        socketPath = nil
        onLine = nil
    }

    // MARK: - Accept loop

    private func acceptPendingConnections(listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                let capturedErrno = errno
                if capturedErrno == EMFILE || capturedErrno == ENFILE {
                    // Transient fd exhaustion. The listen socket is still
                    // readable, so if we just returned, the dispatch source
                    // would re-fire immediately and re-fail `accept` in a
                    // tight CPU spin. Suspend the source and re-arm it after
                    // a brief backoff instead, giving fds elsewhere a chance
                    // to free up. (Hard to exercise deterministically in a
                    // unit test — this path is exercised manually/by review
                    // rather than by an automated fd-exhaustion test.)
                    if !acceptSourceSuspended, let source = acceptSource {
                        acceptSourceSuspended = true
                        source.suspend()
                        queue.asyncAfter(deadline: .now() + Self.acceptBackoff) { [weak self] in
                            guard let self else { return }
                            // `stop()` may have torn everything down while we
                            // were waiting; only resume if this is still the
                            // live, suspended accept source.
                            guard self.acceptSourceSuspended, let source = self.acceptSource else { return }
                            self.acceptSourceSuspended = false
                            source.resume()
                        }
                    }
                }
                break // EAGAIN/EWOULDBLOCK (no more pending) or another transient error.
            }

            guard connections.count < Self.maxConcurrentConnections else {
                // At the concurrent-connection cap: drop the new connection
                // immediately rather than tracking it, so a same-user
                // process cannot exhaust file descriptors or pin N x 2 MiB
                // of per-connection receive buffers. Keep draining the
                // accept backlog so it doesn't build up.
                close(clientFD)
                continue
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
    /// Unix-domain socket owned by the current user AND no live listener
    /// answers a probe connect. Any other kind of file (or a socket owned by
    /// someone else) is left untouched and surfaced as an error instead; a
    /// socket that does answer a probe connect is left untouched too — that
    /// is another process's live socket, not a crash leftover.
    private func removeStaleSocketIfSafe(at path: String) throws {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT {
                return // Nothing there; nothing to remove.
            }
            let capturedErrno = errno
            diagnostics.append(
                stage: "socket-ownership",
                outcome: "permission-failure",
                detail: capturedErrno == EACCES ? "lstat-denied" : "lstat-failed"
            )
            throw UnixSocketServerError.staleSocketCheckFailed(capturedErrno)
        }

        let isSocket = (info.st_mode & S_IFMT) == S_IFSOCK
        let ownedByCurrentUser = info.st_uid == getuid()
        guard isSocket, ownedByCurrentUser else {
            diagnostics.append(stage: "socket-ownership", outcome: "unsafe-path", detail: "not-owned-socket")
            throw UnixSocketServerError.unsafeStaleSocket
        }

        guard !Self.probeLiveListener(at: path) else {
            diagnostics.append(stage: "socket-ownership", outcome: "active-owner", detail: "probe-connected")
            throw UnixSocketServerError.activeListenerPresent
        }

        guard unlink(path) == 0 else {
            let capturedErrno = errno
            diagnostics.append(
                stage: "socket-ownership",
                outcome: "permission-failure",
                detail: capturedErrno == EACCES ? "unlink-denied" : "unlink-failed"
            )
            throw UnixSocketServerError.staleSocketRemovalFailed(capturedErrno)
        }
        diagnostics.append(stage: "socket-ownership", outcome: "stale-removed", detail: "no-live-listener")
    }

    /// Probes whether a live process is listening on the Unix-domain socket
    /// at `path` by attempting a non-blocking `connect()` with a short
    /// (~200 ms) deadline, mirroring `HerdrSocketClient`'s bounded-connect
    /// pattern. Returns `true` only when a peer actually accepts the
    /// connection; refusal, a missing path, or a timeout all read as `false`
    /// (safe to treat the path as stale). The probe file descriptor is
    /// always closed before returning.
    private static func probeLiveListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            let base = rawPath.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base.update(repeating: 0, count: rawPath.count)
            for (index, byte) in pathBytes.enumerated() {
                base[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            return true // Connected immediately: a live listener accepted us.
        }
        guard errno == EINPROGRESS else {
            return false // ECONNREFUSED, ENOENT, EACCES, etc. — no live listener.
        }

        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollDescriptor, 1, probeDeadline)
        guard pollResult > 0, (pollDescriptor.revents & Int16(POLLOUT)) != 0 else {
            return false // Timed out, or another poll error — treat as no listener.
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
            return false
        }
        return socketError == 0
    }

    /// Acquires the single-instance guard: an exclusive, non-blocking
    /// `flock` on `<directory>/relay.lock`, opened/created fresh for this
    /// call. `flock` locks are scoped to the *open file description*, so a
    /// second `open()` of the same lockfile — even from the same process —
    /// still contends for the lock; this is what lets two `UnixSocketServer`
    /// instances in one process (as in tests) correctly exercise the guard.
    ///
    /// Returns the held lockfile descriptor on success. The caller owns it
    /// and must close it (which releases the lock) during teardown.
    private func acquireSingleInstanceLock(inDirectory directory: String) throws -> Int32 {
        let lockPath = (directory as NSString).appendingPathComponent("relay.lock")
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else {
            let capturedErrno = errno
            diagnostics.append(stage: "socket-ownership", outcome: "permission-failure", detail: "lockfile-open-failed")
            throw UnixSocketServerError.lockAcquisitionFailed(capturedErrno)
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fd)
            if capturedErrno == EWOULDBLOCK {
                diagnostics.append(stage: "socket-ownership", outcome: "active-owner", detail: "lock-held")
                throw UnixSocketServerError.activeListenerPresent
            }
            diagnostics.append(stage: "socket-ownership", outcome: "permission-failure", detail: "lock-failed")
            throw UnixSocketServerError.lockAcquisitionFailed(capturedErrno)
        }

        return fd
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
