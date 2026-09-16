import Foundation

actor AgentSessionRegistry {
    private var values: [AgentSessionID: AgentSession] = [:]

    @discardableResult
    func upsert(
        response: AgentResponseEvent,
        processAncestry: [Int32],
        tty: String?
    ) -> AgentSession {
        let id = AgentSessionID(provider: response.provider, providerSessionID: response.providerSessionID)
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

    func session(id: AgentSessionID) -> AgentSession? { values[id] }

    func sessions() -> [AgentSession] {
        values.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func removeAll() { values.removeAll() }

    func remove(id: AgentSessionID) { values[id] = nil }

    /// Default inactivity TTL before a session is considered stale.
    static let defaultTTL: TimeInterval = 20 * 60

    /// Drops sessions whose root process is dead or whose inactivity exceeds `ttl`.
    /// `isAlive` is @Sendable and injected so this stays testable and satisfies
    /// Swift 6 strict concurrency across the actor boundary.
    func prune(now: Date = Date(), ttl: TimeInterval = AgentSessionRegistry.defaultTTL,
               isAlive: @Sendable (Int32) -> Bool) {
        for (id, session) in values {
            let rootPID = session.processAncestry.first
            let dead = rootPID.map { !isAlive($0) } ?? false
            let expired = now.timeIntervalSince(session.lastActivityAt) > ttl
            if dead || expired { values[id] = nil }
        }
    }
}
