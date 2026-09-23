import XCTest
@testable import Relay

final class AgentSessionRegistryTests: XCTestCase {
    func testTerminalContextExtractsMultiplexerMetadata() {
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "claude-a",
            text: "done",
            cwd: "/tmp/repo",
            parentPID: 101,
            environment: [
                "TERM_PROGRAM": "ghostty",
                "TMUX": "/private/tmp/tmux-501/default,123,0",
                "TMUX_PANE": "%7",
                "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
                "HERDR_PANE_ID": "w1:p2"
            ],
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let context = TerminalContext(event: event)
        XCTAssertEqual(context.tmuxSocketPath, "/private/tmp/tmux-501/default")
        XCTAssertEqual(context.tmuxPaneID, "%7")
        XCTAssertEqual(context.herdrSocketPath, "/tmp/herdr.sock")
        XCTAssertEqual(context.herdrPaneID, "w1:p2")
    }

    func testUpsertKeepsSeparateConcurrentProviderSessions() async {
        let registry = AgentSessionRegistry()
        let a = makeEvent(provider: .claudeCode, session: "a", at: 10)
        let b = makeEvent(provider: .codex, session: "b", at: 11)

        await registry.upsert(response: a, processAncestry: [101, 20, 1], tty: "/dev/ttys001")
        await registry.upsert(response: b, processAncestry: [202, 20, 1], tty: "/dev/ttys002")

        let sessions = await registry.sessions()
        XCTAssertEqual(Set(sessions.map(\.id)), [
            AgentSessionID(provider: .claudeCode, providerSessionID: "a"),
            AgentSessionID(provider: .codex, providerSessionID: "b")
        ])
    }

    private func makeEvent(provider: AgentProvider, session: String, at: TimeInterval) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(), provider: provider, providerSessionID: session,
            text: "response", cwd: "/tmp/repo",
            parentPID: 42, environment: [:], capturedAt: Date(timeIntervalSince1970: at)
        )
    }
}
