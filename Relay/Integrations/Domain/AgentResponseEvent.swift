import Foundation

struct AgentResponseEvent: Equatable, Sendable {
    let id: UUID
    let provider: AgentProvider
    let providerSessionID: String
    let text: String
    let cwd: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
    /// Copied from `HookEnvelope.processAncestry`; `nil` when the helper did not send it.
    var processAncestry: [Int32]? = nil
}
