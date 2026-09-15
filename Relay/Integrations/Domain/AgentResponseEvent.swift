import Foundation

struct AgentResponseEvent: Equatable, Sendable {
    let id: UUID
    let provider: AgentProvider
    let providerSessionID: String
    let turnID: String?
    let text: String
    let cwd: String
    let transcriptPath: String?
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}
