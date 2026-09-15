import Foundation

protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool
}

struct HerdrHostOwnershipChecker: HerdrHostOwnershipChecking {
    let processInspector: ProcessInspector

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
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return false }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-U", "-Fn"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.first == "n" && String(line.dropFirst()) == socketPath
        }
    }
}
