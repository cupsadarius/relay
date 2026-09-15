import XCTest
@testable import Relay

final class TmuxFocusResolverTests: XCTestCase {
    func testMatchingFrontmostClientAndPaneIsFocused() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "/dev/ttys001", pid: 300)],
            activePaneByClient: ["/dev/ttys001": "%7"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 100, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let session = makeTmuxSession(pane: "%7")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"),
            sessions: [session], now: Date()
        )
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .focused)
    }

    func testSameClientDifferentPaneIsNotFocused() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "/dev/ttys001", pid: 300)],
            activePaneByClient: ["/dev/ttys001": "%9"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 100, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let decision = await resolver.resolve(
            session: makeTmuxSession(pane: "%7"),
            context: .init(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), sessions: [], now: Date())
        )
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testTwoTmuxClientsUnderSameFrontmostAppAreUnknown() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "c1", pid: 300), .init(name: "c2", pid: 301)],
            activePaneByClient: ["c1": "%7", "c2": "%8"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 20, 1], 301: [301, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let decision = await resolver.resolve(
            session: makeTmuxSession(pane: "%7"),
            context: .init(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), sessions: [], now: Date())
        )
        XCTAssertEqual(decision.state, .unknown)
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

private struct StubProcessTree: ProcessTreeReading {
    let ancestries: [Int32: [Int32]]
    func ancestry(from pid: Int32) async throws -> [Int32] { ancestries[pid] ?? [] }
}

private func makeTmuxSession(pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: "done", cwd: "/tmp/repo", transcriptPath: nil, parentPID: 900,
        environment: ["TMUX": "/tmp/tmux.sock,10,0", "TMUX_PANE": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
