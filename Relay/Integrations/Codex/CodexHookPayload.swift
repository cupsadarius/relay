import Foundation

/// Raw shape of a Codex hook payload, decoded from the JSON that Codex
/// writes to stdin of a registered hook command.
///
/// This mirrors Codex's own field names via `CodingKeys`; only the `Stop`
/// event (see `CodexIntegration`) is currently normalized into a Relay
/// `AgentResponseEvent`. `turnID` is required: Codex always includes
/// `turn_id` on `Stop` events, and Relay's normalized event needs it to
/// distinguish turns within a session.
struct CodexHookPayload: Decodable {
    let sessionID: String
    let transcriptPath: String?
    let cwd: String
    let hookEventName: String
    let turnID: String
    let stopHookActive: Bool?
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
    }
}
