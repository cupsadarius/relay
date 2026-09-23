import XCTest
@testable import Relay

@MainActor
final class ReplayLastResolverTests: XCTestCase {
    private func makeResolver(
        registry: AgentSessionRegistry,
        focused: AgentSessionID? = nil,
        frontmostPID: Int32? = nil,
        runner: any ProcessRunning = AllPIDsAliveProcessRunner()
    ) -> ReplayLastResolver {
        ReplayLastResolver(
            registry: registry,
            processInspector: ProcessInspector(runner: runner),
            focusResolution: StubSessionFocusResolver(focusedSessionID: focused),
            frontmostApps: StubFrontmostAppMonitor(pid: frontmostPID)
        )
    }

    private func upsert(_ registry: AgentSessionRegistry, _ id: String, ancestry: [Int32] = []) async -> AgentSession {
        await registry.upsert(response: .fixture(providerSessionID: id), processAncestry: ancestry, tty: nil)
    }

    func testConfidentlyFocusedSessionWins() async {
        let registry = AgentSessionRegistry()
        let sessionA = await upsert(registry, "session-a")
        _ = await upsert(registry, "session-b")

        let target = await makeResolver(registry: registry, focused: sessionA.id)
            .resolve(globalLatestAvailable: { true })

        guard case let .focusedSession(session) = target else { return XCTFail("got \(target)") }
        XCTAssertEqual(session.id, sessionA.id)
    }

    func testDeadProcessSessionIsPrunedBeforeFocusResolution() async {
        let registry = AgentSessionRegistry()
        let dead = await upsert(registry, "dead-session", ancestry: [1_234_567])

        let target = await makeResolver(registry: registry, focused: dead.id, runner: AllPIDsDeadProcessRunner())
            .resolve(globalLatestAvailable: { false })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testAmbiguousFocusWithFrontmostHostingASessionPrefersGlobalLatest() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 4242)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .globalLatest)
    }

    func testFrontmostHostingNoSessionFallsBackToLastSpoken() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 9999)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testNoFrontmostApplicationFallsBackToLastSpoken() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: nil)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testEmptyGlobalLatestFallsBackToLastSpokenEvenWhenFrontmostHostsASession() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 4242)
            .resolve(globalLatestAvailable: { false })

        XCTAssertEqual(target, .lastSpoken)
    }
}
