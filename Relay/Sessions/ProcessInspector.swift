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
    /// guaranteeing the caller (e.g. `AgentAutoReadCoordinator.handle(_:)`) gets a response instead
    /// of hanging its actor forever.
    private static let timeout: TimeInterval = 5

    /// Executable/arguments are injectable (defaulting to real `/bin/ps`) purely so tests can point
    /// this at a slow/blocking fake command to exercise the watchdog without touching the real
    /// process table.
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let runner: ProcessRunning

    init(
        executableURL: URL = URL(fileURLWithPath: "/bin/ps"),
        arguments: [String] = ["-axo", "pid=,ppid=,tty=,comm="],
        timeout: TimeInterval = ProcessInspector.timeout,
        runner: ProcessRunning = BoundedProcessRunner()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.runner = runner
    }

    func snapshot() async throws -> ProcessSnapshot {
        let result: ProcessResult
        do {
            result = try await runner.run(executable: executableURL, arguments: arguments, timeout: timeout, maxOutputBytes: 4 * 1024 * 1024)
        } catch BoundedProcessError.timedOut {
            throw ProcessInspectionError.timedOut
        } catch {
            throw ProcessInspectionError.psFailed
        }
        guard result.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        return try ProcessSnapshot.parse(String(decoding: result.stdout, as: UTF8.self))
    }
}

enum ProcessInspectionError: Error, Equatable { case psFailed, timedOut }

/// Source of process-table snapshots (`ProcessInspector`'s real `ps` in production).
protocol ProcessSnapshotProviding: Sendable {
    func snapshot() async throws -> ProcessSnapshot
}

extension ProcessInspector: ProcessSnapshotProviding {}
