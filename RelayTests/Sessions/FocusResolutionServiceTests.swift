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

    func testFocusedSessionAmongReturnsTheConfidentlyFocusedOne() async {
        let focusedSession = makeSession(providerSessionID: "focused-one")
        let otherSession = makeSession(providerSessionID: "other")
        let resolver = SelectiveFocusResolver(focusedSessionID: focusedSession.id)
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [resolver]
        )

        let result = await service.focusedSession(among: [otherSession, focusedSession])

        XCTAssertEqual(result?.id, focusedSession.id)
    }

    func testFocusedSessionAmongReturnsNilWhenNoneAreConfidentlyFocused() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "x", decision: .unknown(resolverID: "x", reason: "ambiguous"))]
        )

        let result = await service.focusedSession(among: [makeSession(), makeSession(providerSessionID: "b")])

        XCTAssertNil(result)
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

/// Resolves exactly one session (by id) as confidently focused; every other session is `.unknown`.
private struct SelectiveFocusResolver: FocusResolver {
    let id = "selective"
    let focusedSessionID: AgentSessionID
    func supports(_ session: AgentSession) -> Bool { true }
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        session.id == focusedSessionID
            ? .focused(resolverID: id, reason: "matched")
            : .unknown(resolverID: id, reason: "not matched")
    }
}

private func makeSession(providerSessionID: String = "a") -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: providerSessionID,
        text: "done", cwd: "/tmp/repo",
        parentPID: 900, environment: [:], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: providerSessionID),
        cwd: event.cwd,
        terminalContext: TerminalContext(event: event),
        processAncestry: [900, 20, 1],
        tty: "/dev/ttys001",
        latestResponse: event,
        lastActivityAt: event.capturedAt
    )
}
