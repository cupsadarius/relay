import Foundation
import XCTest

@testable import Relay

@MainActor
final class IntegrationManagerTests: XCTestCase {
    // MARK: - Fixtures

    private func envelope(provider: AgentProvider, rawPayload: String) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: provider,
            rawPayload: rawPayload,
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func event(
        provider: AgentProvider,
        providerSessionID: String = "session-1",
        text: String = "Done.",
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentResponseEvent {
        AgentResponseEvent(
            provider: provider,
            providerSessionID: providerSessionID,
            text: text,
            cwd: "/Users/me/project",
            parentPID: 100,
            environment: [:],
            capturedAt: capturedAt
        )
    }

    private func makeManager(
        speech: FakeSpeechCoordinator? = nil,
        initialStatus: [AgentProvider: IntegrationStatus] = [:],
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        onResponse: @escaping @Sendable (AgentResponseEvent) async -> Void = { _ in },
        onPrompt: @escaping @Sendable (AgentSessionID) async -> Void = { _ in }
    ) -> (manager: IntegrationManager, continuation: AsyncStream<HookEnvelope>.Continuation) {
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            speechCoordinator: speech ?? FakeSpeechCoordinator(),
            initialStatus: initialStatus,
            diagnostics: diagnostics,
            onResponse: onResponse,
            onPrompt: onPrompt
        )
        return (manager, continuation)
    }

    /// Polls `condition` on a bounded loop. Never waits unboundedly: fails the test outright if
    /// `timeout` elapses first.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Parsing and latest response

