import Darwin
import Foundation

/// Reads a process's parent chain straight from the kernel (`sysctl(KERN_PROC_PID)`), with no
/// child process. `RelayHook` calls this synchronously before it exits, so the chain is captured
/// while every ancestor — including a transient `sh -c` wrapper — is still alive.
///
/// Compiled into BOTH the `Relay` app target (for tests) and the `RelayHook` helper target.
enum ProcessAncestry {
    struct Entry: Equatable, Sendable {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    /// Hard bound on hops, so a corrupt or cyclic table can never spin.
    static let maxDepth = 16

    /// Shell basenames treated as transient hook wrappers when they sit at the FRONT of the
    /// chain (below the agent). A login shell above the agent is never trimmed, because trimming
    /// stops at the first non-shell entry.
    static let wrapperShellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// One kernel lookup. `nil` when `pid` does not exist.
    static func entry(pid: Int32) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Entry(pid: pid, parentPID: info.kp_eproc.e_ppid, command: command)
    }

    /// `pid` first, then each parent, stopping at pid 0, a missing process, a repeated pid, or
    /// `maxDepth` entries.
    static func chain(
        from pid: Int32,
        maxDepth: Int = ProcessAncestry.maxDepth,
        lookup: (Int32) -> Entry? = ProcessAncestry.entry(pid:)
    ) -> [Entry] {
        var result: [Entry] = []
        var visited = Set<Int32>()
        var current = pid
        while current > 0, result.count < maxDepth, visited.insert(current).inserted, let entry = lookup(current) {
            result.append(entry)
            current = entry.parentPID
        }
        return result
    }

    /// The pids Relay records for a session: `chain(from:)` with leading wrapper shells dropped,
    /// so `first` is the agent process even when it spawned the hook via `sh -c`. If every entry
    /// is a shell, the untrimmed chain is returned.
    static func agentAncestry(
        from pid: Int32,
        maxDepth: Int = ProcessAncestry.maxDepth,
        lookup: (Int32) -> Entry? = ProcessAncestry.entry(pid:)
    ) -> [Int32] {
        let full = chain(from: pid, maxDepth: maxDepth, lookup: lookup)
        let trimmed = full.drop { wrapperShellNames.contains($0.command) }
        return (trimmed.isEmpty ? full[...] : trimmed).map(\.pid)
    }
}
