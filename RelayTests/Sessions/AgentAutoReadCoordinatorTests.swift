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

    // MARK: - Diagnostics

    func testFocusedHighConfidenceRecordsSpokeDiagnosticsEntry() async throws {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let coordinator = makeCoordinator(
            focus: .focused(resolverID: "tmux", reason: "exact pane"),
            speech: speech,
            autoRead: true,
            diagnostics: diagnostics
        )
        await coordinator.handle(makeAutoReadEvent(text: "**Done.**"))

        let entries = diagnostics.snapshot()
        XCTAssertTrue(entries.contains { $0.stage == "coordinator" && $0.outcome == "spoke" })
        XCTAssertTrue(entries.contains { $0.stage == "coordinator" && $0.outcome == "session-upserted" })
    }

    func testAutoReadDisabledRecordsSilentDiagnosticsEntry() async {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let coordinator = makeCoordinator(
            focus: .focused(resolverID: "tmux", reason: "exact pane"),
            speech: speech,
            autoRead: false,
            diagnostics: diagnostics
        )
        await coordinator.handle(makeAutoReadEvent(text: "done"))

        let silent = diagnostics.snapshot().first { $0.stage == "coordinator" && $0.outcome == "silent" }
        XCTAssertNotNil(silent)
        XCTAssertEqual(silent?.detail, "auto-read-disabled")
    }

    func testUnknownFocusRecordsFocusDecisionThenSilentDiagnosticsEntries() async {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let coordinator = makeCoordinator(
            focus: .unknown(resolverID: "generic", reason: "ambiguous"),
            speech: speech,
            autoRead: true,
            diagnostics: diagnostics
        )
        await coordinator.handle(makeAutoReadEvent(text: "done"))

        let entries = diagnostics.snapshot()
        let focusDecisionIndex = entries.firstIndex { $0.outcome == "focus-decision" }
        let silentIndex = entries.firstIndex { $0.outcome == "silent" }
        XCTAssertNotNil(focusDecisionIndex)
        XCTAssertNotNil(silentIndex)
        if let focusDecisionIndex, let silentIndex {
            // Newest-first snapshot: "silent" was recorded after "focus-decision", so it appears
            // at a lower index.
            XCTAssertLessThan(silentIndex, focusDecisionIndex)
        }
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("state=unknown"))
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("confidence=low"))
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("resolver=generic"))
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("reason=ambiguous"))
    }

    func testFocusDecisionDiagnosticsEntryIncludesResolverAndReason() async throws {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let coordinator = makeCoordinator(
            focus: .notFocused(resolverID: "tmux", reason: "other pane"),
            speech: speech,
            autoRead: true,
            diagnostics: diagnostics
        )
        await coordinator.handle(makeAutoReadEvent(text: "done"))

        let entries = diagnostics.snapshot()
        let focusDecision = entries.first { $0.outcome == "focus-decision" }
        XCTAssertEqual(
            focusDecision?.detail,
            "state=notFocused confidence=high resolver=tmux reason=other pane"
        )
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
    autoRead: Bool,
    diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
) -> AutoReadHarness {
    let registry = AgentSessionRegistry()
    let coordinator = AgentAutoReadCoordinator(
        registry: registry,
        processContext: StubProcessContextCapture(),
        focus: StubSessionFocusResolver(decision: focus),
        preprocess: { $0.replacingOccurrences(of: "**", with: "") },
        speech: speech,
        autoReadEnabled: { autoRead },
        diagnostics: diagnostics
    )
    return .init(coordinator: coordinator, registry: registry)
}

@MainActor
private func makeCoordinator(
    focus: FocusDecision,
    speech: RecordingSpeechSink,
    autoRead: Bool,
    diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
) -> AgentAutoReadCoordinator {
    makeCoordinatorHarness(focus: focus, speech: speech, autoRead: autoRead, diagnostics: diagnostics).coordinator
}

private func makeAutoReadEvent(text: String) -> AgentResponseEvent {
    .init(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: text, cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: 900, environment: [:], capturedAt: Date()
    )
}
