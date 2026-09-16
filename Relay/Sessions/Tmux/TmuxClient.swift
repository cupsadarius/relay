import Foundation

struct TmuxClientListing: Equatable, Sendable {
    let name: String
    let pid: Int32
}

protocol TmuxCommandRunning: Sendable {
    func listClients(socketPath: String) async throws -> [TmuxClientListing]
    func activePane(socketPath: String, clientName: String) async throws -> String
}

struct TmuxClient: TmuxCommandRunning {
    let executable: String
    let runner: ProcessRunning
    private let timeout: TimeInterval

    init(executable: String, runner: ProcessRunning = BoundedProcessRunner(), timeout: TimeInterval = 3) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    func listClients(socketPath: String) async throws -> [TmuxClientListing] {
        let output = try run(["-S", socketPath, "list-clients", "-F", "#{client_name}\\t#{client_pid}"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[1]) else { return nil }
            return .init(name: parts[0], pid: pid)
        }
    }

    func activePane(socketPath: String, clientName: String) async throws -> String {
        try run(["-S", socketPath, "display-message", "-p", "-c", clientName, "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String]) throws -> String {
        let result = try runner.run(executable: URL(fileURLWithPath: executable), arguments: arguments, timeout: timeout, maxOutputBytes: 256 * 1024)
        guard result.terminationStatus == 0 else { throw TmuxError.commandFailed }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

enum TmuxError: Error { case commandFailed }
