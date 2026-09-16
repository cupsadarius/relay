import Foundation

protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool
}

struct HerdrHostOwnershipChecker: HerdrHostOwnershipChecking {
    /// How long we'll wait for `lsof` to produce output before giving up. `lsof -a -p <pid> -U -Fn`
    /// against a single process's open unix sockets is normally a few milliseconds, but this check
    /// runs on the focus path, so a short timeout keeps a hung/misbehaving `lsof` from blocking focus
    /// resolution indefinitely.
    private static let defaultTimeout: TimeInterval = 2

    let processInspector: ProcessInspector

    /// Executable/arguments/timeout are injectable (defaulting to real `/usr/sbin/lsof` and its
    /// normal arguments) purely so tests can point the ownership check at a slow/blocking fake
    /// command to exercise the watchdog without touching real sockets.
    private let lsofExecutableURL: URL
    private let lsofArguments: @Sendable (Int32) -> [String]
    private let lsofTimeout: TimeInterval

    init(
        processInspector: ProcessInspector,
        lsofExecutableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        lsofArguments: @escaping @Sendable (Int32) -> [String] = { pid in ["-a", "-p", String(pid), "-U", "-Fn"] },
        lsofTimeout: TimeInterval = HerdrHostOwnershipChecker.defaultTimeout
    ) {
        self.processInspector = processInspector
        self.lsofExecutableURL = lsofExecutableURL
        self.lsofArguments = lsofArguments
        self.lsofTimeout = lsofTimeout
    }

    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool {
        guard let snapshot = try? processInspector.snapshot() else { return false }
        let candidates = snapshot.descendants(of: frontmostPID).filter {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased() == "herdr"
        }
        for candidate in candidates where lsof(pid: candidate.pid, contains: socketPath) {
            return true
        }
        return false
    }

    private func lsof(pid: Int32, contains socketPath: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: lsofExecutableURL.path) else { return false }
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = lsofExecutableURL
        process.arguments = lsofArguments(pid)
        process.standardOutput = stdoutPipe
        // Redirect stderr to /dev/null rather than a Pipe: an unread Pipe fills its 64KB kernel
        // buffer and blocks the child on write, which is exactly the deadlock class this fix
        // exists to eliminate. We don't care about lsof's stderr, so there's nothing to drain.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return false }

        // Drain stdout on a background thread and signal completion via a semaphore that we wait
        // on with a deadline. This is the key ordering fix: we must read the pipe to EOF *before*
        // (or concurrently with) `waitUntilExit()`, because a misbehaving child blocks writing to a
        // full pipe and `waitUntilExit()` blocks waiting for the child to exit — reading only after
        // `waitUntilExit()` returns is a guaranteed deadlock once output exceeds the pipe's kernel
        // buffer (64KB). Reading on a background thread also lets us bound the whole operation with
        // a timeout, so a hung `lsof` can never wedge the focus path forever. Mirrors
        // `ProcessInspector.snapshot()` (see that file for the fuller rationale).
        let readSemaphore = DispatchSemaphore(value: 0)
        let dataBox = LockedBox<Data>(Data())
        let readQueue = DispatchQueue(label: "HerdrHostOwnershipChecker.stdoutDrain")
        readQueue.async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            dataBox.value = data
            readSemaphore.signal()
        }

        let deadline = DispatchTime.now() + lsofTimeout
        guard readSemaphore.wait(timeout: deadline) == .success else {
            // Timed out: lsof is hung or unreasonably slow. Ask it to terminate and give up rather
            // than blocking the focus path forever. Ownership is unproven, so the conservative
            // fallback is "frontmost app does not own this client" (false), never a crash or hang.
            process.terminate()
            return false
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let text = String(decoding: dataBox.value, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.first == "n" && String(line.dropFirst()) == socketPath
        }
    }
}

/// Minimal `NSLock`-protected box used to hand the drained pipe data back from the background read
/// thread to `lsof(pid:contains:)` once the read semaphore has signaled. `Data` itself is
/// `Sendable`, but the box avoids relying on unsynchronized capture across the explicit
/// `DispatchQueue.async` boundary. Mirrors `ProcessInspector`'s private `LockedBox`; kept as a local
/// file-private copy rather than a shared type since both are file-scoped `private` helpers.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
