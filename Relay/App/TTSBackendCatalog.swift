import Foundation

/// A text-to-speech backend as presented in Settings: its place in the user's preferred order
/// and its current readiness, derived from `AppSettings.ttsBackendOrder` plus a live
/// `BackendAvailability` check (or an in-flight download). Mirrors `STTBackendStatus` exactly -
/// label text and iconography live in the view layer; this type only carries the facts.
struct TTSBackendStatus: Identifiable, Equatable, Sendable {
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

extension AppModel {
    /// Re-derives `ttsBackends` from the current settings order and each registered backend's
    /// live `availability()`. Mirrors `refreshSpeechBackendStatuses()`'s race-safety exactly:
    /// only reads `downloadingTTSBackendIDs`/`ttsBackends` at the very end, right before the
    /// synchronous merge-and-assign, guarded by a generation counter so a superseded refresh
    /// can't clobber a newer one's results.
    func refreshTTSBackendStatuses() async {
        ttsRefreshGeneration += 1
        let generation = ttsRefreshGeneration
        let order = knownTTSBackendOrder()
        var fresh: [TTSBackendStatus] = []

        for id in ttsRegistry.keys.sorted() {
            guard let backend = ttsRegistry[id] else { continue }
            let state = Self.mapTTSAvailability(await backend.availability())
            fresh.append(
                TTSBackendStatus(
                    id: id,
                    displayName: backend.displayName,
                    state: state,
                    isEnabled: order.contains(id),
                    position: order.firstIndex(of: id) ?? Int.max
                )
            )
        }

        guard generation == ttsRefreshGeneration else { return }

        let liveByID = Dictionary(uniqueKeysWithValues: ttsBackends.map { ($0.id, $0) })
        ttsBackends = fresh.map { candidate in
            guard let live = liveByID[candidate.id] else { return candidate }
            guard downloadingTTSBackendIDs.contains(candidate.id) || Self.isTTSDownloadInFlightOrFailed(live.state) else {
                return candidate
            }
            var merged = candidate
            merged.state = live.state
            return merged
        }
        sortTTSBackendStatuses()
    }

    /// Whether `id` has a registered downloader (only Kokoro, today). The view uses this to
    /// decide whether to show a Download button at all.
    func canDownloadTTSModel(_ id: String) -> Bool {
        ttsModelDownloaders[id] != nil
    }

    /// Enables or disables a backend in `ttsBackendOrder`. Refuses to disable the last enabled
    /// backend so the router always has somewhere to fall back to.
    func setTTSBackendEnabled(_ id: String, _ enabled: Bool) {
        guard ttsRegistry[id] != nil else { return }
        var order = knownTTSBackendOrder()

        if enabled {
            guard !order.contains(id) else { return }
            order.append(id)
        } else {
            guard order.contains(id) else { return }
            guard order.count > 1 else {
                setTTSBackendMessage("At least one TTS backend must stay enabled.")
                return
            }
            order.removeAll { $0 == id }
        }

        applyTTSBackendOrder(order)
    }

    /// Moves a backend one place earlier or later in `ttsBackendOrder`. No-op if the backend
    /// isn't enabled or is already at that end of the order.
    func moveTTSBackend(_ id: String, up: Bool) {
        var order = knownTTSBackendOrder()
        guard let index = order.firstIndex(of: id) else { return }
        let newIndex = up ? index - 1 : index + 1
        guard order.indices.contains(newIndex) else { return }

        order.swapAt(index, newIndex)
        applyTTSBackendOrder(order)
    }

