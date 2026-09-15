import Foundation

/// Holds the single most recent normalized agent response in memory only.
///
/// This store is intentionally ephemeral: it never touches `UserDefaults`, a file, a database,
/// or any transcript path. Its contents live only for the lifetime of the process and are lost
/// on quit, matching the Phase 2 constraint that agent response text is never written to Relay
/// history.
actor LatestAgentResponseStore {
    private var latest: AgentResponseEvent?

    /// Replaces the stored event, discarding whatever was there before.
    func set(_ event: AgentResponseEvent) {
        latest = event
    }

    /// Returns the most recently stored event, or `nil` if none has arrived yet (or it has been
    /// cleared).
    func get() -> AgentResponseEvent? {
        latest
    }

    /// Discards the stored event, if any.
    func clear() {
        latest = nil
    }
}
