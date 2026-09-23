import Foundation
import XCTest

@testable import Relay

@MainActor
final class IntegrationManagerTests: XCTestCase {
    // MARK: - Fixtures

    private func envelope(
        provider: AgentProvider,
        rawPayload: String = "{}",
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: provider,
            rawPayload: rawPayload,
            parentPID: 100,
            environment: [:],
            capturedAt: capturedAt
        )
    }

    private func event(
        provider: AgentProvider,
        providerSessionID: String = "session-1",
        text: String = "Done.",
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(),
            provider: provider,
            providerSessionID: providerSessionID,
            text: text,
            cwd: "/Users/me/project",
            parentPID: 100,
            environment: [:],
            capturedAt: capturedAt
        )
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

    // MARK: - Provider dispatch

    func testClaudeEnvelopeIsDecodedOnlyByClaudeAdapterAndBecomesLatest() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-1")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        let codex = SpyIntegration(provider: .codex, result: .failure(TestError.shouldNotBeCalled))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude, codex],
            speechCoordinator: FakeSpeechCoordinator()
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        await waitUntil { manager.latestResponse != nil }

        XCTAssertEqual(manager.latestResponse, claudeEvent)
        XCTAssertEqual(claude.decodeCount, 1)
        XCTAssertEqual(codex.decodeCount, 0)
    }

    func testCodexEnvelopeIsDecodedOnlyByCodexAdapterAndBecomesLatest() async {
        let codexEvent = event(provider: .codex, providerSessionID: "codex-1")
        let claude = SpyIntegration(provider: .claudeCode, result: .failure(TestError.shouldNotBeCalled))
        let codex = SpyIntegration(provider: .codex, result: .success(codexEvent))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude, codex],
            speechCoordinator: FakeSpeechCoordinator()
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .codex))

        await waitUntil { manager.latestResponse != nil }

        XCTAssertEqual(manager.latestResponse, codexEvent)
        XCTAssertEqual(codex.decodeCount, 1)
        XCTAssertEqual(claude.decodeCount, 0)
    }

    // MARK: - Status transitions

    func testFirstValidCodexEventFlipsStatusFromTrustRequiredToActive() async {
        let codexEvent = event(provider: .codex, capturedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let codex = SpyIntegration(provider: .codex, result: .success(codexEvent))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [codex],
            speechCoordinator: FakeSpeechCoordinator(),
            initialStatus: [.codex: .installedTrustRequired]
        )
        manager.start()
        defer { manager.stop() }

        XCTAssertEqual(manager.status[.codex], .installedTrustRequired)

        continuation.yield(envelope(provider: .codex))

        await waitUntil { manager.status[.codex] == .active(lastEventAt: codexEvent.capturedAt) }

        XCTAssertEqual(manager.status[.codex], .active(lastEventAt: codexEvent.capturedAt))
    }

    func testFirstValidClaudeEventFlipsStatusToActive() async {
        let claudeEvent = event(provider: .claudeCode, capturedAt: Date(timeIntervalSince1970: 1_700_000_600))
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            initialStatus: [.claudeCode: .installedAwaitingFirstEvent]
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        await waitUntil { manager.status[.claudeCode] == .active(lastEventAt: claudeEvent.capturedAt) }

        XCTAssertEqual(manager.status[.claudeCode], .active(lastEventAt: claudeEvent.capturedAt))
    }

    // MARK: - Malformed events

    func testMalformedEnvelopeLeavesLatestAndStatusUnchanged() async {
        let claude = SpyIntegration(provider: .claudeCode, result: .failure(TestError.malformed))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            initialStatus: [.claudeCode: .installedAwaitingFirstEvent]
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode, rawPayload: "not json"))

        // Bounded settle: give the (rejected) event a chance to be processed before asserting
        // nothing changed.
        await waitUntil(timeout: 0.3) { claude.decodeCount >= 1 }

        XCTAssertEqual(claude.decodeCount, 1)
        XCTAssertNil(manager.latestResponse)
        XCTAssertEqual(manager.status[.claudeCode], .installedAwaitingFirstEvent)
    }

    func testEnvelopeWithNoRegisteredAdapterLeavesLatestAndStatusUnchanged() async {
        let codex = SpyIntegration(provider: .codex, result: .failure(TestError.shouldNotBeCalled))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [codex],
            speechCoordinator: FakeSpeechCoordinator()
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        // No Claude adapter registered, so nothing can ever mark this handled; give it a bounded
        // window and confirm state never moved.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(manager.latestResponse)
        XCTAssertEqual(codex.decodeCount, 0)
        XCTAssertNil(manager.status[.claudeCode])
    }

    // MARK: - Replacement

    func testSecondEventReplacesLatestInMemoryOnly() async {
        let firstEvent = event(provider: .claudeCode, providerSessionID: "first")
        let secondEvent = event(provider: .codex, providerSessionID: "second")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(firstEvent))
        let codex = SpyIntegration(provider: .codex, result: .success(secondEvent))
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let store = LatestAgentResponseStore()
        let manager = IntegrationManager(
            events: events,
            integrations: [claude, codex],
            store: store,
            speechCoordinator: FakeSpeechCoordinator()
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))
        await waitUntil { manager.latestResponse == firstEvent }

        continuation.yield(envelope(provider: .codex))
        await waitUntil { manager.latestResponse == secondEvent }

        XCTAssertEqual(manager.latestResponse, secondEvent)
        let stored = await store.get()
        XCTAssertEqual(stored, secondEvent)
    }

    // MARK: - Single source of truth (gate cannot diverge from content)

    /// Hardens the actual bug: the gate (`latestResponse`) and the spoken content (`store.get()`)
    /// must trace back to the SAME state, so anything that mutates `store` — not only the
    /// manager's own consume loop — has to be reflected in the gate too. Before the fix,
    /// `latestResponse` was written only from inside `recordActive()`, so a direct `store.set`
    /// left the gate stale and `waitUntil` below would time out. After the fix, `latestResponse`
    /// is a projection of `store` itself.
    func testGateCannotDivergeFromStoreAcrossDirectMutation() async {
        let store = LatestAgentResponseStore()
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(
            events: events,
            integrations: [],
            store: store,
            speechCoordinator: FakeSpeechCoordinator()
        )
        manager.start()
        defer { manager.stop() }

        let latest = event(provider: .claudeCode, providerSessionID: "direct-set")
        await store.set(latest)
        await waitUntil { manager.latestResponse != nil }

        XCTAssertEqual(
            manager.latestResponse, latest,
            "the gate must reflect every store mutation, not just ones routed through the manager's own consume loop"
        )
        let stored = await store.get()
        XCTAssertEqual(stored, latest)
    }

    // MARK: - onResponse callback

    /// Phase 3 moves the auto-read decision out of this manager entirely: it now only publishes
    /// every successfully-decoded event through `onResponse`, and never submits speech on this
    /// path itself. Focus-gated auto-read semantics are covered separately by
    /// `AgentAutoReadCoordinatorTests`.
    func testOnResponseInvokedOnceForAValidClaudeEvent() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-onresponse-1", text: "**Done.** All set.")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        let recorder = ResponseRecorder()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            onResponse: { event in recorder.record(event) }
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        await waitUntil { recorder.events.count == 1 }

        XCTAssertEqual(recorder.events, [claudeEvent])
    }

    func testOnResponseInvokedOnceForAValidCodexEvent() async {
        let codexEvent = event(provider: .codex, providerSessionID: "codex-onresponse-1", text: "Finished the task.")
        let codex = SpyIntegration(provider: .codex, result: .success(codexEvent))
        let recorder = ResponseRecorder()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [codex],
            speechCoordinator: FakeSpeechCoordinator(),
            onResponse: { event in recorder.record(event) }
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .codex))

        await waitUntil { recorder.events.count == 1 }

        XCTAssertEqual(recorder.events, [codexEvent])
    }

    func testOnResponseNotInvokedForMalformedEvent() async {
        let claude = SpyIntegration(provider: .claudeCode, result: .failure(TestError.malformed))
        let recorder = ResponseRecorder()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            onResponse: { event in recorder.record(event) }
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode, rawPayload: "not json"))

        // Bounded settle: give the (rejected) event a chance to be processed before asserting
        // onResponse was never invoked.
        await waitUntil(timeout: 0.3) { claude.decodeCount >= 1 }

        XCTAssertEqual(claude.decodeCount, 1)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// The manager itself must never submit speech on the auto (decoded-event) path, regardless
    /// of whether a caller supplies `onResponse` — that decision now lives entirely outside this
    /// type.
    func testManagerSubmitsNoSpeechOnTheAutoPath() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-onresponse-2")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        let speech = FakeSpeechCoordinator()
        let recorder = ResponseRecorder()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: speech,
            onResponse: { event in recorder.record(event) }
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        await waitUntil { manager.latestResponse != nil }

        XCTAssertEqual(manager.latestResponse, claudeEvent)
        XCTAssertEqual(recorder.events, [claudeEvent])
        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testOnResponseDefaultsToNoOpWhenNotConfigured() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-onresponse-3")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        let speech = FakeSpeechCoordinator()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: speech
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

        await waitUntil { manager.latestResponse != nil }

        XCTAssertTrue(speech.requests.isEmpty)
    }

    // MARK: - speakLatest

    func testSpeakLatestPreprocessesAutomaticStyleThenSubmitsUserRequestedSpeech() async throws {
        let rawText = "**Done.**\n```swift\nlet secret = 1\n```\nAll set."
        let latest = event(provider: .codex, providerSessionID: "codex-session-42", text: rawText)
        let store = LatestAgentResponseStore()
        await store.set(latest)
        let speech = FakeSpeechCoordinator()
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(
            events: events,
            integrations: [],
            store: store,
            speechCoordinator: speech
        )

        let spoke = try await manager.speakLatest()

        XCTAssertTrue(spoke)
        let expectedText = RulesSpeechPreprocessor().prepare(text: rawText, mode: .automatic)
        XCTAssertEqual(speech.requests.count, 1)
        let request = try XCTUnwrap(speech.requests.first)
        XCTAssertEqual(request.text, expectedText)
        XCTAssertEqual(request.source, .codex)
        XCTAssertEqual(request.mode, .userRequested)
        XCTAssertEqual(request.sessionID, "codex:codex-session-42")
    }

    func testSpeakLatestWithClaudeEventUsesClaudeSource() async throws {
        let latest = event(provider: .claudeCode, providerSessionID: "claude-session-7", text: "All done.")
        let store = LatestAgentResponseStore()
        await store.set(latest)
        let speech = FakeSpeechCoordinator()
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(
            events: events,
            integrations: [],
            store: store,
            speechCoordinator: speech
        )

        try await manager.speakLatest()

        let request = try XCTUnwrap(speech.requests.first)
        XCTAssertEqual(request.source, .claudeCode)
        XCTAssertEqual(request.mode, .userRequested)
        XCTAssertEqual(request.sessionID, "claude-code:claude-session-7")
    }

    func testSpeakLatestWithNoStoredEventSubmitsNothing() async throws {
        let store = LatestAgentResponseStore()
        let speech = FakeSpeechCoordinator()
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(
            events: events,
            integrations: [],
            store: store,
            speechCoordinator: speech
        )

        let spoke = try await manager.speakLatest()

        XCTAssertFalse(spoke)
        XCTAssertTrue(speech.requests.isEmpty)
    }

    // MARK: - Diagnostics

    func testAcceptedEventRecordsEventAcceptedThenOnResponseReturned() async {
        let claudeEvent = event(provider: .claudeCode, providerSessionID: "claude-diag-1")
        let claude = SpyIntegration(provider: .claudeCode, result: .success(claudeEvent))
        let diagnostics = IntegrationDiagnosticsLog()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            diagnostics: diagnostics
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode))

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

    func testAdapterRejectedPayloadRecordsDroppedDiagnosticsEntry() async {
        let claude = SpyIntegration(provider: .claudeCode, result: .failure(TestError.malformed))
        let diagnostics = IntegrationDiagnosticsLog()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [claude],
            speechCoordinator: FakeSpeechCoordinator(),
            diagnostics: diagnostics
        )
        manager.start()
        defer { manager.stop() }

        continuation.yield(envelope(provider: .claudeCode, rawPayload: "not json"))

        await waitUntil(timeout: 0.5) {
            diagnostics.snapshot().contains { $0.outcome == "dropped" && $0.detail.contains("adapter-rejected") }
        }

        let dropped = diagnostics.snapshot().first { $0.outcome == "dropped" }
        XCTAssertNotNil(dropped)
        XCTAssertEqual(dropped?.stage, "manager")
        XCTAssertTrue(dropped?.detail.contains("adapter-rejected") ?? false)
    }
}

// MARK: - Test doubles

private enum TestError: Error {
    case shouldNotBeCalled
    case malformed
}

/// A `RelayIntegration` test double that records how many times it was asked to decode and
/// returns a fixed result. Thread-safe because the manager's consumption loop calls `decode`
/// off the MainActor.
private final class SpyIntegration: RelayIntegration, @unchecked Sendable {
    let provider: AgentProvider
    private let result: Result<AgentResponseEvent, Error>
    private let lock = NSLock()
    private var _decodeCount = 0

    init(provider: AgentProvider, result: Result<AgentResponseEvent, Error>) {
        self.provider = provider
        self.result = result
    }

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decodeCount
    }

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        lock.lock()
        _decodeCount += 1
        lock.unlock()
        return try result.get()
    }
}

/// Records `onResponse` invocations. Thread-safe because the manager calls `onResponse` after
/// hopping back onto the MainActor from `recordActive`, but the closure type itself is
/// `@Sendable`, so this stays consistent with `SpyIntegration`'s own lock-based approach above.
private final class ResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentResponseEvent] = []

    func record(_ event: AgentResponseEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [AgentResponseEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
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