    /// Downloads the model for `id` (currently only Kokoro has one). Ignored if that backend has
    /// no downloader registered or a download for it is already running. `downloadingTTSBackendIDs`
    /// and the row's `.downloading` state are always written together in the same synchronous
    /// step (`beginTTSDownload`/`endTTSDownload`) so the two can never disagree about whether a
    /// download is running.
    func downloadTTSModel(_ id: String) async {
        guard let downloader = ttsModelDownloaders[id] else { return }
        guard !downloadingTTSBackendIDs.contains(id) else { return }

        beginTTSDownload(id)
        setTTSBackendMessage(nil)
        recordDiagnostic(.speechModelDownloadStarted(backendID: id))

        do {
            try await downloader.downloadModels(progress: { [weak self] progress in
                Task { @MainActor in
                    self?.applyTTSDownloadProgress(id: id, progress: progress)
                }
            })
            recordDiagnostic(.speechModelDownloadFinished(backendID: id))
            let availability = await ttsRegistry[id]?.availability()
            let finalState = availability.map(Self.mapTTSAvailability) ?? .unavailable
            endTTSDownload(id, finalState: finalState)
        } catch {
            recordDiagnostic(.speechModelDownloadFailed(backendID: id))
            endTTSDownload(id, finalState: .downloadFailed)
            let displayName = ttsRegistry[id]?.displayName ?? id
            let message = "\(displayName) model download failed. Check your connection and try again."
            setTTSBackendMessage(message)
        }
    }

    /// Applies one progress tick from an in-flight download. Ignored if the download already
    /// finished (or was never the one running) and ignored if it's an out-of-order tick reporting
    /// less progress than what's already shown, so a late or reordered callback can never move
    /// the UI backwards or resurrect a finished download.
    private func applyTTSDownloadProgress(id: String, progress: Double) {
        guard downloadingTTSBackendIDs.contains(id) else { return }
        guard case let .downloading(current)? = ttsBackends.first(where: { $0.id == id })?.state,
              progress >= current
        else { return }
        setOrInsertTTSBackendState(id, .downloading(progress: progress))
    }

    /// Marks `id` as downloading. Always pairs the single-flight guard with the visible state in
    /// one synchronous step.
    private func beginTTSDownload(_ id: String) {
        downloadingTTSBackendIDs.insert(id)
        setOrInsertTTSBackendState(id, .downloading(progress: 0))
    }

    /// Clears the single-flight guard for `id` and writes its resulting state in the same
    /// synchronous step, so the guard and the visible state never disagree.
    private func endTTSDownload(_ id: String, finalState: TTSBackendStatus.State) {
        downloadingTTSBackendIDs.remove(id)
        setOrInsertTTSBackendState(id, finalState)
    }

    private func setTTSBackendMessage(_ message: String?) {
        ttsBackendMessage = message
        if let message {
            statusText = message
        }
    }

    private func applyTTSBackendOrder(_ order: [String]) {
        setTTSBackendOrder(order)
        ttsBackends = ttsBackends.map { status in
            var updated = status
            updated.isEnabled = order.contains(status.id)
            updated.position = order.firstIndex(of: status.id) ?? Int.max
            return updated
        }
        sortTTSBackendStatuses()
        setTTSBackendMessage(nil)
    }

    /// `ttsBackendOrder` filtered to ids this run actually has a backend for, so a stale or
    /// unknown id left over in settings never counts toward the last-enabled guard, positions, or
    /// what gets persisted the next time the order changes.
    private func knownTTSBackendOrder() -> [String] {
        settings.ttsBackendOrder.filter { ttsRegistry[$0] != nil }
    }

    /// Updates the state for `id`, inserting a new row built from the registry if one doesn't
    /// exist yet — e.g. a Download click that lands before the first `refreshTTSBackendStatuses()`
    /// has populated `ttsBackends`.
    private func setOrInsertTTSBackendState(_ id: String, _ state: TTSBackendStatus.State) {
        if let index = ttsBackends.firstIndex(where: { $0.id == id }) {
            ttsBackends[index].state = state
            return
        }
        guard let backend = ttsRegistry[id] else { return }
        let order = knownTTSBackendOrder()
        ttsBackends.append(
            TTSBackendStatus(
                id: id,
                displayName: backend.displayName,
                state: state,
                isEnabled: order.contains(id),
                position: order.firstIndex(of: id) ?? Int.max
            )
        )
        sortTTSBackendStatuses()
    }

    private func sortTTSBackendStatuses() {
        ttsBackends.sort { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }

    private static func isTTSDownloadInFlightOrFailed(_ state: TTSBackendStatus.State) -> Bool {
        switch state {
        case .downloading, .downloadFailed: true
        case .ready, .modelNotDownloaded, .unsupported, .unavailable: false
        }
    }

    private static func mapTTSAvailability(_ availability: BackendAvailability) -> TTSBackendStatus.State {
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
