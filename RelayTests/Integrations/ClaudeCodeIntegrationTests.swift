import XCTest
@testable import Relay

final class ClaudeCodeIntegrationTests: XCTestCase {
    private let integration = ClaudeCodeIntegration()

    private func envelope(rawPayload: String) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: rawPayload,
            parentPID: 4242,
            environment: ["TERM_PROGRAM": "ghostty"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private let fixture = #"""
    {
      "session_id": "abc123",
      "transcript_path": "/Users/me/.claude/projects/p/abc123.jsonl",
      "cwd": "/Users/me/project",
      "hook_event_name": "Stop",
      "stop_hook_active": false,
      "last_assistant_message": "I've completed the refactoring."
    }
    """#

    func testDecodesStopEventPreservingSessionCwdTranscriptAndText() throws {
        let event = try integration.decode(envelope(rawPayload: fixture))

        XCTAssertEqual(event.provider, .claudeCode)
        XCTAssertEqual(event.providerSessionID, "abc123")
        XCTAssertEqual(event.cwd, "/Users/me/project")
        XCTAssertEqual(event.transcriptPath, "/Users/me/.claude/projects/p/abc123.jsonl")
        XCTAssertEqual(event.text, "I've completed the refactoring.")
        XCTAssertNil(event.turnID)
        XCTAssertEqual(event.parentPID, 4242)
        XCTAssertEqual(event.environment, ["TERM_PROGRAM": "ghostty"])
        XCTAssertEqual(event.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMissingLastAssistantMessageIsRejected() {
        let payload = #"""
        {
          "session_id": "abc123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "stop_hook_active": false
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? ClaudeCodeIntegrationError, .missingFinalMessage)
        }
    }

    func testEmptyLastAssistantMessageIsRejected() {
        let payload = #"""
        {
          "session_id": "abc123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "stop_hook_active": false,
          "last_assistant_message": "   "
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? ClaudeCodeIntegrationError, .missingFinalMessage)
        }
    }

    func testNonStopHookEventNameIsRejected() {
        let payload = #"""
        {
          "session_id": "abc123",
          "cwd": "/Users/me/project",
          "hook_event_name": "PreToolUse",
          "stop_hook_active": false,
          "last_assistant_message": "I've completed the refactoring."
        }
        """#

        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: payload))) { error in
            XCTAssertEqual(error as? ClaudeCodeIntegrationError, .unsupportedHookEvent)
        }
    }

    func testDecodesStopEventWhenStopHookActiveFieldIsAbsent() throws {
        let payload = #"""
        {
          "session_id": "abc123",
          "cwd": "/Users/me/project",
          "hook_event_name": "Stop",
          "last_assistant_message": "I've completed the refactoring."
        }
        """#

        let event = try integration.decode(envelope(rawPayload: payload))

        XCTAssertEqual(event.text, "I've completed the refactoring.")
    }

    func testMalformedRawPayloadIsRejected() {
        XCTAssertThrowsError(try integration.decode(envelope(rawPayload: "not json"))) { error in
            XCTAssertEqual(error as? ClaudeCodeIntegrationError, .malformedPayload)
        }
    }
}
