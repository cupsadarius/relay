import Foundation

actor AgentSessionRegistry {
    private var values: [AgentSessionID: AgentSession] = [:]

    @discardableResult
    func upsert(
        response: AgentResponseEvent,
        processAncestry: [Int32],
        tty: String?
    ) -> AgentSession {
        let id = response.sessionID
        let value = AgentSession(
            id: id,
            cwd: response.cwd,
            terminalContext: TerminalContext(event: response),
            processAncestry: processAncestry,
            tty: tty,
            latestResponse: response,
            lastActivityAt: response.capturedAt
        )
        values[id] = value
        return value
    }

    func sessions() -> [AgentSession] {
        values.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Default inactivity TTL before a session is considered stale.
    static let defaultTTL: TimeInterval = 20 * 60

    /// Drops sessions whose agent (leaf) process is dead or whose inactivity exceeds `ttl`.
    /// `isAlive` is @Sendable and injected so this stays testable and satisfies
    /// Swift 6 strict concurrency across the actor boundary.
    ///
    /// PID reuse can produce a false negative here (a dead agent's pid gets recycled by an
    /// unrelated live process before this runs) — the TTL check is the backstop for that case.
    func prune(now: Date = Date(), ttl: TimeInterval = AgentSessionRegistry.defaultTTL,
               isAlive: @Sendable (Int32) -> Bool) {
        for (id, session) in values {
            let agentPID = session.processAncestry.first
            let dead = agentPID.map { !isAlive($0) } ?? false
            let expired = now.timeIntervalSince(session.lastActivityAt) > ttl
            if dead || expired { values[id] = nil }
        }
    }
}

/// Prunes `registry` against `snapshot` — the SAME snapshot the caller uses for the rest of its
/// focus decision. A `nil` snapshot (failed `ps`) skips pruning for this cycle rather than
/// risking a false "dead" verdict on a session that is still running.
func pruneDeadSessions(in registry: AgentSessionRegistry, snapshot: ProcessSnapshot?) async {
    guard let snapshot else { return }
    await registry.prune(isAlive: { pid in snapshot.record(pid: pid) != nil })
}
