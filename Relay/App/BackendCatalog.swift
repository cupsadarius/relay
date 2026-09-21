import Foundation

/// A speech backend as presented in Settings: its place in the user's preferred order and its
/// current readiness, derived from the relevant `AppSettings` order plus a live
/// `BackendAvailability` check (or an in-flight download). One shape shared by STT and TTS —
/// `STTBackendStatus`/`TTSBackendStatus` are aliases of this type, kept as distinct names only so
/// call sites and tests don't need to change. Label text and iconography live in the view layer;
/// this type only carries the facts.
struct BackendStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case modelNotDownloaded
        case downloading(progress: Double)
        case downloadFailed
        case unsupported
        case unavailable
    }

    let id: String
    let displayName: String
    var state: State
    var isEnabled: Bool
    var position: Int
}

/// The result of attempting to enable or disable a backend: either nothing changes (unknown id,
/// or already in the requested state), the change is refused with a message (disabling the last
/// enabled backend), or it should be applied as a new order.
enum BackendEnableOutcome: Equatable {
    case noop
    case refused(message: String)
    case apply(order: [String])
}

/// The shared algorithm behind `SpeechBackendCatalog.swift` and `TTSBackendCatalog.swift`:
/// generation-counter race-safe merging, sorting, enable/disable, reorder, and download-progress
/// monotonicity. Generic only over `Backend` — the registry's element type (`any
/// SpeechToTextBackend` vs. `any TextToSpeechBackend`) — and only for structural membership
/// checks (`registry[id] != nil`), never for calling a method on a backend: `SpeechToTextBackend`
/// is `Sendable` and callable off the main actor, while `TextToSpeechBackend` is `@MainActor`, so
/// actually invoking `availability()`/`displayName` generically across both would either force a
/// false isolation requirement onto STT or require a data race risking `Sendable` escape hatch on
/// TTS. Each adapter therefore still owns the handful of lines that touch a live backend
/// (`await backend.availability()`, `backend.displayName`) — genuinely backend-specific glue, not
/// duplicated algorithm — while every id/order/state transition (the actual race-safety-bearing
/// logic) lives here exactly once.
///
/// This type is deliberately stateless: `AppModel` keeps owning `sttBackends`/`ttsBackends`,
/// `downloadingBackendIDs`/`downloadingTTSBackendIDs`, and `refreshGeneration`/
/// `ttsRefreshGeneration` as its own stored (and therefore `@Observable`-tracked) properties, and
/// calls into these functions at each mutation point. That keeps the load-bearing invariant — a
/// stale in-flight refresh must never clobber a newer one's results, with the generation-counter
/// increment/compare bracketing the exact same `await` gap it always did — entirely in the
/// adapter's hands, where it's one straight-line function, easy to audit, rather than hidden
/// behind a second layer of async indirection.
@MainActor
enum BackendCatalog<Backend> {
    /// Merges a freshly computed status list with the currently visible one: a backend with an
    /// in-flight (or just-failed) download keeps its live state instead of being reset by the now-
    /// stale fresh snapshot. Does not sort — callers apply `sorted(_:)` afterward.
    static func merged(fresh: [BackendStatus], live: [BackendStatus], downloadingIDs: Set<String>) -> [BackendStatus] {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        return fresh.map { candidate in
            guard let liveStatus = liveByID[candidate.id] else { return candidate }
            guard downloadingIDs.contains(candidate.id) || isDownloadInFlightOrFailed(liveStatus.state) else {
                return candidate
            }
            var merged = candidate
            merged.state = liveStatus.state
            return merged
        }
    }

    /// Enabled backends first (in their configured order), then disabled backends alphabetically
    /// by id.
    static func sorted(_ statuses: [BackendStatus]) -> [BackendStatus] {
        statuses.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }

    /// `order` filtered to ids `registry` actually has a backend for, so a stale or unknown id
    /// left over in settings never counts toward the last-enabled guard, positions, or what gets
    /// persisted the next time the order changes.
    static func knownOrder(_ order: [String], registry: [String: Backend]) -> [String] {
        order.filter { registry[$0] != nil }
    }

