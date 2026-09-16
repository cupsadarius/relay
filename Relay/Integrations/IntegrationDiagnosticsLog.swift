import Foundation

/// One recorded transition in the integration pipeline (socket receive -> envelope decode ->
/// adapter decode -> registry upsert -> focus gate).
///
/// PRIVACY: `detail` must never carry response text, cwd, file/transcript paths, environment
/// values, raw error/exception strings, or `providerSessionID`. Only structural facts belong
/// here: provider name, byte counts, drop-reason case names, focus state/confidence labels, and
/// spoke/silent outcomes.
struct IntegrationDiagnosticsEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let stage: String
    let outcome: String
    let detail: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stage: String,
        outcome: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.outcome = outcome
        self.detail = detail
    }
}

/// In-memory, in-app diagnostics log for the integration pipeline (hook socket -> receiver ->
/// manager -> auto-read coordinator). Independent of the unified logging system (`os_log`): this
/// exists so pipeline-stage transitions can be inspected directly in the Diagnostics window, since
/// `os_log` output is not observable via `log show` on some dev machines.
///
/// Safe to call from any isolation domain: `@unchecked Sendable`, internally guarded by a lock.
/// The socket/receiver code, `IntegrationManager`'s off-MainActor consumption loop, and the
/// `AgentAutoReadCoordinator` actor all append directly from their own isolation; a SwiftUI view
/// reads a snapshot (typically on a manual Refresh tap, mirroring how the existing Agent Sessions
/// list already refreshes).
///
/// Capped at `capacity` entries (oldest evicted first) so a runaway pipeline can never grow this
/// unboundedly.
final class IntegrationDiagnosticsLog: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [IntegrationDiagnosticsEntry] = []

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// Appends one pipeline-stage transition. Safe to call from any isolation domain.
    func append(stage: String, outcome: String, detail: String) {
        let entry = IntegrationDiagnosticsEntry(stage: stage, outcome: outcome, detail: detail)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    /// A snapshot of currently recorded entries, newest first.
    func snapshot() -> [IntegrationDiagnosticsEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    /// Removes all recorded entries.
    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
