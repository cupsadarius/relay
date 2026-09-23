import Foundation

/// The fields Relay reads from a Claude Code or Codex `Stop` hook payload. Both agents use the
/// same snake_case names; unknown fields are ignored. `turnID` is optional here and enforced per
/// provider by `StopHookIntegration.requiresTurnID`.
struct StopHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let turnID: String?
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case lastAssistantMessage = "last_assistant_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        cwd = try container.decode(String.self, forKey: .cwd)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        // `turn_id` is only structurally meaningful for Codex (enforced separately by
        // `StopHookIntegration.requiresTurnID`); Claude Code payloads may omit it or send any
        // shape at all, so a wrong type here must never fail decoding of an otherwise-valid
        // Claude payload. Missing or wrong-typed both simply resolve to `nil`.
        turnID = try? container.decode(String.self, forKey: .turnID)
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
    }
}

/// Why a hook envelope was rejected. Never carries payload content — only the structural reason.
enum StopHookIntegrationError: Error, Equatable, Sendable {
    /// Not UTF-8/JSON, not the expected shape, or missing a required `turn_id`.
    case malformedPayload
    /// `hook_event_name` was not `"Stop"`.
    case unsupportedHookEvent
    /// `last_assistant_message` was missing, empty, or blank.
    case missingFinalMessage
}

/// Normalizes a `Stop` hook envelope from either agent into Relay's provider-neutral
/// `AgentResponseEvent`. Only `Stop` events with a nonblank `last_assistant_message` are
/// accepted.
struct StopHookIntegration: RelayIntegration {
    static let claudeCode = StopHookIntegration(provider: .claudeCode)
    /// Codex always sends `turn_id` on `Stop`; a payload without it is not a real Codex `Stop`.
    static let codex = StopHookIntegration(provider: .codex, requiresTurnID: true)

    let provider: AgentProvider
    let requiresTurnID: Bool
    private let decoder: JSONDecoder

    init(provider: AgentProvider, requiresTurnID: Bool = false, decoder: JSONDecoder = JSONDecoder()) {
        self.provider = provider
        self.requiresTurnID = requiresTurnID
        self.decoder = decoder
    }

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        guard let data = envelope.rawPayload.data(using: .utf8),
            let payload = try? decoder.decode(StopHookPayload.self, from: data)
        else {
            throw StopHookIntegrationError.malformedPayload
        }
        if requiresTurnID, payload.turnID == nil {
            throw StopHookIntegrationError.malformedPayload
        }
        guard payload.hookEventName == "Stop" else {
            throw StopHookIntegrationError.unsupportedHookEvent
        }
        guard let text = payload.lastAssistantMessage,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw StopHookIntegrationError.missingFinalMessage
        }

        return AgentResponseEvent(
            id: UUID(),
            provider: provider,
            providerSessionID: payload.sessionID,
            text: text,
            cwd: payload.cwd,
            parentPID: envelope.parentPID,
            environment: envelope.environment,
            capturedAt: envelope.capturedAt,
            processAncestry: envelope.processAncestry
        )
    }
}
