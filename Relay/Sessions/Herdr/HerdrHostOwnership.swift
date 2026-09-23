import Foundation

protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool
}

struct HerdrHostOwnershipChecker: HerdrHostOwnershipChecking {
    /// How long we'll wait for `lsof` to produce output before giving up. `lsof -a -p <pid> -U -Fn`
    /// against a single process's open unix sockets is normally a few milliseconds, but this check
    /// runs on the focus path, so a short timeout keeps a hung/misbehaving `lsof` from blocking focus
    /// resolution indefinitely.
    private static let defaultTimeout: TimeInterval = 2

    /// Executable/arguments/timeout are injectable (defaulting to real `/usr/sbin/lsof` and its
    /// normal arguments) purely so tests can point the ownership check at a slow/blocking fake
    /// command to exercise the watchdog without touching real sockets.
    private let lsofExecutableURL: URL
    private let lsofArguments: @Sendable (Int32) -> [String]
    private let lsofTimeout: TimeInterval
    private let runner: ProcessRunning

    init(
        lsofExecutableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        lsofArguments: @escaping @Sendable (Int32) -> [String] = { pid in ["-a", "-p", String(pid), "-U", "-Fn"] },
        lsofTimeout: TimeInterval = HerdrHostOwnershipChecker.defaultTimeout,
        runner: ProcessRunning = BoundedProcessRunner()
    ) {
        self.lsofExecutableURL = lsofExecutableURL
        self.lsofArguments = lsofArguments
        self.lsofTimeout = lsofTimeout
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
        guard FileManager.default.isExecutableFile(atPath: lsofExecutableURL.path) else { return false }
        // Bounded via the shared runner (stderr discarded, stdout drained, `lsofTimeout`).
        // Ownership is unproven on any failure, so the fallback is always `false`.
        guard
            let result = try? await runner.run(executable: lsofExecutableURL, arguments: lsofArguments(pid), timeout: lsofTimeout, maxOutputBytes: 1024 * 1024)
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
