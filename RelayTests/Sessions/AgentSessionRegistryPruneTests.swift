import XCTest
@testable import Relay

final class AgentSessionRegistryPruneTests: XCTestCase {
    func testPruneRemovesDeadProcessSessions() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(response: makeEvent(session: "a", at: 100), processAncestry: [111, 20, 1], tty: nil)
        let b = await registry.upsert(response: makeEvent(session: "b", at: 100), processAncestry: [222, 20, 1], tty: nil)

        await registry.prune(now: Date(timeIntervalSince1970: 130), isAlive: { $0 != 111 })

        let remaining = await registry.sessions()
        XCTAssertEqual(remaining.map(\.id), [b.id])
    }

    func testPruneRemovesSessionsPastTTL() async {
        let registry = AgentSessionRegistry()
        let session = await registry.upsert(response: makeEvent(session: "a", at: 0), processAncestry: [111, 20, 1], tty: nil)
        let inserted = await registry.sessions()
        XCTAssertEqual(inserted.map(\.id), [session.id])

        await registry.prune(
            now: Date(timeIntervalSince1970: 0).addingTimeInterval(21 * 60),
            ttl: 20 * 60,
            isAlive: { _ in true }
        )

        let remaining = await registry.sessions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPruneKeepsFreshLiveSessions() async {
        let registry = AgentSessionRegistry()
        let session = await registry.upsert(response: makeEvent(session: "a", at: 1_000), processAncestry: [111, 20, 1], tty: nil)

        await registry.prune(
            now: Date(timeIntervalSince1970: 1_000).addingTimeInterval(60),
            ttl: 20 * 60,
            isAlive: { _ in true }
        )

        let remaining = await registry.sessions()
        XCTAssertEqual(remaining.map(\.id), [session.id])
    }

    private func makeEvent(session: String, at: TimeInterval = 100) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(), provider: .claudeCode, providerSessionID: session,
            text: "response", cwd: "/tmp/repo",
            parentPID: 42, environment: [:], capturedAt: Date(timeIntervalSince1970: at)
        )
    }
}
