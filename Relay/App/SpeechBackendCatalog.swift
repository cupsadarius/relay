import Foundation

/// A speech-to-text backend as presented in Settings: its place in the user's preferred order
/// and its current readiness, derived from `AppSettings.sttBackendOrder` plus a live
/// `BackendAvailability` check (or an in-flight download). Label text and iconography live in
/// the view layer; this type only carries the facts.
struct STTBackendStatus: Identifiable, Equatable, Sendable {
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

/// The seam `AppModel` uses to trigger an explicit, on-device model download for a speech
/// backend (Parakeet today) without depending on the concrete backend type. Kept separate from
/// `SpeechToTextBackend`/`STTRouter` so the router never has to know about downloading at all.
protocol SpeechModelDownloading: Sendable {
    /// Downloads the backend's model. `progress` is called with a fraction in [0, 1] while the
    /// download is in flight; it may be called from any queue, in any order, including after
    /// the call has already completed — callers must tolerate stale or out-of-order ticks.
    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension ParakeetBackend: SpeechModelDownloading {}

extension AppModel {
    /// Re-derives `sttBackends` from the current settings order and each registered backend's
    /// live `availability()`. Because `availability()` is awaited per backend, another task
    /// (most notably a Download click) can run in between; to stay race-safe this method only
    /// reads `downloadingBackendIDs`/`sttBackends` at the very end, right before the synchronous
    /// merge-and-assign, never before or during the awaits. A backend with an in-flight (or just
    /// failed) download keeps its live state instead of being reset by a now-stale snapshot. A
    /// generation counter also ensures a refresh that was superseded by a later one can't apply
    /// its (older) results after the newer one has already won.
    func refreshSpeechBackendStatuses() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let order = knownSTTBackendOrder()
        var fresh: [STTBackendStatus] = []

        for id in sttRegistry.keys.sorted() {
            guard let backend = sttRegistry[id] else { continue }
            let state = Self.mapAvailability(await backend.availability())
            fresh.append(
                STTBackendStatus(
                    id: id,
                    displayName: backend.displayName,
                    state: state,
                    isEnabled: order.contains(id),
                    position: order.firstIndex(of: id) ?? Int.max
                )
            )
        }

        // A newer refresh (one that started after this one) has already applied its results;
        // this one is stale and must not overwrite them.
        guard generation == refreshGeneration else { return }

        let liveByID = Dictionary(uniqueKeysWithValues: sttBackends.map { ($0.id, $0) })
        sttBackends = fresh.map { candidate in
            guard let live = liveByID[candidate.id] else { return candidate }
            guard downloadingBackendIDs.contains(candidate.id) || Self.isDownloadInFlightOrFailed(live.state) else {
                return candidate
            }
            var merged = candidate
            merged.state = live.state
            return merged
        }
        sortSpeechBackendStatuses()
    }

    /// Whether `id` has a registered downloader (only Parakeet, today). The view uses this to
    /// decide whether to show a Download button at all.
    func canDownloadSpeechModel(_ id: String) -> Bool {
        speechModelDownloaders[id] != nil
    }

    /// Enables or disables a backend in `sttBackendOrder`. Refuses to disable the last enabled
    /// backend so the router always has somewhere to fall back to.
    func setSTTBackendEnabled(_ id: String, _ enabled: Bool) {
        guard sttRegistry[id] != nil else { return }
        var order = knownSTTBackendOrder()

        if enabled {
            guard !order.contains(id) else { return }
            order.append(id)
        } else {
            guard order.contains(id) else { return }
            guard order.count > 1 else {
                setSpeechBackendMessage("At least one speech recognition backend must stay enabled.")
                return
            }
            order.removeAll { $0 == id }
        }

        applySpeechBackendOrder(order)
    }

    /// Moves a backend one place earlier or later in `sttBackendOrder`. No-op if the backend
    /// isn't enabled or is already at that end of the order.
    func moveSTTBackend(_ id: String, up: Bool) {
        var order = knownSTTBackendOrder()
        guard let index = order.firstIndex(of: id) else { return }
        let newIndex = up ? index - 1 : index + 1
        guard order.indices.contains(newIndex) else { return }

        order.swapAt(index, newIndex)
        applySpeechBackendOrder(order)
    }

