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
    func snapshot() throws -> ProcessSnapshot {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try ProcessSnapshot.parse(String(decoding: data, as: UTF8.self))
    }
}

enum ProcessInspectionError: Error { case psFailed }
