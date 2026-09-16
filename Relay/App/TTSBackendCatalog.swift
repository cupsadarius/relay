import Foundation

/// `TTSBackendStatus` is `BackendCatalog`'s shared `BackendStatus`, kept under its own name so
/// call sites (`AppModel.ttsBackends`, `TTSSettingsView`, tests) don't need to change.
typealias TTSBackendStatus = BackendStatus

private typealias Catalog = BackendCatalog<any TextToSpeechBackend>

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
            let state = Catalog.mapAvailability(await backend.availability())
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

        ttsBackends = Catalog.sorted(Catalog.merged(fresh: fresh, live: ttsBackends, downloadingIDs: downloadingTTSBackendIDs))
    }

    /// Whether `id` has a registered downloader (Kokoro and PocketTTS, today). The view uses this
    /// to decide whether to show a Download button at all.
    func canDownloadTTSModel(_ id: String) -> Bool {
        ttsModelDownloaders[id] != nil
    }

    /// Enables or disables a backend in `ttsBackendOrder`. Refuses to disable the last enabled
    /// backend so the router always has somewhere to fall back to.
    func setTTSBackendEnabled(_ id: String, _ enabled: Bool) {
        let outcome = Catalog.settingEnabled(
            enabled,
            id: id,
            order: knownTTSBackendOrder(),
            registry: ttsRegistry,
            refusalMessage: "At least one TTS backend must stay enabled."
        )
        switch outcome {
        case .noop:
            return
        case let .refused(message):
            setTTSBackendMessage(message)
        case let .apply(order):
            applyTTSBackendOrder(order)
        }
    }

    /// Moves a backend one place earlier or later in `ttsBackendOrder`. No-op if the backend
    /// isn't enabled or is already at that end of the order.
    func moveTTSBackend(_ id: String, up: Bool) {
        guard let order = Catalog.moved(knownTTSBackendOrder(), id: id, up: up) else { return }
        applyTTSBackendOrder(order)
    }

    /// Downloads the model for `id` (currently Kokoro and PocketTTS). Ignored if that backend has
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
            let finalState = availability.map(Catalog.mapAvailability) ?? .unavailable
            endTTSDownload(id, finalState: finalState)
        } catch {
            recordDiagnostic(.speechModelDownloadFailed(backendID: id))
            endTTSDownload(id, finalState: .downloadFailed)
            let displayName = ttsRegistry[id]?.displayName ?? id
            let message = "\(displayName) model download failed. Check your connection and try again."
            setTTSBackendMessage(message)
        }
    }

    /// Applies one progress tick from an in-flight download.
    private func applyTTSDownloadProgress(id: String, progress: Double) {
        guard Catalog.shouldApplyProgress(ttsBackends, id: id, progress: progress, downloadingIDs: downloadingTTSBackendIDs) else {
            return
        }
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
        ttsBackends = Catalog.applyingOrder(order, to: ttsBackends)
        setTTSBackendMessage(nil)
    }

    /// `ttsBackendOrder` filtered to ids this run actually has a backend for, so a stale or
    /// unknown id left over in settings never counts toward the last-enabled guard, positions, or
    /// what gets persisted the next time the order changes.
    private func knownTTSBackendOrder() -> [String] {
        Catalog.knownOrder(settings.ttsBackendOrder, registry: ttsRegistry)
    }

    /// Updates the state for `id`, inserting a new row built from the registry if one doesn't
    /// exist yet — e.g. a Download click that lands before the first `refreshTTSBackendStatuses()`
    /// has populated `ttsBackends`.
    private func setOrInsertTTSBackendState(_ id: String, _ state: TTSBackendStatus.State) {
        ttsBackends = Catalog.insertingOrUpdating(
            ttsBackends,
            id: id,
            state: state,
            displayName: ttsRegistry[id]?.displayName,
            order: knownTTSBackendOrder()
        )
    }
}
