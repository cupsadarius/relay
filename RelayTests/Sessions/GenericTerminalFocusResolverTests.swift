import XCTest
@testable import Relay

final class GenericTerminalFocusResolverTests: XCTestCase {
    func testSingleDirectSessionWhoseAncestryContainsFrontmostAppIsFocused() async {
        let session = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: "com.example.Terminal", localizedName: "Terminal Host"),
            sessions: [session],
            now: Date()
        )
        let decision = await GenericTerminalFocusResolver().resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .focused)
        XCTAssertEqual(decision.confidence, .high)
    }

    func testTwoDirectSessionsUnderSameFrontmostAppAreUnknown() async {
        let a = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let b = makeDirectSession(id: "b", ancestry: [901, 101, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Any Terminal"),
            sessions: [a, b],
            now: Date()
        )
        let decision = await GenericTerminalFocusResolver().resolve(session: a, context: context)
        XCTAssertEqual(decision.state, .unknown)
    }

    func testDifferentFrontmostAppIsNotFocused() async {
        let session = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 88, bundleIdentifier: "com.apple.Safari", localizedName: "Safari"),
            sessions: [session],
            now: Date()
        )
        let decision = await GenericTerminalFocusResolver().resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .notFocused)
    }
}

private func makeDirectSession(id: String, ancestry: [Int32]) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: id,
        text: "done", cwd: "/tmp/\(id)",
        parentPID: ancestry.first ?? 0, environment: [:], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: id),
        cwd: event.cwd,
        terminalContext: TerminalContext(event: event),
        processAncestry: ancestry,
        tty: nil,
        latestResponse: event,
        lastActivityAt: event.capturedAt
    )
}
