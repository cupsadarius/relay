import Foundation

struct AgentSessionID: Hashable, Codable, Sendable {
    let provider: AgentProvider
    let providerSessionID: String
}

struct AgentSession: Equatable, Sendable {
    let id: AgentSessionID
    var cwd: String
    var terminalContext: TerminalContext
    var processAncestry: [Int32]
    var tty: String?
    var latestResponse: AgentResponseEvent
    var lastActivityAt: Date
}
