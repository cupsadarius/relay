import Foundation

struct ProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let command: String
}

struct ProcessSnapshot: Sendable {
    private let records: [Int32: ProcessRecord]

    static func parse(_ output: String) -> ProcessSnapshot {
        var records: [Int32: ProcessRecord] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let fields = raw.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3,
                let pid = Int32(fields[0]),
                let ppid = Int32(fields[1])
            else { continue }
            records[pid] = ProcessRecord(pid: pid, parentPID: ppid, command: fields[2])
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
    /// Bounds `ps` so a caller such as `AgentAutoReadCoordinator.handle(_:)` never hangs its actor.
    private static let timeout: TimeInterval = 5

    private let runner: ProcessRunning

    init(runner: ProcessRunning = BoundedProcessRunner()) {
        self.runner = runner
    }

    func snapshot() async throws -> ProcessSnapshot {
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,comm="],
                timeout: Self.timeout,
                maxOutputBytes: 4 * 1024 * 1024
            )
        } catch BoundedProcessError.timedOut {
            throw ProcessInspectionError.timedOut
        } catch {
            throw ProcessInspectionError.psFailed
        }
        guard result.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        return ProcessSnapshot.parse(String(decoding: result.stdout, as: UTF8.self))
    }
}

enum ProcessInspectionError: Error, Equatable { case psFailed, timedOut }

/// Source of process-table snapshots (`ProcessInspector`'s real `ps` in production).
protocol ProcessSnapshotProviding: Sendable {
    func snapshot() async throws -> ProcessSnapshot
}

extension ProcessInspector: ProcessSnapshotProviding {}
