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
    var tty: String?
    /// This session's own most recent reply — distinct from (and not a duplicate of)
    /// `LatestAgentResponseStore`'s single global latest: `AppModel.replayLast()`'s tier 1 needs
    /// the FOCUSED session's own last reply, which may not be whichever session replied most
    /// recently across all of them. Kept deliberately; not part of the Task 3 single-source fix.
    var latestResponse: AgentResponseEvent
    var lastActivityAt: Date
}
