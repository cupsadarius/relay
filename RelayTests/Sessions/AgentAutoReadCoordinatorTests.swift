import XCTest
@testable import Relay

@MainActor
final class AgentAutoReadCoordinatorTests: XCTestCase {
    func testFocusedSessionSpeaksAutomatically() async throws {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true)
        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "a")

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "**Done.**"))

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests[0].mode, .automatic)
        XCTAssertEqual(speech.requests[0].sessionID, "claude-code:a")
    }

    func testBackgroundResponseStaysSilentButRegistryKeepsIt() async throws {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        let harness = makeCoordinatorHarness(focus: focus, speech: speech, autoRead: true)
        // Nobody focused yet and "a" has never been the last-active session: stays silent.
        await harness.coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "background"))

        XCTAssertTrue(speech.requests.isEmpty)
        let sessions = await harness.registry.sessions()
        XCTAssertEqual(sessions.first?.latestResponse.text, "background")
    }

    func testNobodyFocusedAndSessionNeverLastActiveStaysSilent() async {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver() // nobody focused
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testDisabledAutoReadSkipsFocusAndSpeech() async {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "a")
        let harness = makeCoordinatorHarness(focus: focus, speech: speech, autoRead: false)

        await harness.coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

        XCTAssertTrue(speech.requests.isEmpty)
        // Auto-read being disabled must still upsert the session into the registry, so a
        // background response remains available for manual "Speak Latest".
        let sessions = await harness.registry.sessions()
        XCTAssertEqual(sessions.first?.latestResponse.text, "done")
    }

    // MARK: - Last-active handoff (rule 2)

    /// S is confidently focused (rule 1), then focus is lost entirely (the user tabs to a
    /// non-agent app). S, being the last-active session, keeps reading.
    func testSessionKeepsReadingAsLastActiveAfterFocusIsLost() async {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        let sessionA = AgentSessionID(provider: .claudeCode, providerSessionID: "a")
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true)

        focus.focusedSessionID = sessionA
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "first"))
        XCTAssertEqual(speech.requests.count, 1)

        focus.focusedSessionID = nil // user tabbed away to a non-agent app
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "second"))

        XCTAssertEqual(speech.requests.count, 2)
        XCTAssertEqual(speech.requests[1].sessionID, "claude-code:a")
    }

    /// A different session becomes confidently focused: the original background session stays
    /// silent, and focus ownership (last-active) hands off to the newly-focused session.
    func testDifferentFocusedSessionSilencesBackgroundAndBecomesLastActive() async {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        let sessionA = AgentSessionID(provider: .claudeCode, providerSessionID: "a")
        let sessionB = AgentSessionID(provider: .claudeCode, providerSessionID: "b")
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true)

        focus.focusedSessionID = sessionA
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "first"))
        XCTAssertEqual(speech.requests.count, 1)

        // Register B so it's a candidate the focus resolver can return.
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "b", text: "b-background"))

        // Now B becomes confidently focused; A's next response must stay silent...
        focus.focusedSessionID = sessionB
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "a-again"))
        XCTAssertEqual(speech.requests.count, 1, "A must stay silent while B is confidently focused")

        // ...and the handoff means B - not A - now keeps reading once focus is lost entirely.
        focus.focusedSessionID = nil
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "b", text: "b-again"))
        XCTAssertEqual(speech.requests.count, 2)
        XCTAssertEqual(speech.requests[1].sessionID, "claude-code:b")
    }

    // MARK: - Diagnostics

    func testFocusedSessionRecordsSpokeDiagnosticsEntry() async throws {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "a")
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true, diagnostics: diagnostics)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "**Done.**"))

        let entries = diagnostics.snapshot()
        XCTAssertTrue(entries.contains { $0.stage == "coordinator" && $0.outcome == "spoke" && $0.detail.contains("reason=focused") })
        XCTAssertTrue(entries.contains { $0.stage == "coordinator" && $0.outcome == "session-upserted" })
    }

    func testAutoReadDisabledRecordsSilentDiagnosticsEntry() async {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: false, diagnostics: diagnostics)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

        let silent = diagnostics.snapshot().first { $0.stage == "coordinator" && $0.outcome == "silent" }
        XCTAssertNotNil(silent)
        XCTAssertEqual(silent?.detail, "auto-read-disabled")
    }

    func testNobodyFocusedRecordsFocusDecisionThenSilentDiagnosticsEntries() async {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true, diagnostics: diagnostics)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

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
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("focused=none"))
        XCTAssertTrue(entries[focusDecisionIndex!].detail.contains("lastActive=none"))
        XCTAssertEqual(entries[silentIndex!].detail, "reason=not-focused-not-last-active")
    }

    // MARK: - Pruning

    /// A session whose root process has since died must be pruned before the focus resolver ever
    /// sees it — proven here by inspecting exactly what `focusedSession(among:)` was called with,
    /// not merely the eventual registry contents.
    func testDeadSessionIsPrunedBeforeFocusResolution() async {
        let speech = RecordingSpeechSink()
        let focus = MutableStubFocusResolver()
        let runner = MutableAliveProcessRunner(alivePIDs: [111, 222])
        let harness = makeCoordinatorHarness(
            focus: focus,
            speech: speech,
            autoRead: true,
            processInspector: ProcessInspector(runner: runner)
        )

        await harness.coordinator.handle(makeAutoReadEvent(providerSessionID: "dead", text: "stale", parentPID: 111))
        runner.alivePIDs = [222] // pid 111's process has since exited
        await harness.coordinator.handle(makeAutoReadEvent(providerSessionID: "alive", text: "fresh", parentPID: 222))

        let deadID = AgentSessionID(provider: .claudeCode, providerSessionID: "dead")
        let aliveID = AgentSessionID(provider: .claudeCode, providerSessionID: "alive")
        XCTAssertEqual(focus.lastAmongIDs, [aliveID], "dead session must not be offered to the focus resolver")
        XCTAssertFalse(focus.lastAmongIDs.contains(deadID))

        let remaining = await harness.registry.sessions()
        XCTAssertEqual(remaining.map(\.id), [aliveID])
    }

    func testDifferentSessionFocusedDiagnosticsEntryRecordsBothIDs() async throws {
        let speech = RecordingSpeechSink()
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true, diagnostics: diagnostics)

        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "a")
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "first"))

        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "b")
        await coordinator.handle(makeAutoReadEvent(providerSessionID: "b", text: "second"))
        diagnostics.clear()

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "third"))

        let focusDecision = diagnostics.snapshot().first { $0.outcome == "focus-decision" }
        XCTAssertEqual(focusDecision?.detail, "focused=claude-code:b lastActive=claude-code:b")
    }
}

