import XCTest

@testable import Relay

final class HookMessageTests: XCTestCase {
    private func envelope(provider: AgentProvider, rawPayload: String) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: provider,
            rawPayload: rawPayload,
            parentPID: 4242,
            environment: ["TMUX_PANE": "%3"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func payload(
        event: String = "Stop",
        message: String? = "I've completed the refactoring.",
        turnID: String? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = ["session_id": "abc123", "cwd": "/Users/me/project", "hook_event_name": event]
        if let message { object["last_assistant_message"] = message }
        if let turnID { object["turn_id"] = turnID }
        object.merge(extra) { current, _ in current }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private struct NotAResponse: Error {}

    private func response(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        guard case let .response(event) = try HookMessage.parse(envelope) else { throw NotAResponse() }
        return event
    }

    func testClaudeCodeDecodesStopEventWithoutTurnID() throws {
        let event = try response(envelope(provider: .claudeCode, rawPayload: payload()))

        XCTAssertEqual(event.provider, .claudeCode)
        XCTAssertEqual(event.providerSessionID, "abc123")
        XCTAssertEqual(event.cwd, "/Users/me/project")
        XCTAssertEqual(event.text, "I've completed the refactoring.")
        XCTAssertEqual(event.parentPID, 4242)
        XCTAssertEqual(event.environment, ["TMUX_PANE": "%3"])
        XCTAssertEqual(event.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCodexDecodesStopEventWithTurnID() throws {
        let event = try response(envelope(provider: .codex, rawPayload: payload(turnID: "turn_456")))

        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.providerSessionID, "abc123")
    }

    func testCodexRejectsMissingTurnIDAsMalformed() {
        XCTAssertThrowsError(try HookMessage.parse(envelope(provider: .codex, rawPayload: payload()))) { error in
            XCTAssertEqual(error as? HookMessageError, .malformedPayload)
        }
    }

    func testUnknownFieldsFromEitherAgentAreIgnored() throws {
        let raw = payload(extra: ["transcript_path": "/tmp/t.jsonl", "stop_hook_active": false, "model": "x"])
        XCTAssertNoThrow(try response(envelope(provider: .claudeCode, rawPayload: raw)))
    }

    /// Claude Code does not use `turn_id`; a wrong-typed value there must never fail decoding of
    /// an otherwise-valid Claude payload (only Codex structurally requires it as a string).
    func testClaudeCodeDecodesStopEventWithNonStringTurnID() throws {
        let raw = payload(extra: ["turn_id": 12345])
        XCTAssertNoThrow(try response(envelope(provider: .claudeCode, rawPayload: raw)))
    }

    func testMissingOrBlankFinalMessageIsRejectedForBothProviders() {
        for (provider, turnID) in [(AgentProvider.claudeCode, nil), (.codex, "t")] as [(AgentProvider, String?)] {
            for raw in [payload(message: nil, turnID: turnID), payload(message: "   \n", turnID: turnID)] {
                XCTAssertThrowsError(try HookMessage.parse(envelope(provider: provider, rawPayload: raw))) { error in
                    XCTAssertEqual(error as? HookMessageError, .missingFinalMessage)
                }
            }
        }
    }

    func testNonStopHookEventIsRejected() {
        let raw = payload(event: "PreToolUse")
        XCTAssertThrowsError(try response(envelope(provider: .claudeCode, rawPayload: raw))) { error in
            XCTAssertEqual(error as? HookMessageError, .unsupportedHookEvent)
        }
    }

    func testMalformedRawPayloadIsRejected() {
        XCTAssertThrowsError(try HookMessage.parse(envelope(provider: .codex, rawPayload: "not json"))) { error in
            XCTAssertEqual(error as? HookMessageError, .malformedPayload)
        }
    }

    func testEnvelopeAncestryIsCarriedOntoTheEvent() throws {
        var hookEnvelope = envelope(provider: .claudeCode, rawPayload: payload())
        hookEnvelope.processAncestry = [800, 700]
        XCTAssertEqual(try response(hookEnvelope).processAncestry, [800, 700])
    }
}
