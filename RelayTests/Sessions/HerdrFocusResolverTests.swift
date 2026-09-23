import XCTest

@testable import Relay

private let emptySnapshot = try! ProcessSnapshot.parse("")

final class HerdrFocusResolverTests: XCTestCase {
    func testFocusedPaneAndMatchingNativeAgentSessionIsFocused() async {
        let herdr = StubHerdrQuery(
            pane: .init(
                paneID: "w1:p2",
                focused: true,
                agentSession: .init(source: "herdr:claude", agent: "claude", kind: "id", value: "claude-a")
            )
        )
        let ownership = StubHerdrHostOwnership(owns: true)
        let resolver = HerdrFocusResolver(herdr: herdr, hostOwnership: ownership)
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "claude-a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"),
            sessions: [session], processSnapshot: emptySnapshot
        )
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .focused)
    }

    func testMatchingPaneInBackgroundHerdrClientIsNotAuthorized() async {
        let herdr = StubHerdrQuery(pane: .init(paneID: "w1:p2", focused: true, agentSession: nil))
        let resolver = HerdrFocusResolver(herdr: herdr, hostOwnership: StubHerdrHostOwnership(owns: false))
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 88, bundleIdentifier: "com.apple.Safari", localizedName: "Safari"),
            sessions: [session], processSnapshot: emptySnapshot
        )
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testDifferentActivePaneIsNotFocused() async {
        let resolver = HerdrFocusResolver(
            herdr: StubHerdrQuery(pane: .init(paneID: "w1:p9", focused: true, agentSession: nil)),
            hostOwnership: StubHerdrHostOwnership(owns: true)
        )
        let session = makeHerdrSession(provider: .codex, sessionID: "c", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"), sessions: [session], processSnapshot: emptySnapshot)
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testMissingProcessSnapshotIsUnknown() async {
        let resolver = HerdrFocusResolver(
            herdr: StubHerdrQuery(pane: .init(paneID: "w1:p2", focused: true, agentSession: nil)),
            hostOwnership: StubHerdrHostOwnership(owns: true)
        )
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"),
            sessions: [session],
            processSnapshot: nil
        )
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .unknown)
    }
}

private struct StubHerdrQuery: HerdrQuerying {
    let pane: HerdrPaneInfo
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo { pane }
}

private struct StubHerdrHostOwnership: HerdrHostOwnershipChecking {
    let owns: Bool
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool { owns }
}

private func makeHerdrSession(provider: AgentProvider, sessionID: String, pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: provider, providerSessionID: sessionID,
        text: "done", cwd: "/tmp/repo", parentPID: 900,
        environment: ["HERDR_SOCKET_PATH": "/tmp/herdr.sock", "HERDR_PANE_ID": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: provider, providerSessionID: sessionID), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