private final class MutableStubFocusResolver: SessionFocusResolving, @unchecked Sendable {
    var focusedSessionID: AgentSessionID?
    /// The ids `focusedSession(among:)` was most recently called with, so tests can prove pruning
    /// happened before this resolver ever saw a candidate list.
    private(set) var lastAmongIDs: [AgentSessionID] = []

    func resolve(session: AgentSession) async -> FocusDecision {
        session.id == focusedSessionID
            ? .focused(resolverID: "stub", reason: "stubbed focused session")
            : .unknown(resolverID: "stub", reason: "not the stubbed focused session")
    }

    func focusedSession(among sessions: [AgentSession]) async -> AgentSession? {
        lastAmongIDs = sessions.map(\.id)
        guard let focusedSessionID else { return nil }
        return sessions.first { $0.id == focusedSessionID }
    }
}

/// Reports every pid in a wide synthetic range as alive, standing in for a live process table so
/// existing coordinator tests (which use small fabricated pids for `processAncestry`) aren't
/// treated as dead now that `AgentAutoReadCoordinator` prunes before every focus decision.
private final class AlwaysAliveProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let lines = (1...2_000).map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
}

/// Reports only `alivePIDs` as alive; mutable so a single test can simulate a process exiting
/// between two `handle(_:)` calls.
private final class MutableAliveProcessRunner: ProcessRunning, @unchecked Sendable {
    var alivePIDs: Set<Int32>
    init(alivePIDs: Set<Int32>) { self.alivePIDs = alivePIDs }
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let lines = alivePIDs.map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
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
    focus: MutableStubFocusResolver,
    speech: RecordingSpeechSink,
    autoRead: Bool,
    diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
    processInspector: ProcessInspector = ProcessInspector(runner: AlwaysAliveProcessRunner())
) -> AutoReadHarness {
    let registry = AgentSessionRegistry()
    let coordinator = AgentAutoReadCoordinator(
        registry: registry,
        processContext: StubProcessContextCapture(),
        focus: focus,
        preprocess: { $0.replacingOccurrences(of: "**", with: "") },
        speech: speech,
        autoReadEnabled: { autoRead },
        diagnostics: diagnostics,
        processInspector: processInspector
    )
    return .init(coordinator: coordinator, registry: registry)
}

@MainActor
private func makeCoordinator(
    focus: MutableStubFocusResolver,
    speech: RecordingSpeechSink,
    autoRead: Bool,
    diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
    processInspector: ProcessInspector = ProcessInspector(runner: AlwaysAliveProcessRunner())
) -> AgentAutoReadCoordinator {
    makeCoordinatorHarness(focus: focus, speech: speech, autoRead: autoRead, diagnostics: diagnostics, processInspector: processInspector).coordinator
}

private func makeAutoReadEvent(providerSessionID: String = "a", text: String, parentPID: Int32 = 900) -> AgentResponseEvent {
    .init(
        id: UUID(), provider: .claudeCode, providerSessionID: providerSessionID, turnID: nil,
        text: text, cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: parentPID, environment: [:], capturedAt: Date()
    )
}
