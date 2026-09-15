import XCTest
@testable import Relay

@MainActor
final class AgentAutoReadCoordinatorTests: XCTestCase {
    func testFocusedHighResponseSpeaksAutomatically() async throws {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .focused(resolverID: "tmux", reason: "exact pane"), speech: speech, autoRead: true)
        await coordinator.handle(makeAutoReadEvent(text: "**Done.**"))
        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests[0].mode, .automatic)
        XCTAssertEqual(speech.requests[0].sessionID, "claude-code:a")
    }

    func testBackgroundResponseStaysSilentButRegistryKeepsIt() async throws {
        let speech = RecordingSpeechSink()
        let harness = makeCoordinatorHarness(focus: .notFocused(resolverID: "tmux", reason: "other pane"), speech: speech, autoRead: true)
        await harness.coordinator.handle(makeAutoReadEvent(text: "background"))
        XCTAssertTrue(speech.requests.isEmpty)
        let sessions = await harness.registry.sessions()
        XCTAssertEqual(sessions.first?.latestResponse.text, "background")
    }

    func testUnknownFocusStaysSilent() async {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .unknown(resolverID: "generic", reason: "ambiguous"), speech: speech, autoRead: true)
        await coordinator.handle(makeAutoReadEvent(text: "done"))
        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testDisabledAutoReadSkipsFocusAndSpeech() async {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .focused(resolverID: "tmux", reason: "exact pane"), speech: speech, autoRead: false)
        await coordinator.handle(makeAutoReadEvent(text: "done"))
        XCTAssertTrue(speech.requests.isEmpty)
    }
}

private struct StubSessionFocusResolver: SessionFocusResolving {
    let decision: FocusDecision
    func resolve(session: AgentSession) async -> FocusDecision { decision }
}

private struct StubProcessContextCapture: AgentProcessContextCapturing {
    func capture(parentPID: Int32) async -> AgentProcessContext {
        .init(ancestry: [parentPID, 20, 1], tty: "/dev/ttys001")
    }
}

/// `@unchecked Sendable`: `AgentAutoReadCoordinator` requires `any SpeechSubmitting & Sendable`
/// (see that type's doc comment) since it calls `speak(_:)` — `@MainActor`-isolated — from its own
/// actor isolation. All mutable state here (`requests`) is touched only from `@MainActor`.
@MainActor
private final class RecordingSpeechSink: SpeechSubmitting, @unchecked Sendable {
    var requests: [SpeechRequest] = []
    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
}

private struct AutoReadHarness {
    let coordinator: AgentAutoReadCoordinator
    let registry: AgentSessionRegistry
}

@MainActor
private func makeCoordinatorHarness(
    focus: FocusDecision,
    speech: RecordingSpeechSink,
    autoRead: Bool
) -> AutoReadHarness {
    let registry = AgentSessionRegistry()
    let coordinator = AgentAutoReadCoordinator(
        registry: registry,
        processContext: StubProcessContextCapture(),
        focus: StubSessionFocusResolver(decision: focus),
        preprocess: { $0.replacingOccurrences(of: "**", with: "") },
        speech: speech,
        autoReadEnabled: { autoRead }
    )
    return .init(coordinator: coordinator, registry: registry)
}

@MainActor
private func makeCoordinator(
    focus: FocusDecision,
    speech: RecordingSpeechSink,
    autoRead: Bool
) -> AgentAutoReadCoordinator {
    makeCoordinatorHarness(focus: focus, speech: speech, autoRead: autoRead).coordinator
}

private func makeAutoReadEvent(text: String) -> AgentResponseEvent {
    .init(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: text, cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: 900, environment: [:], capturedAt: Date()
    )
}
