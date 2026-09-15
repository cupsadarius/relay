import XCTest
@testable import Relay

final class CodexIntegrationTests: XCTestCase {
    private let integration = CodexIntegration()

    private func envelope(rawPayload: String) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: .codex,
            rawPayload: rawPayload,
            parentPID: 4242,
            environment: ["TERM_PROGRAM": "ghostty"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private let fixture = #"""
    {
      "session_id": "thr_123",
      "transcript_path": "/Users/me/.codex/sessions/rollout.jsonl",
      "cwd": "/Users/me/project",
      "hook_event_name": "Stop",
      "turn_id": "turn_456",
      "stop_hook_active": false,
      "last_assistant_message": "The tests now pass."
    }
    """#

    func testDecodesStopEventPreservingTurnSessionCwdTranscriptAndText() throws {
        let event = try integration.decode(envelope(rawPayload: fixture))

        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.providerSessionID, "thr_123")
        XCTAssertEqual(event.turnID, "turn_456")
        XCTAssertEqual(event.cwd, "/Users/me/project")
        XCTAssertEqual(event.transcriptPath, "/Users/me/.codex/sessions/rollout.jsonl")
        XCTAssertEqual(event.text, "The tests now pass.")
        XCTAssertEqual(event.parentPID, 4242)
        XCTAssertEqual(event.environment, ["TERM_PROGRAM": "ghostty"])
        XCTAssertEqual(event.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMissingLastAssistantMessageIsRejected() {
        let payload = #"""
        {
          "session_id": "thr_123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "turn_id": "turn_456",
          "stop_hook_active": false
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? CodexIntegrationError, .missingFinalMessage)
        }
    }

    func testEmptyLastAssistantMessageIsRejected() {
        let payload = #"""
        {
          "session_id": "thr_123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "turn_id": "turn_456",
          "stop_hook_active": false,
          "last_assistant_message": "   "
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? CodexIntegrationError, .missingFinalMessage)
        }
    }

    func testNonStopHookEventNameIsRejected() {
        let payload = #"""
        {
          "session_id": "thr_123",
          "cwd": "/Users/me/project",
          "hook_event_name": "PreToolUse",
          "turn_id": "turn_456",
          "stop_hook_active": false,
          "last_assistant_message": "The tests now pass."
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? CodexIntegrationError, .unsupportedHookEvent)
        }
    }

    func testDecodesStopEventWhenStopHookActiveFieldIsAbsent() throws {
        let payload = #"""
        {
          "session_id": "thr_123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "turn_id": "turn_456",
          "last_assistant_message": "The tests now pass."
        }
        """#

        let event = try integration.decode(envelope(rawPayload: payload))

        XCTAssertEqual(event.text, "The tests now pass.")
        XCTAssertEqual(event.turnID, "turn_456")
    }

    func testMissingTurnIDIsRejectedAsMalformed() {
        let payload = #"""
        {
          "session_id": "thr_123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "stop_hook_active": false,
          "last_assistant_message": "The tests now pass."
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? CodexIntegrationError, .malformedPayload)
        }
    }

    func testMalformedRawPayloadIsRejected() {
        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: "not json"))) { error in
            XCTAssertEqual(error as? CodexIntegrationError, .malformedPayload)
        }
    }
}
