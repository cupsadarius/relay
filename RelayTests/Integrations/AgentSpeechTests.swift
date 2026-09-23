import XCTest

@testable import Relay

final class AgentSpeechTests: XCTestCase {
    private func event(_ provider: AgentProvider, session: String) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(), provider: provider, providerSessionID: session,
            text: "raw", cwd: "/tmp", parentPID: 1, environment: [:], capturedAt: Date()
        )
    }

    func testQualifiedNameIsProviderColonSession() {
        XCTAssertEqual(AgentSessionID(provider: .codex, providerSessionID: "t1").qualifiedName, "codex:t1")
    }

    func testClaudeCodeEventBuildsClaudeSpeechRequest() {
        let source = event(.claudeCode, session: "abc")
        XCTAssertEqual(source.sessionID, AgentSessionID(provider: .claudeCode, providerSessionID: "abc"))
        XCTAssertEqual(
            source.speechRequest(text: "prepared", mode: .automatic),
            SpeechRequest(text: "prepared", source: .claudeCode, mode: .automatic, sessionID: "claude-code:abc")
        )
    }

    func testCodexEventBuildsCodexSpeechRequest() {
        XCTAssertEqual(
            event(.codex, session: "thr").speechRequest(text: "p", mode: .userRequested),
            SpeechRequest(text: "p", source: .codex, mode: .userRequested, sessionID: "codex:thr")
        )
    }
}