    /// Downloads the model for `id` (currently only Parakeet has one). Ignored if that backend
    /// has no downloader registered or a download for it is already running. `downloadingBackendIDs`
    /// and the row's `.downloading` state are always written together in the same synchronous
    /// step (`beginDownload`/`endDownload`) so the two can never disagree about whether a
    /// download is running.
    func downloadSpeechModel(_ id: String) async {
        guard let downloader = speechModelDownloaders[id] else { return }
        guard !downloadingBackendIDs.contains(id) else { return }

        beginDownload(id)
        setSpeechBackendMessage(nil)
        recordDiagnostic(.speechModelDownloadStarted(backendID: id))

        do {
            try await downloader.downloadModels(progress: { [weak self] progress in
                Task { @MainActor in
                    self?.applyDownloadProgress(id: id, progress: progress)
                }
            })
            recordDiagnostic(.speechModelDownloadFinished(backendID: id))
            let availability = await sttRegistry[id]?.availability()
            let finalState = availability.map(Self.mapAvailability) ?? .unavailable
            endDownload(id, finalState: finalState)
        } catch {
            recordDiagnostic(.speechModelDownloadFailed(backendID: id))
            endDownload(id, finalState: .downloadFailed)
            let displayName = sttRegistry[id]?.displayName ?? id
            let message = "\(displayName) model download failed. Check your connection and try again."
            setSpeechBackendMessage(message)
        }
    }

    /// Applies one progress tick from an in-flight download. Ignored if the download already
    /// finished (or was never the one running) and ignored if it's an out-of-order tick reporting
    /// less progress than what's already shown, so a late or reordered callback can never move
    /// the UI backwards or resurrect a finished download.
    private func applyDownloadProgress(id: String, progress: Double) {
        guard downloadingBackendIDs.contains(id) else { return }
        guard case let .downloading(current)? = sttBackends.first(where: { $0.id == id })?.state,
              progress >= current
        else { return }
        setOrInsertSpeechBackendState(id, .downloading(progress: progress))
    }

    /// Marks `id` as downloading. Always pairs the single-flight guard with the visible state in
    /// one synchronous step.
    private func beginDownload(_ id: String) {
        downloadingBackendIDs.insert(id)
        setOrInsertSpeechBackendState(id, .downloading(progress: 0))
    }

    /// Clears the single-flight guard for `id` and writes its resulting state in the same
    /// synchronous step, so the guard and the visible state never disagree.
    private func endDownload(_ id: String, finalState: STTBackendStatus.State) {
        downloadingBackendIDs.remove(id)
        setOrInsertSpeechBackendState(id, finalState)
    }

    private func setSpeechBackendMessage(_ message: String?) {
        speechBackendMessage = message
        if let message {
            statusText = message
        }
    }

    private func applySpeechBackendOrder(_ order: [String]) {
        setSTTBackendOrder(order)
        sttBackends = sttBackends.map { status in
            var updated = status
            updated.isEnabled = order.contains(status.id)
            updated.position = order.firstIndex(of: status.id) ?? Int.max
            return updated
        }
        sortSpeechBackendStatuses()
        setSpeechBackendMessage(nil)
    }

    /// `sttBackendOrder` filtered to ids this run actually has a backend for, so a stale or
    /// unknown id left over in settings never counts toward the last-enabled guard, positions, or
    /// what gets persisted the next time the order changes.
    private func knownSTTBackendOrder() -> [String] {
        settings.sttBackendOrder.filter { sttRegistry[$0] != nil }
    }

    /// Updates the state for `id`, inserting a new row built from the registry if one doesn't
    /// exist yet — e.g. a Download click that lands before the first `refreshSpeechBackendStatuses()`
    /// has populated `sttBackends`.
    private func setOrInsertSpeechBackendState(_ id: String, _ state: STTBackendStatus.State) {
        if let index = sttBackends.firstIndex(where: { $0.id == id }) {
            sttBackends[index].state = state
            return
        }
        guard let backend = sttRegistry[id] else { return }
        let order = knownSTTBackendOrder()
        sttBackends.append(
            STTBackendStatus(
                id: id,
                displayName: backend.displayName,
                state: state,
                isEnabled: order.contains(id),
                position: order.firstIndex(of: id) ?? Int.max
            )
        )
        sortSpeechBackendStatuses()
    }

    private func sortSpeechBackendStatuses() {
        sttBackends.sort { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }

    private static func isDownloadInFlightOrFailed(_ state: STTBackendStatus.State) -> Bool {
        switch state {
        case .downloading, .downloadFailed: true
        case .ready, .modelNotDownloaded, .unsupported, .unavailable: false
        }
    }

    private static func mapAvailability(_ availability: BackendAvailability) -> STTBackendStatus.State {
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
