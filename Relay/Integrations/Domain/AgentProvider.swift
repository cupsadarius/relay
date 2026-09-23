// This file is also compiled directly into the `RelayHook` CLI target (see
// `project.yml`), so it must stay Foundation-only: no dependencies on
// anything else in the Relay app target.

import Foundation

enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
}
