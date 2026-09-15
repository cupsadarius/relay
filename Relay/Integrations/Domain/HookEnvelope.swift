import Foundation

struct HookEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let provider: AgentProvider
    let rawPayload: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}
