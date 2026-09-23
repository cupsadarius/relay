import XCTest

@testable import Relay

final class TmuxFocusResolverTests: XCTestCase {
    /// Ghostty (20) -> login (100) -> tmux clients 300 and 301.
    private let snapshot = try! ProcessSnapshot.parse(
        """
          1   0 ??      launchd
         20   1 ??      Ghostty
        100  20 ttys001 login
        300 100 ttys001 tmux
        301 100 ttys002 tmux
        """)

    private func context(frontmostPID: Int32 = 20, snapshot: ProcessSnapshot?) -> FocusContext {
        FocusContext(
            frontmostApplication: .init(pid: frontmostPID, bundleIdentifier: nil, localizedName: "Terminal"),
            sessions: [],
            processSnapshot: snapshot
        )
    }

    func testMatchingFrontmostClientAndPaneIsFocused() async {
        let runner = StubTmuxRunner(clients: [.init(name: "/dev/ttys001", pid: 300)], activePaneByClient: ["/dev/ttys001": "%7"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .focused)
    }

    func testSameClientDifferentPaneIsNotFocused() async {
        let runner = StubTmuxRunner(clients: [.init(name: "/dev/ttys001", pid: 300)], activePaneByClient: ["/dev/ttys001": "%9"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testTwoTmuxClientsUnderSameFrontmostAppAreUnknown() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "c1", pid: 300), .init(name: "c2", pid: 301)],
            activePaneByClient: ["c1": "%7", "c2": "%8"]
        )
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .unknown)
    }

    func testMissingProcessSnapshotIsUnknown() async {
        let runner = StubTmuxRunner(clients: [.init(name: "c1", pid: 300)], activePaneByClient: ["c1": "%7"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: nil))
        XCTAssertEqual(decision.state, .unknown)
        XCTAssertEqual(decision.reason, "process snapshot unavailable")
    }
}

private struct StubTmuxRunner: TmuxCommandRunning {
    let clients: [TmuxClientListing]
    let activePaneByClient: [String: String]
    func listClients(socketPath: String) async throws -> [TmuxClientListing] { clients }
    func activePane(socketPath: String, clientName: String) async throws -> String {
        activePaneByClient[clientName] ?? ""
    }
}

private func makeTmuxSession(pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a",
        text: "done", cwd: "/tmp/repo", parentPID: 900,
        environment: ["TMUX": "/tmp/tmux.sock,10,0", "TMUX_PANE": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
