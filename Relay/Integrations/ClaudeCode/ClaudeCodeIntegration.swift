import Foundation

/// Why a decoded Claude Code hook envelope was rejected. Never carries
/// payload content — only the structural reason.
enum ClaudeCodeIntegrationError: Error, Equatable, Sendable {
    /// `rawPayload` was not valid UTF-8/JSON, or did not match the expected
    /// Claude Code hook payload shape.
    case malformedPayload
    /// `hook_event_name` was present but was not `"Stop"`.
    case unsupportedHookEvent
    /// `last_assistant_message` was missing, empty, or blank.
    case missingFinalMessage
}

/// Normalizes Claude Code `Stop` hook events into Relay's provider-neutral
/// `AgentResponseEvent`.
///
/// Only `Stop` events carrying a nonblank `last_assistant_message` are
/// accepted; every other event is rejected with a `ClaudeCodeIntegrationError`
/// so callers never have to special-case Claude Code payload shapes.
struct ClaudeCodeIntegration: RelayIntegration {
    let provider: AgentProvider = .claudeCode

    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        guard let data = envelope.rawPayload.data(using: .utf8) else {
            throw ClaudeCodeIntegrationError.malformedPayload
        }

        let payload: ClaudeCodeHookPayload
        do {
            payload = try decoder.decode(ClaudeCodeHookPayload.self, from: data)
        } catch {
            throw ClaudeCodeIntegrationError.malformedPayload
        }

        guard payload.hookEventName == "Stop" else {
            throw ClaudeCodeIntegrationError.unsupportedHookEvent
        }

        guard let text = payload.lastAssistantMessage,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCodeIntegrationError.missingFinalMessage
        }

        return AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: payload.sessionID,
            text: text,
            cwd: payload.cwd,
            parentPID: envelope.parentPID,
            environment: envelope.environment,
            capturedAt: envelope.capturedAt
        )
    }
}
