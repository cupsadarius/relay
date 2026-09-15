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
/// Phase 2 never auto-speaks: `speakLatest()` exists only for an explicit, user-initiated
/// action wired up by the UI in a later task. Nothing in this type calls it on its own.
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
    @ObservationIgnored nonisolated private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    init(
        events: AsyncStream<HookEnvelope>,
        integrations: [any RelayIntegration],
        store: LatestAgentResponseStore = LatestAgentResponseStore(),
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: any SpeechCoordinating,
        initialStatus: [AgentProvider: IntegrationStatus] = [:]
    ) {
        self.events = events
        self.integrations = Dictionary(uniqueKeysWithValues: integrations.map { ($0.provider, $0) })
        self.store = store
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.status = initialStatus
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
                continue
            }

            let event: AgentResponseEvent
            do {
                event = try integration.decode(envelope)
            } catch {
                logger.log("hook envelope dropped: adapter rejected payload")
                continue
            }

            await store.set(event)
            await recordActive(event)
        }
    }

    private func recordActive(_ event: AgentResponseEvent) {
        latestResponse = event
        status[event.provider] = .active(lastEventAt: event.capturedAt)
    }

    /// Clears any runtime status recorded for `provider`, removing its entry from `status`
    /// entirely rather than pinning it to some other value. Called by `AppModel` right after a
    /// successful uninstall, so a stale `.active` entry from earlier this session can't keep
    /// winning `AppModel.integrationStatus(for:)`'s merge once the provider's installer state is
    /// reloaded as not-installed.
    func clearRuntimeStatus(for provider: AgentProvider) {
        status[provider] = nil
    }

    /// Reads the ephemeral latest response (if any) and submits it for speech as a
    /// user-requested request. Never invoked automatically.
    func speakLatest() async throws {
        guard let event = await store.get() else { return }

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
}
