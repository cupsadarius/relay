import Foundation

/// The agent hook events Relay installs and reads.
enum HookEvent: String, CaseIterable {
    /// Delivers the agent's reply.
    case stop = "Stop"
    /// Tells Relay which session the user prompted.
    case userPromptSubmit = "UserPromptSubmit"
}

/// Why a hook envelope was rejected. Never carries payload content — only the structural reason.
enum HookMessageError: Error, Equatable, Sendable {
    /// Not JSON, not the expected shape, or missing a required `turn_id`.
    case malformedPayload
    /// `hook_event_name` was neither `Stop` nor `UserPromptSubmit`.
    case unsupportedHookEvent
    /// `last_assistant_message` was missing, empty, or blank.
    case missingFinalMessage
}

/// One hook envelope from Claude Code or Codex, parsed once at the edge.
enum HookMessage: Equatable, Sendable {
    /// The user prompted this session. The prompt text is never read.
    case prompt(AgentSessionID)
    /// The agent finished a turn with a nonblank reply.
    case response(AgentResponseEvent)

    static func parse(_ envelope: HookEnvelope) throws(HookMessageError) -> HookMessage {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(envelope.rawPayload.utf8)) else {
            throw .malformedPayload
        }
        if payload.hookEventName == HookEvent.userPromptSubmit.rawValue {
            return .prompt(AgentSessionID(provider: envelope.provider, providerSessionID: payload.sessionID))
        }
        // Codex always sends `turn_id` on `Stop`; a payload without it is not a real Codex `Stop`.
        guard let cwd = payload.cwd, envelope.provider != .codex || payload.turnID != nil else {
            throw .malformedPayload
        }
        guard payload.hookEventName == HookEvent.stop.rawValue else { throw .unsupportedHookEvent }
        guard let text = payload.lastAssistantMessage, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .missingFinalMessage
        }
        return .response(
            AgentResponseEvent(
                provider: envelope.provider,
                providerSessionID: payload.sessionID,
                text: text,
                cwd: cwd,
                parentPID: envelope.parentPID,
                environment: envelope.environment,
                capturedAt: envelope.capturedAt,
                processAncestry: envelope.processAncestry
            ))
    }

    /// The fields Relay reads from a hook payload. Both agents use the same snake_case names;
    /// unknown fields are ignored.
    private struct Payload: Decodable {
        let sessionID: String
        let hookEventName: String
        let cwd: String?
        let turnID: String?
        let lastAssistantMessage: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case hookEventName = "hook_event_name"
            case cwd
            case turnID = "turn_id"
            case lastAssistantMessage = "last_assistant_message"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            hookEventName = try container.decode(String.self, forKey: .hookEventName)
            // A missing or wrong-typed optional field reads as nil; `parse` decides if it matters.
            cwd = try? container.decode(String.self, forKey: .cwd)
            turnID = try? container.decode(String.self, forKey: .turnID)
            lastAssistantMessage = try? container.decode(String.self, forKey: .lastAssistantMessage)
        }
    }
}
