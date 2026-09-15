import Foundation

protocol RelayIntegration: Sendable {
    var provider: AgentProvider { get }
    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent
}
