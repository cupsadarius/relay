import Foundation

/// Raw shape of a Claude Code hook payload, decoded from the JSON that
/// Claude Code writes to stdin of a registered hook command.
///
/// This mirrors Claude Code's own field names via `CodingKeys`; only the
/// `Stop` event (see `ClaudeCodeIntegration`) is currently normalized into a
/// Relay `AgentResponseEvent`.
struct ClaudeCodeHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case lastAssistantMessage = "last_assistant_message"
    }
}
