import Foundation
import Observation
import os

/// Consumes envelopes from a hook receiver's `events` stream, parses each into a `HookMessage`,
/// keeps the latest response in memory only, and reflects per-provider runtime status for the UI.
///
/// Parsing runs off the MainActor, so a burst of hook traffic never blocks the UI. This manager
/// never speaks on its own: each response goes to `onResponse`, and `speakLatest()` runs only on
/// an explicit user action.
@MainActor
@Observable
final class IntegrationManager {
    private(set) var status: [AgentProvider: IntegrationStatus]
    /// Never persisted: agent response text is never written to disk.
    private(set) var latestResponse: AgentResponseEvent?

    @ObservationIgnored nonisolated private let events: AsyncStream<HookEnvelope>
    @ObservationIgnored nonisolated private let preprocessor: RulesSpeechPreprocessor
    @ObservationIgnored private let speechCoordinator: any SpeechCoordinating
    /// Runs once per response, after `status` and `latestResponse` are updated.
    @ObservationIgnored private let onResponse: @Sendable (AgentResponseEvent) async -> Void
    /// Runs for each `UserPromptSubmit` envelope with the session the user just prompted.
    @ObservationIgnored nonisolated private let onPrompt: @Sendable (AgentSessionID) async -> Void
    @ObservationIgnored nonisolated private let logger = Logger.relay("integrations")
    @ObservationIgnored nonisolated private let diagnostics: IntegrationDiagnosticsLog
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    init(
        events: AsyncStream<HookEnvelope>,
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: any SpeechCoordinating,
        initialStatus: [AgentProvider: IntegrationStatus] = [:],
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        onResponse: @escaping @Sendable (AgentResponseEvent) async -> Void = { _ in },
        onPrompt: @escaping @Sendable (AgentSessionID) async -> Void = { _ in }
    ) {
        self.events = events
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.status = initialStatus
        self.diagnostics = diagnostics
        self.onResponse = onResponse
        self.onPrompt = onPrompt
    }

    /// Starts consuming `events` on a background task. Calling this more than once while
    /// already running is a no-op.
    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task { await self.consume() }
    }

    /// Stops consuming further events. Does not close `events` itself; that stream is owned by
    /// whoever constructed this manager (typically `HookEnvelopeReceiver`).
    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Runs off the MainActor for as long as `events` has elements. Only structural facts are
    /// ever logged here: never `event.text`, cwd, transcript path, session or turn IDs, or
    /// environment.
    nonisolated private func consume() async {
        for await envelope in events {
            let message: HookMessage
            do {
                message = try HookMessage.parse(envelope)
            } catch {
                logger.log("hook envelope dropped: payload rejected")
                diagnostics.append(
                    stage: "manager",
                    outcome: "dropped",
                    detail: "adapter-rejected provider=\(envelope.provider.rawValue)"
                )
                continue
            }

            switch message {
            case let .prompt(sessionID):
                diagnostics.append(stage: "manager", outcome: "prompt", detail: "provider=\(envelope.provider.rawValue)")
                await onPrompt(sessionID)
            case let .response(event):
                diagnostics.append(stage: "manager", outcome: "event-accepted", detail: "provider=\(envelope.provider.rawValue)")
                await recordActive(event)
            }
        }
    }

    private func recordActive(_ event: AgentResponseEvent) async {
        latestResponse = event
        status[event.provider] = .active(lastEventAt: event.capturedAt)

        await onResponse(event)
        diagnostics.append(stage: "manager", outcome: "onResponse-returned", detail: "provider=\(event.provider.rawValue)")
    }

    /// Called after an uninstall, so a stale `.active` cannot outlive it.
    func clearRuntimeStatus(for provider: AgentProvider) {
        status[provider] = nil
    }

    /// Preprocesses `event` and speaks it as a user-requested request. Shared by `speakLatest()`
    /// and the focused-session replay, so both build the request the same way.
    func speakResponse(_ event: AgentResponseEvent, tracer: PipelineTracer? = nil) async throws {
        let prepared = preprocessor.prepare(text: event.text)
        try await speechCoordinator.speak(event.speechRequest(text: prepared, mode: .userRequested, tracer: tracer))
    }

    /// Speaks the latest response as a user-requested request. Returns `false` when there is
    /// nothing to speak, so a caller can fall back.
    @discardableResult
    func speakLatest(tracer: PipelineTracer? = nil) async throws -> Bool {
        guard let event = latestResponse else { return false }
        try await speakResponse(event, tracer: tracer)
        return true
    }
}
