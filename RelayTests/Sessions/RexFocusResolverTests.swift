import XCTest

@testable import Relay

final class RexFocusResolverTests: XCTestCase {
    func testProducingBlockFocusedWhileRexIsFrontmostIsFocused() async {
        let resolver = RexFocusResolver(rex: StubRexQuery(focusedBlockID: "block:a"))
        let session = makeRexSession(block: "block:a")

        let decision = await resolver.resolve(session: session, context: rexContext(session, bundleID: "com.superlogical.rex"))

        XCTAssertEqual(decision.state, .focused)
    }

    func testAnotherFocusedBlockIsNotFocused() async {
        let resolver = RexFocusResolver(rex: StubRexQuery(focusedBlockID: "block:b"))
        let session = makeRexSession(block: "block:a")

        let decision = await resolver.resolve(session: session, context: rexContext(session, bundleID: "com.superlogical.rex"))

        XCTAssertEqual(decision.state, .notFocused)
    }

    func testRexNotFrontmostIsNotFocused() async {
        let resolver = RexFocusResolver(rex: StubRexQuery(focusedBlockID: "block:a"))
        let session = makeRexSession(block: "block:a")

        let decision = await resolver.resolve(session: session, context: rexContext(session, bundleID: "com.apple.Safari"))

        XCTAssertEqual(decision.state, .notFocused)
    }

    func testFailedQueryIsUnknown() async {
        let resolver = RexFocusResolver(rex: StubRexQuery(focusedBlockID: nil))
        let session = makeRexSession(block: "block:a")

        let decision = await resolver.resolve(session: session, context: rexContext(session, bundleID: "com.superlogical.rex"))

        XCTAssertEqual(decision.state, .unknown)
    }

    func testOnlyRexSessionsAreSupportedAndGenericTerminalSkipsThem() {
        let session = makeRexSession(block: "block:a")

        XCTAssertTrue(RexFocusResolver(rex: StubRexQuery(focusedBlockID: nil)).supports(session))
        XCTAssertFalse(GenericTerminalFocusResolver().supports(session))
    }

    func testFocusedBlockComesFromTheActiveWindow() throws {
        let view = """
            {"active_window_id":"window:2","windows":[
              {"window_id":"window:1","focused_block_id":"block:1"},
              {"window_id":"window:2","focused_block_id":"block:2"}]}
            """

        XCTAssertEqual(try RexClient.focusedBlockID(inSessionView: Data(view.utf8)), "block:2")
    }
}

private struct StubRexQuery: RexQuerying {
    struct Failure: Error {}
    /// `nil` makes the query throw.
    let focusedBlockID: String?

    func focusedBlockID(server: String?, sessionID: String) async throws -> String? {
        guard let focusedBlockID else { throw Failure() }
        return focusedBlockID
    }
}

private func rexContext(_ session: AgentSession, bundleID: String) -> FocusContext {
    FocusContext(
        frontmostApplication: .init(pid: 20, bundleIdentifier: bundleID),
        sessions: [session],
        processSnapshot: nil
    )
}

private func makeRexSession(block: String) -> AgentSession {
    let event = AgentResponseEvent(
        provider: .claudeCode, providerSessionID: "a",
        text: "done", cwd: "/tmp/repo", parentPID: 900,
        environment: ["REX_SERVER": "unix:///tmp/rex.sock", "REX_SESSION": "session:1", "REX_BLOCK": block],
        capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [],
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
