import XCTest
@testable import Relay

final class FocusResolutionServiceTests: XCTestCase {
    func testHighFocusedStopsResolution() async {
        let resolver = StubFocusResolver(
            id: "exact",
            decision: .focused(resolverID: "exact", reason: "exact pane")
        )
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [resolver]
        )
        let decision = await service.resolve(session: makeSession())
        XCTAssertEqual(decision.state, .focused)
        XCTAssertEqual(decision.confidence, .high)
    }

    func testUnknownNeverBecomesFocusedByDefault() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "x", decision: .unknown(resolverID: "x", reason: "ambiguous"))]
        )
        let decision = await service.resolve(session: makeSession())
        XCTAssertEqual(decision.state, .unknown)
    }
}

private struct StubFrontmostApp: FrontmostAppMonitoring {
    let pid: Int32
    func current() async -> FrontmostApplication? {
        .init(pid: pid, bundleIdentifier: nil, localizedName: "Test Terminal")
    }
}

private struct StubFocusResolver: FocusResolver {
    let id: String
    let decision: FocusDecision
    func supports(_ session: AgentSession) -> Bool { true }
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision { decision }
}

private func makeSession() -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: "done", cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: 900, environment: [:], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"),
        cwd: event.cwd,
        terminalContext: TerminalContext(event: event),
        processAncestry: [900, 20, 1],
        tty: "/dev/ttys001",
        latestResponse: event,
        lastActivityAt: event.capturedAt
    )
}