    func testClaudeEnvelopeBecomesLatest() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-1")
        let (manager, continuation) = makeManager()
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(claudeEvent))

        await waitUntil { manager.latestResponse != nil }
        XCTAssertEqual(manager.latestResponse, claudeEvent)
    }

    func testCodexEnvelopeBecomesLatest() async {
        let codexEvent = event(provider: .codex, providerSessionID: "codex-1")
        let (manager, continuation) = makeManager()
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(codexEvent))

        await waitUntil { manager.latestResponse != nil }
        XCTAssertEqual(manager.latestResponse, codexEvent)
    }

    func testUserPromptSubmitReportsThePromptAndIsNeverAResponse() async {
        let prompts = PromptRecorder()
        let responses = ResponseRecorder()
        let (manager, continuation) = makeManager(
            onResponse: { responses.record($0) },
            onPrompt: { prompts.record($0) }
        )
        manager.start()
        defer { manager.stop() }

        let payload = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/x","prompt":"hi"}"#
        continuation.yield(envelope(provider: .claudeCode, rawPayload: payload))

        await waitUntil { !prompts.ids.isEmpty }
        XCTAssertEqual(prompts.ids, [AgentSessionID(provider: .claudeCode, providerSessionID: "s1")])
        XCTAssertNil(manager.latestResponse)
        XCTAssertTrue(responses.events.isEmpty)
    }

    // MARK: - Status transitions

    func testFirstValidCodexEventFlipsStatusFromTrustRequiredToActive() async {
        let codexEvent = event(provider: .codex, capturedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let (manager, continuation) = makeManager(initialStatus: [.codex: .installedTrustRequired])
        manager.start()
        defer { manager.stop() }

        XCTAssertEqual(manager.status[.codex], .installedTrustRequired)

        continuation.yield(.stop(codexEvent))

        await waitUntil { manager.status[.codex] == .active(lastEventAt: codexEvent.capturedAt) }
    }

    func testFirstValidClaudeEventFlipsStatusToActive() async {
        let claudeEvent = event(provider: .claudeCode, capturedAt: Date(timeIntervalSince1970: 1_700_000_600))
        let (manager, continuation) = makeManager(initialStatus: [.claudeCode: .installedAwaitingFirstEvent])
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(claudeEvent))

        await waitUntil { manager.status[.claudeCode] == .active(lastEventAt: claudeEvent.capturedAt) }
    }

    // MARK: - Malformed events

    func testMalformedEnvelopeLeavesLatestStatusAndOnResponseUnchanged() async {
        let diagnostics = IntegrationDiagnosticsLog()
        let recorder = ResponseRecorder()
        let (manager, continuation) = makeManager(
            initialStatus: [.claudeCode: .installedAwaitingFirstEvent],
            diagnostics: diagnostics,
            onResponse: { recorder.record($0) }
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode, rawPayload: "not json"))

        await waitUntil { diagnostics.snapshot().contains { $0.outcome == "dropped" } }
        XCTAssertNil(manager.latestResponse)
        XCTAssertEqual(manager.status[.claudeCode], .installedAwaitingFirstEvent)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testRejectedPayloadRecordsDroppedDiagnosticsEntry() async {
        let diagnostics = IntegrationDiagnosticsLog()
        let (manager, continuation) = makeManager(diagnostics: diagnostics)
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode, rawPayload: "not json"))

        await waitUntil {
            diagnostics.snapshot().contains { $0.outcome == "dropped" && $0.detail.contains("adapter-rejected") }
        }
        let dropped = diagnostics.snapshot().first { $0.outcome == "dropped" }
        XCTAssertEqual(dropped?.stage, "manager")
    }

    // MARK: - Replacement

    func testSecondEventReplacesLatest() async {
        let firstEvent = event(provider: .claudeCode, providerSessionID: "first")
        let secondEvent = event(provider: .codex, providerSessionID: "second")
        let (manager, continuation) = makeManager()
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(firstEvent))
        await waitUntil { manager.latestResponse == firstEvent }

        continuation.yield(.stop(secondEvent))
        await waitUntil { manager.latestResponse == secondEvent }
    }

    // MARK: - onResponse callback

    /// The manager publishes every response through `onResponse` and never speaks itself.
    func testOnResponseInvokedOnceForEachProvidersResponse() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-onresponse-1", text: "**Done.** All set.")
        let codexEvent = event(provider: .codex, providerSessionID: "codex-onresponse-1", text: "Finished the task.")
        let speech = FakeSpeechCoordinator()
        let recorder = ResponseRecorder()
        let (manager, continuation) = makeManager(speech: speech, onResponse: { recorder.record($0) })
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(claudeEvent))
        continuation.yield(.stop(codexEvent))

        await waitUntil { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events, [claudeEvent, codexEvent])
        XCTAssertTrue(speech.requests.isEmpty)
    }

    // MARK: - speakLatest

    func testSpeakLatestPreprocessesThenSubmitsUserRequestedSpeech() async throws {
        let rawText = "**Done.**\n```swift\nlet secret = 1\n```\nAll set."
        let latest = event(provider: .codex, providerSessionID: "codex-session-42", text: rawText)
        let speech = FakeSpeechCoordinator()
        let (manager, continuation) = makeManager(speech: speech)
        manager.start()
        defer { manager.stop() }
        continuation.yield(.stop(latest))
        await waitUntil { manager.latestResponse != nil }

        let spoke = try await manager.speakLatest()

        XCTAssertTrue(spoke)
        XCTAssertEqual(speech.requests.count, 1)
        let request = try XCTUnwrap(speech.requests.first)
        XCTAssertEqual(request.text, RulesSpeechPreprocessor().prepare(text: rawText))
        XCTAssertEqual(request.source, .codex)
        XCTAssertEqual(request.mode, .userRequested)
        XCTAssertEqual(request.sessionID, "codex:codex-session-42")
    }

    func testSpeakLatestWithClaudeEventUsesClaudeSource() async throws {
        let latest = event(provider: .claudeCode, providerSessionID: "claude-session-7", text: "All done.")
        let speech = FakeSpeechCoordinator()
        let (manager, continuation) = makeManager(speech: speech)
        manager.start()
        defer { manager.stop() }
        continuation.yield(.stop(latest))
        await waitUntil { manager.latestResponse != nil }

        try await manager.speakLatest()

        let request = try XCTUnwrap(speech.requests.first)
        XCTAssertEqual(request.source, .claudeCode)
        XCTAssertEqual(request.mode, .userRequested)
        XCTAssertEqual(request.sessionID, "claude-code:claude-session-7")
    }

    func testSpeakLatestWithNoResponseSubmitsNothing() async throws {
        let speech = FakeSpeechCoordinator()
        let (manager, _) = makeManager(speech: speech)

        let spoke = try await manager.speakLatest()

        XCTAssertFalse(spoke)
        XCTAssertTrue(speech.requests.isEmpty)
    }

    // MARK: - Diagnostics

    func testAcceptedEventRecordsEventAcceptedThenOnResponseReturned() async {
        let diagnostics = IntegrationDiagnosticsLog()
        let (manager, continuation) = makeManager(diagnostics: diagnostics)
        manager.start()
        defer { manager.stop() }

        continuation.yield(.stop(event(provider: .claudeCode, providerSessionID: "claude-diag-1")))

        await waitUntil { diagnostics.snapshot().contains { $0.outcome == "onResponse-returned" } }

        let entries = diagnostics.snapshot()
        let acceptedIndex = entries.firstIndex { $0.outcome == "event-accepted" }
        let returnedIndex = entries.firstIndex { $0.outcome == "onResponse-returned" }
        XCTAssertNotNil(acceptedIndex)
        XCTAssertNotNil(returnedIndex)
        if let acceptedIndex, let returnedIndex {
            // Newest-first snapshot: onResponse-returned was recorded after event-accepted, so it
            // appears at a lower index.
            XCTAssertLessThan(returnedIndex, acceptedIndex)
        }
    }
}

// MARK: - Test doubles

/// Thread-safe: the manager calls `onPrompt` off the MainActor.
private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentSessionID] = []

    func record(_ id: AgentSessionID) { lock.withLock { recorded.append(id) } }
    var ids: [AgentSessionID] { lock.withLock { recorded } }
}

private final class ResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentResponseEvent] = []

    func record(_ event: AgentResponseEvent) { lock.withLock { recorded.append(event) } }
    var events: [AgentResponseEvent] { lock.withLock { recorded } }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []

    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
    }
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {}
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}
