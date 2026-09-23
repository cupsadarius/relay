import XCTest
@testable import Relay

final class HookEnvelopeTests: XCTestCase {
    func testEnvelopeRoundTripsWithoutLosingRawPayload() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: #"{"session_id":"abc","last_assistant_message":"done"}"#,
            parentPID: 123,
            environment: ["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%3"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try JSONDecoder().decode(HookEnvelope.self, from: data), envelope)
    }

    func testWireDataLeavesSlashesUnescapedAndRoundTrips() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .codex,
            rawPayload: #"{"cwd":"/Users/me/project","transcript_path":"/tmp/t.jsonl"}"#,
            parentPID: 42,
            environment: ["TERM_PROGRAM": "ghostty"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try XCTUnwrap(try envelope.wireData())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains(#"\/"#))
        XCTAssertEqual(try JSONDecoder().decode(HookEnvelope.self, from: data), envelope)
    }

    /// 1.5 MiB of quotes passes RelayHook's raw stdin cap, but each `"` escapes to `\"`, so the
    /// encoded line is about 3 MiB, over the socket's limit. It must be refused before sending.
    func testWireDataRefusesAnEnvelopeWhoseEscapedEncodingExceedsTheSocketLimit() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: String(repeating: "\"", count: 1_500 * 1_024),
            parentPID: 42,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertNil(try envelope.wireData())
    }

    func testSocketLineLimitIsTheSharedEnvelopeWireLimit() {
        XCTAssertEqual(UnixSocketServer.maxLineBytes, HookEnvelope.maxWireBytes)
    }
}
