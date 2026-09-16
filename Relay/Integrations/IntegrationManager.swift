import Foundation
import Observation
import os

/// Consumes decoded `HookEnvelope`s from a hook receiver's `events` stream, dispatches each to
/// the matching `RelayIntegration` adapter, keeps the ephemeral latest response in memory, and
/// reflects per-provider runtime status on the MainActor for UI observation.
///
/// The event-consumption loop itself never runs on the MainActor: decoding and storing happen
/// off it, and only the resulting `status`/`latestResponse` bookkeeping hops there. This keeps a
/// burst of hook traffic from ever blocking the UI.
///
/// `speakLatest()` remains an explicit, user-initiated action (submitted as `.userRequested`)
/// wired up by the UI. This manager never submits speech automatically on its own: every
/// successfully decoded event is instead published through `onResponse`, so a caller (Phase 3's
/// `AgentAutoReadCoordinator`) can apply focus-gated auto-read semantics.
///
/// Runtime status tracked here is independent of the installers' install-time status (set by
/// `ClaudeCodeInstaller`/`CodexInstaller`); this type never calls into either installer.
@MainActor
@Observable
final class IntegrationManager {
    private(set) var status: [AgentProvider: IntegrationStatus]
    private(set) var latestResponse: AgentResponseEvent?

    @ObservationIgnored nonisolated private let events: AsyncStream<HookEnvelope>
    @ObservationIgnored nonisolated private let integrations: [AgentProvider: any RelayIntegration]
    @ObservationIgnored nonisolated private let store: LatestAgentResponseStore
    @ObservationIgnored nonisolated private let preprocessor: RulesSpeechPreprocessor
    @ObservationIgnored private let speechCoordinator: any SpeechCoordinating
    /// Invoked once per successfully-decoded event, after `latestResponse`/`status` have been
    /// updated. Lets a caller (Phase 3's `AgentAutoReadCoordinator`) apply focus-gated auto-read
    /// semantics without this manager knowing anything about focus or sessions itself.
    @ObservationIgnored private let onResponse: @Sendable (AgentResponseEvent) async -> Void
    @ObservationIgnored nonisolated private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")
    @ObservationIgnored nonisolated private let diagnostics: IntegrationDiagnosticsLog
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    init(
        events: AsyncStream<HookEnvelope>,
        integrations: [any RelayIntegration],
        store: LatestAgentResponseStore = LatestAgentResponseStore(),
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: any SpeechCoordinating,
        initialStatus: [AgentProvider: IntegrationStatus] = [:],
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        onResponse: @escaping @Sendable (AgentResponseEvent) async -> Void = { _ in }
    ) {
        self.events = events
        self.integrations = Dictionary(uniqueKeysWithValues: integrations.map { ($0.provider, $0) })
        self.store = store
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.status = initialStatus
        self.diagnostics = diagnostics
        self.onResponse = onResponse
    }

    /// Starts consuming `events` on a background task. Calling this more than once while
    /// already running is a no-op.
    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task {
            await self.consume()
        }
    }

    /// Stops consuming further events. Does not close `events` itself; that stream is owned by
    /// whoever constructed this manager (typically `HookEnvelopeReceiver`).
    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Runs off the MainActor for as long as `events` has elements. Only structural facts are
    /// ever logged here: never `event.text`, cwd, transcript path, providerSessionID, turn ID,
    /// or environment.
    nonisolated private func consume() async {
        for await envelope in events {
            guard let integration = integrations[envelope.provider] else {
                logger.log("hook envelope dropped: no integration registered for this provider")
                diagnostics.append(
                    stage: "manager",
                    outcome: "dropped",
                    detail: "no-integration provider=\(envelope.provider.rawValue)"
                )
                continue
            }

            let event: AgentResponseEvent
            do {
                event = try integration.decode(envelope)
            } catch {
                logger.log("hook envelope dropped: adapter rejected payload")
                diagnostics.append(
                    stage: "manager",
                    outcome: "dropped",
                    detail: "adapter-rejected provider=\(envelope.provider.rawValue)"
                )
                continue
            }

            diagnostics.append(stage: "manager", outcome: "event-accepted", detail: "provider=\(envelope.provider.rawValue)")

            await store.set(event)
            await recordActive(event)
        }
    }

    /// Updates `latestResponse`/`status` for a successfully decoded `event`, then publishes it
    /// through `onResponse`. This manager never submits speech on this path itself.
    private func recordActive(_ event: AgentResponseEvent) async {
        latestResponse = event
        status[event.provider] = .active(lastEventAt: event.capturedAt)

        await onResponse(event)
        diagnostics.append(stage: "manager", outcome: "onResponse-returned", detail: "provider=\(event.provider.rawValue)")
    }

    /// Clears any runtime status recorded for `provider`, removing its entry from `status`
    /// entirely rather than pinning it to some other value. Called by `AppModel` right after a
    /// successful uninstall, so a stale `.active` entry from earlier this session can't keep
    /// winning `AppModel.integrationStatus(for:)`'s merge once the provider's installer state is
    /// reloaded as not-installed.
    func clearRuntimeStatus(for provider: AgentProvider) {
        status[provider] = nil
    }

    /// Builds a `.userRequested` speech request for `event` (preprocessed the same way as any
    /// other agent response) and submits it. Shared by `speakLatest()` and by
    /// `AppModel.replayLast()`'s focused-session tier, so both paths build the request
    /// identically. Never invoked automatically; only ever reached from an explicit user action.
    func speakResponse(_ event: AgentResponseEvent) async throws {
        let prepared = preprocessor.prepare(text: event.text, mode: .automatic)
        let source: SpeechSource
        switch event.provider {
        case .claudeCode:
            source = .claudeCode
        case .codex:
            source = .codex
        }

        let request = SpeechRequest(
            text: prepared,
            source: source,
            mode: .userRequested,
            sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"
        )
        try await speechCoordinator.speak(request)
    }

    /// Reads the ephemeral latest response (if any) and submits it for speech as a
    /// user-requested request. Never invoked automatically.
    func speakLatest() async throws {
        guard let event = await store.get() else { return }
        try await speakResponse(event)
    }
}
