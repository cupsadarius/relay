import Foundation

/// Why a decoded Codex hook envelope was rejected. Never carries payload
/// content — only the structural reason.
enum CodexIntegrationError: Error, Equatable, Sendable {
    /// `rawPayload` was not valid UTF-8/JSON, or did not match the expected
    /// Codex hook payload shape (including a missing required `turn_id`).
    case malformedPayload
    /// `hook_event_name` was present but was not `"Stop"`.
    case unsupportedHookEvent
    /// `last_assistant_message` was missing, empty, or blank.
    case missingFinalMessage
}

/// Normalizes Codex `Stop` hook events into Relay's provider-neutral
/// `AgentResponseEvent`.
///
/// Only `Stop` events carrying a nonblank `last_assistant_message` are
/// accepted; every other event is rejected with a `CodexIntegrationError` so
/// callers never have to special-case Codex payload shapes.
struct CodexIntegration: RelayIntegration {
    let provider: AgentProvider = .codex

    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        guard let data = envelope.rawPayload.data(using: .utf8) else {
            throw CodexIntegrationError.malformedPayload
        }

        let payload: CodexHookPayload
        do {
            payload = try decoder.decode(CodexHookPayload.self, from: data)
        } catch {
            throw CodexIntegrationError.malformedPayload
        }

        guard payload.hookEventName == "Stop" else {
            throw CodexIntegrationError.unsupportedHookEvent
        }

        guard let text = payload.lastAssistantMessage,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexIntegrationError.missingFinalMessage
        }

        return AgentResponseEvent(
            id: UUID(),
            provider: .codex,
            providerSessionID: payload.sessionID,
            text: text,
            cwd: payload.cwd,
            parentPID: envelope.parentPID,
            environment: envelope.environment,
            capturedAt: envelope.capturedAt
        )
    }
}
