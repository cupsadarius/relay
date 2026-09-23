import Foundation

/// Raw shape of a Codex hook payload, decoded from the JSON that Codex
/// writes to stdin of a registered hook command.
///
/// This mirrors Codex's own field names via `CodingKeys`; only the `Stop`
/// event (see `CodexIntegration`) is currently normalized into a Relay
/// `AgentResponseEvent`. `turnID` is decoded only as a shape guard: Codex always
/// includes `turn_id` on `Stop` events, so a payload without it is rejected as
/// malformed (see `CodexIntegrationError.malformedPayload`). Relay does not
/// otherwise use the value.
struct CodexHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let turnID: String
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case lastAssistantMessage = "last_assistant_message"
    }
}
