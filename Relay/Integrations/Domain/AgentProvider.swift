import Foundation

enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
}