    /// Computes the outcome of enabling/disabling `id` in `order`. Refuses to disable the last
    /// enabled backend so the router always has somewhere to fall back to; unknown ids and
    /// already-in-the-requested-state ids are a no-op.
    static func settingEnabled(
        _ enabled: Bool,
        id: String,
        order: [String],
        registry: [String: Backend],
        refusalMessage: String
    ) -> BackendEnableOutcome {
        guard registry[id] != nil else { return .noop }
        var order = order

        if enabled {
            guard !order.contains(id) else { return .noop }
            order.append(id)
        } else {
            guard order.contains(id) else { return .noop }
            guard order.count > 1 else { return .refused(message: refusalMessage) }
            order.removeAll { $0 == id }
        }

        return .apply(order: order)
    }

    /// Moves `id` one place earlier or later in `order`. `nil` if `id` isn't in `order` or is
    /// already at that end of it.
    static func moved(_ order: [String], id: String, up: Bool) -> [String]? {
        var order = order
        guard let index = order.firstIndex(of: id) else { return nil }
        let newIndex = up ? index - 1 : index + 1
        guard order.indices.contains(newIndex) else { return nil }
        order.swapAt(index, newIndex)
        return order
    }

    /// Re-derives `isEnabled`/`position` for every existing row from a newly applied `order`, then
    /// sorts.
    static func applyingOrder(_ order: [String], to statuses: [BackendStatus]) -> [BackendStatus] {
        let updated = statuses.map { status -> BackendStatus in
            var updated = status
            updated.isEnabled = order.contains(status.id)
            updated.position = order.firstIndex(of: status.id) ?? Int.max
            return updated
        }
        return sorted(updated)
    }

    /// Updates the state for `id`, inserting a new row if one doesn't exist yet — e.g. a Download
    /// click that lands before the first refresh has populated `statuses`. `displayName` is only
    /// evaluated for that insert path (a Download click always targets an id the caller's registry
    /// actually has, but if it doesn't, no row is inserted). Sorts only when inserting; an
    /// in-place state update preserves the existing row's position.
    static func insertingOrUpdating(
        _ statuses: [BackendStatus],
        id: String,
        state: BackendStatus.State,
        displayName: @autoclosure () -> String?,
        order: [String]
    ) -> [BackendStatus] {
        if let index = statuses.firstIndex(where: { $0.id == id }) {
            var updated = statuses
            updated[index].state = state
            return updated
        }
        guard let displayName = displayName() else { return statuses }
        var updated = statuses
        updated.append(
            BackendStatus(
                id: id,
                displayName: displayName,
                state: state,
                isEnabled: order.contains(id),
                position: order.firstIndex(of: id) ?? Int.max
            )
        )
        return sorted(updated)
    }

    /// Whether a progress tick for `id` should be applied: ignored if the download already
    /// finished (or was never the one running) and ignored if it's an out-of-order tick reporting
    /// less progress than what's already shown, so a late or reordered callback can never move the
    /// UI backwards or resurrect a finished download.
    static func shouldApplyProgress(
        _ statuses: [BackendStatus],
        id: String,
        progress: Double,
        downloadingIDs: Set<String>
    ) -> Bool {
        guard downloadingIDs.contains(id) else { return false }
        guard case let .downloading(current)? = statuses.first(where: { $0.id == id })?.state,
              progress >= current
        else { return false }
        return true
    }

    static func isDownloadInFlightOrFailed(_ state: BackendStatus.State) -> Bool {
        switch state {
        case .downloading, .downloadFailed: true
        case .ready, .modelNotDownloaded, .unsupported, .unavailable: false
        }
    }

    static func mapAvailability(_ availability: BackendAvailability) -> BackendStatus.State {
        switch availability {
        case .available:
            .ready
        case .modelNotDownloaded:
            .modelNotDownloaded
        case .unsupportedOS, .unsupportedHardware:
            .unsupported
        case .permissionDenied, .unavailable, .initializing, .failed:
            .unavailable
        }
    }
}
