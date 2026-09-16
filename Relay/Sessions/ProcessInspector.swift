import Foundation

struct ProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let tty: String?
    let command: String
}

struct ProcessSnapshot: Sendable {
    private let records: [Int32: ProcessRecord]

    static func parse(_ output: String) throws -> ProcessSnapshot {
        var records: [Int32: ProcessRecord] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let fields = raw.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            let tty = fields[2] == "??" || fields[2] == "?" ? nil : fields[2]
            records[pid] = ProcessRecord(pid: pid, parentPID: ppid, tty: tty, command: fields[3])
        }
        return ProcessSnapshot(records: records)
    }

    func record(pid: Int32) -> ProcessRecord? { records[pid] }

    func ancestry(from pid: Int32) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var current = pid
        var visited = Set<Int32>()
        while current > 0, visited.insert(current).inserted, let record = records[current] {
            result.append(record)
            current = record.parentPID
        }
        return result
    }

    func descendants(of rootPID: Int32) -> [ProcessRecord] {
        records.values.filter { candidate in
            ancestry(from: candidate.pid).dropFirst().contains { $0.pid == rootPID }
        }
    }
}

struct ProcessInspector: Sendable {
    /// How long we'll wait for `ps` to produce output before giving up. `ps` over the full process
    /// table is normally a few milliseconds; 5s gives a huge margin for a loaded machine while still
    /// guaranteeing the caller (`AgentProcessContextCapture.capture`) gets a response instead of
    /// hanging its actor forever.
    private static let timeout: TimeInterval = 5

    /// Executable/arguments are injectable (defaulting to real `/bin/ps`) purely so tests can point
    /// this at a slow/blocking fake command to exercise the watchdog without touching the real
    /// process table.
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/bin/ps"),
        arguments: [String] = ["-axo", "pid=,ppid=,tty=,comm="],
        timeout: TimeInterval = ProcessInspector.timeout
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    func snapshot() throws -> ProcessSnapshot {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        // Redirect stderr to /dev/null rather than a Pipe: an unread Pipe fills its 64KB kernel
        // buffer and blocks the child on write, which is exactly the deadlock class this fix
        // exists to eliminate. We don't care about ps's stderr, so there's nothing to drain.
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Drain stdout on a background thread and signal completion via a semaphore that we wait
        // on with a deadline. This is the key ordering fix: we must read the pipe to EOF *before*
        // (or concurrently with) `waitUntilExit()`, because `ps` blocks writing to a full pipe and
        // `waitUntilExit()` blocks waiting for `ps` to exit — reading only after `waitUntilExit()`
        // returns is a guaranteed deadlock once output exceeds the pipe's kernel buffer (64KB).
        // Reading on a background thread (rather than just reordering to a synchronous
        // `readDataToEndOfFile()` before `waitUntilExit()`) additionally lets us bound the whole
        // operation with a timeout, so a hung/slow `ps` can never wedge the caller forever.
        let readSemaphore = DispatchSemaphore(value: 0)
        let dataBox = LockedBox<Data>(Data())
        let readQueue = DispatchQueue(label: "ProcessInspector.stdoutDrain")
        readQueue.async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            dataBox.value = data
            readSemaphore.signal()
        }

        let deadline = DispatchTime.now() + timeout
        guard readSemaphore.wait(timeout: deadline) == .success else {
            // Timed out: ps is hung or unreasonably slow. Ask it to terminate and give up rather
            // than blocking the caller forever. We deliberately do not wait (again) for exit here —
            // the caller treats a thrown error as "no context available" and degrades gracefully.
            process.terminate()
            throw ProcessInspectionError.timedOut
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        return try ProcessSnapshot.parse(String(decoding: dataBox.value, as: UTF8.self))
    }
}

/// Minimal `NSLock`-protected box used to hand the drained pipe data back from the background read
/// thread to `snapshot()` once the read semaphore has signaled. `Data` itself is `Sendable`, but the
/// box avoids relying on unsynchronized capture across the explicit `DispatchQueue.async` boundary.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

enum ProcessInspectionError: Error, Equatable { case psFailed, timedOut }

protocol ProcessTreeReading: Sendable {
    func ancestry(from pid: Int32) async throws -> [Int32]
}

extension ProcessInspector: ProcessTreeReading {
    func ancestry(from pid: Int32) async throws -> [Int32] {
        try snapshot().ancestry(from: pid).map(\.pid)
    }
}
