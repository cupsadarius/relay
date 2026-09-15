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
}
