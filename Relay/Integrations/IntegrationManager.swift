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
/// wired up by the UI. Separately, when `shouldAutoRead` returns `true`, every successfully
/// decoded event also drives an `.automatic` speech request on its own, per the interim, global
/// `AppSettings.autoReadEnabled` flag (Phase 3 will scope this to the focused session).
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
    /// Read only from `recordActive` (MainActor), so — like `speechCoordinator` above and
    /// `TTSRouter`'s `backendOrder` closure — this deliberately is NOT `nonisolated`/`@Sendable`:
    /// that lets it safely capture MainActor-confined, non-`Sendable` state (e.g. `AppModel`'s
    /// settings box) the same way `AppModel`'s existing closures already do.
    @ObservationIgnored private let shouldAutoRead: () -> Bool
    @ObservationIgnored nonisolated private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    init(
        events: AsyncStream<HookEnvelope>,
        integrations: [any RelayIntegration],
        store: LatestAgentResponseStore = LatestAgentResponseStore(),
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: any SpeechCoordinating,
        initialStatus: [AgentProvider: IntegrationStatus] = [:],
        shouldAutoRead: @escaping () -> Bool = { false }
    ) {
        self.events = events
        self.integrations = Dictionary(uniqueKeysWithValues: integrations.map { ($0.provider, $0) })
        self.store = store
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.status = initialStatus
        self.shouldAutoRead = shouldAutoRead
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

    /// Updates `latestResponse`/`status` for a successfully decoded `event`, then, when
    /// `shouldAutoRead` says so, submits it for speech automatically. Auto-read errors are
    /// swallowed like every other step in this pipeline: a speech failure must never crash the
    /// app or interrupt event bookkeeping.
    private func recordActive(_ event: AgentResponseEvent) async {
        latestResponse = event
        status[event.provider] = .active(lastEventAt: event.capturedAt)

        guard shouldAutoRead() else { return }

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
            mode: .automatic,
            sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"
        )
        try? await speechCoordinator.speak(request)
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
