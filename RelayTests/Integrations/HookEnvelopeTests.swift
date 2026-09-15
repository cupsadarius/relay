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
}
