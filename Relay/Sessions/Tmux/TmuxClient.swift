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
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TmuxError.commandFailed }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

enum TmuxError: Error { case commandFailed }
