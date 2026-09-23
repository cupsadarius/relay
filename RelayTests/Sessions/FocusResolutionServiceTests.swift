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

    func testResolveFocusReturnsTheFirstConfidentlyFocusedSessionAndStopsThere() async {
        let a = makeSession(providerSessionID: "a")
        let b = makeSession(providerSessionID: "b")
        let c = makeSession(providerSessionID: "c")
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [SelectiveFocusResolver(focusedSessionID: b.id)]
        )

        let result = await service.resolveFocus(among: [a, b, c], processSnapshot: nil)

        XCTAssertEqual(result.focused?.id, b.id)
        XCTAssertEqual(result.decisions.map(\.state), [.unknown, .focused])
    }

    func testResolveFocusReturnsNilWhenNoneAreConfidentlyFocused() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "x", decision: .unknown(resolverID: "x", reason: "ambiguous"))]
        )

        let result = await service.resolveFocus(among: [makeSession(), makeSession(providerSessionID: "b")], processSnapshot: nil)

        XCTAssertNil(result.focused)
        XCTAssertEqual(result.decisions.count, 2)
    }

    func testResolveFocusLooksUpTheFrontmostAppOnceAndSharesOneSnapshot() async throws {
        let frontmost = CountingFrontmostApp(pid: 20)
        let recorder = SnapshotRecordingResolver()
        let service = FocusResolutionService(registry: AgentSessionRegistry(), frontmostApps: frontmost, resolvers: [recorder])
        let snapshot = try ProcessSnapshot.parse("42 1 ?? agent")

        _ = await service.resolveFocus(
            among: [makeSession(providerSessionID: "a"), makeSession(providerSessionID: "b"), makeSession(providerSessionID: "c")],
            processSnapshot: snapshot
        )

        let lookups = await frontmost.lookups
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(recorder.sawSnapshotContainingPID42, [true, true, true])
    }

    func testUnresolvedSessionKeepsTheResolversSpecificReason() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "generic-terminal", decision: .unknown(resolverID: "generic-terminal", reason: "ambiguous"))]
        )

        let decision = await service.resolve(session: makeSession())

        XCTAssertEqual(decision.resolverID, "generic-terminal")
        XCTAssertEqual(decision.reason, "ambiguous")
    }
}

private actor CountingFrontmostApp: FrontmostAppMonitoring {
    let pid: Int32
    private(set) var lookups = 0
    init(pid: Int32) { self.pid = pid }
    func current() async -> FrontmostApplication? {
        lookups += 1
        return .init(pid: pid, bundleIdentifier: nil, localizedName: "Test Terminal")
    }
}

private final class SnapshotRecordingResolver: FocusResolver, @unchecked Sendable {
    let id = "recorder"
    private let lock = NSLock()
    private var seen: [Bool] = []
    var sawSnapshotContainingPID42: [Bool] { lock.withLock { seen } }
    func supports(_ session: AgentSession) -> Bool { true }
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        let saw = context.processSnapshot?.record(pid: 42) != nil
        lock.withLock { seen.append(saw) }
        return .unknown(resolverID: id, reason: "recording")
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
