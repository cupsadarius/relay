import Foundation

protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool
}

struct HerdrHostOwnershipChecker: HerdrHostOwnershipChecking {
    /// This check runs on the focus path, so a hung `lsof` must not block focus resolution.
    private static let lsofTimeout: TimeInterval = 2
    private static let lsofExecutableURL = URL(fileURLWithPath: "/usr/sbin/lsof")

    private let runner: ProcessRunning

    init(runner: ProcessRunning = BoundedProcessRunner()) {
        self.runner = runner
    }

    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool {
        let candidates = processSnapshot.descendants(of: frontmostPID).filter {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased() == "herdr"
        }
        for candidate in candidates {
            if await lsof(pid: candidate.pid, contains: socketPath) { return true }
        }
        return false
    }

    private func lsof(pid: Int32, contains socketPath: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.lsofExecutableURL.path) else { return false }
        // Ownership is unproven on any failure, so the fallback is always `false`.
        guard
            let result = try? await runner.run(
                executable: Self.lsofExecutableURL,
                arguments: ["-a", "-p", String(pid), "-U", "-Fn"],
                timeout: Self.lsofTimeout,
                maxOutputBytes: 1024 * 1024
            )
        else {
            return false
        }
        guard result.terminationStatus == 0 else { return false }
        let text = String(decoding: result.stdout, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.first == "n" && String(line.dropFirst()) == socketPath
        }
    }
}
