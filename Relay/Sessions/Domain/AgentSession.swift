import Foundation

struct AgentSessionID: Hashable, Codable, Sendable {
    let provider: AgentProvider
    let providerSessionID: String
}

extension AgentSessionID {
    /// `"<provider raw value>:<providerSessionID>"`, e.g. `"claude-code:abc"`. The one spelling
    /// used for speech-request session IDs and privacy-reviewed diagnostics labels.
    var qualifiedName: String { "\(provider.rawValue):\(providerSessionID)" }
}

struct AgentSession: Equatable, Sendable {
    let id: AgentSessionID
    var cwd: String
    var terminalContext: TerminalContext
    var processAncestry: [Int32]
    /// This session's own last reply, which may differ from the global latest reply.
    var latestResponse: AgentResponseEvent
    var lastActivityAt: Date
}
