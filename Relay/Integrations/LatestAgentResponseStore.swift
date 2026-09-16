import Foundation

/// Holds the single most recent normalized agent response in memory only.
///
/// This store is intentionally ephemeral: it never touches `UserDefaults`, a file, a database,
/// or any transcript path. Its contents live only for the lifetime of the process and are lost
/// on quit, matching the Phase 2 constraint that agent response text is never written to Relay
/// history.
///
/// This is the ONE authoritative owner of "the latest agent response". Both the availability
/// gate (`IntegrationManager.latestResponse`, read by `AppModel`'s replay-last tiering) and the
/// spoken content (`IntegrationManager.speakLatest()`, via `get()`) must trace back to this same
/// state, or the two can silently diverge — see `subscribe(_:)`, which is how the gate stays a
/// pure, single-writer projection of whatever is stored here.
actor LatestAgentResponseStore {
    private var latest: AgentResponseEvent?
    private var subscriber: (@MainActor @Sendable (AgentResponseEvent?) -> Void)?

    /// Replaces the stored event, discarding whatever was there before, then runs the subscriber
    /// registered via `subscribe(_:)` (if any) with the new value before returning — so by the
    /// time a caller's `await` on this method completes, any projection of this store (like
    /// `IntegrationManager.latestResponse`) has already caught up. No stale-read window.
    func set(_ event: AgentResponseEvent) async {
        latest = event
        await subscriber?(latest)
    }

    /// Returns the most recently stored event, or `nil` if none has arrived yet (or it has been
    /// cleared).
    func get() -> AgentResponseEvent? {
        latest
    }

    /// Discards the stored event, if any, then runs the subscriber exactly as `set(_:)` does.
    func clear() async {
        latest = nil
        await subscriber?(latest)
    }

    /// Registers `callback` to run on the `MainActor`, as part of every subsequent `set`/`clear`
    /// call — from ANY caller, not just whoever happens to be driving the primary hook-event
    /// pipeline — delivering this store's current value immediately upon registration.
    ///
    /// `IntegrationManager` is this store's one long-lived subscriber, and it is the ONLY place
    /// that writes its `latestResponse` gate — always from here, never independently — so that
    /// property can never fall out of sync with what `get()` returns, no matter what mutates this
    /// store. Registering again replaces the previous subscription; this store supports exactly
    /// one at a time.
    func subscribe(_ callback: @escaping @MainActor @Sendable (AgentResponseEvent?) -> Void) async {
        subscriber = callback
        await callback(latest)
    }
}
