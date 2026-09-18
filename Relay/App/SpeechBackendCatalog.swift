import Foundation

/// `STTBackendStatus` is `BackendCatalog`'s shared `BackendStatus`, kept under its own name so
/// call sites (`AppModel.sttBackends`, `DictationSettingsView`, tests) don't need to change.
typealias STTBackendStatus = BackendStatus

/// Thrown by `downloadSpeechModel` if a registered manager unexpectedly reports no models.
/// Every manager registered today (Parakeet) always has exactly one, so this should never
/// actually happen in production; it exists only so the backend-id -> model-id parity adapter
/// has something well-defined to throw instead of force-unwrapping.
private enum SpeechModelCatalogError: Error, Sendable {
    case noModelRegistered
}

private typealias Catalog = BackendCatalog<any SpeechToTextBackend>

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
            let state = Catalog.mapAvailability(await backend.availability())
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

        sttBackends = Catalog.sorted(Catalog.merged(fresh: fresh, live: sttBackends, downloadingIDs: downloadingBackendIDs))
    }

    /// Whether `id` has a registered model manager (only Parakeet, today). The view uses this to
    /// decide whether to show a Download button at all.
    func canDownloadSpeechModel(_ id: String) -> Bool {
        speechModelManagers[id] != nil
    }

    /// Enables or disables a backend in `sttBackendOrder`. Refuses to disable the last enabled
    /// backend so the router always has somewhere to fall back to.
    func setSTTBackendEnabled(_ id: String, _ enabled: Bool) {
        let outcome = Catalog.settingEnabled(
            enabled,
            id: id,
            order: knownSTTBackendOrder(),
            registry: sttRegistry,
            refusalMessage: "At least one speech recognition backend must stay enabled."
        )
        switch outcome {
        case .noop:
            return
        case let .refused(message):
            setSpeechBackendMessage(message)
        case let .apply(order):
            applySpeechBackendOrder(order)
        }
    }

    /// Moves a backend one place earlier or later in `sttBackendOrder`. No-op if the backend
    /// isn't enabled or is already at that end of the order.
    func moveSTTBackend(_ id: String, up: Bool) {
        guard let order = Catalog.moved(knownSTTBackendOrder(), id: id, up: up) else { return }
        applySpeechBackendOrder(order)
    }

    /// Downloads the model for `id` (currently only Parakeet has one). Ignored if that backend
    /// has no manager registered or a download for it is already running. `downloadingBackendIDs`
    /// and the row's `.downloading` state are always written together in the same synchronous
    /// step (`beginDownload`/`endDownload`) so the two can never disagree about whether a
    /// download is running.
    ///
    /// `speechModelManagers` is keyed by backend id but `SpeechModelManaging.downloadModel` takes
    /// a MODEL id, so this resolves the manager's single model via `models()` first -- parity
    /// with the old one-download-per-backend behavior. Per-model selection (letting a caller
    /// download one of several models for a backend) lands in the follow-up task; every manager
    /// registered here today (Parakeet) still has exactly one model.
    func downloadSpeechModel(_ id: String) async {
        guard let manager = speechModelManagers[id] else { return }
        guard !downloadingBackendIDs.contains(id) else { return }

        beginDownload(id)
        setSpeechBackendMessage(nil)
        recordDiagnostic(.speechModelDownloadStarted(backendID: id))

        do {
            guard let modelID = await manager.models().first?.id else {
                throw SpeechModelCatalogError.noModelRegistered
            }
            try await manager.downloadModel(modelID, progress: { [weak self] progress in
                Task { @MainActor in
                    self?.applyDownloadProgress(id: id, progress: progress)
                }
            })
            recordDiagnostic(.speechModelDownloadFinished(backendID: id))
            let availability = await sttRegistry[id]?.availability()
            let finalState = availability.map(Catalog.mapAvailability) ?? .unavailable
            endDownload(id, finalState: finalState)
        } catch {
            recordDiagnostic(.speechModelDownloadFailed(backendID: id))
            endDownload(id, finalState: .downloadFailed)
            let displayName = sttRegistry[id]?.displayName ?? id
            let message = "\(displayName) model download failed. Check your connection and try again."
            setSpeechBackendMessage(message)
        }
    }

    /// Applies one progress tick from an in-flight download.
    private func applyDownloadProgress(id: String, progress: Double) {
        guard Catalog.shouldApplyProgress(sttBackends, id: id, progress: progress, downloadingIDs: downloadingBackendIDs) else {
            return
        }
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
        sttBackends = Catalog.applyingOrder(order, to: sttBackends)
        setSpeechBackendMessage(nil)
    }

    /// `sttBackendOrder` filtered to ids this run actually has a backend for, so a stale or
    /// unknown id left over in settings never counts toward the last-enabled guard, positions, or
    /// what gets persisted the next time the order changes.
    private func knownSTTBackendOrder() -> [String] {
        Catalog.knownOrder(settings.sttBackendOrder, registry: sttRegistry)
    }

    /// Updates the state for `id`, inserting a new row built from the registry if one doesn't
    /// exist yet — e.g. a Download click that lands before the first `refreshSpeechBackendStatuses()`
    /// has populated `sttBackends`.
    private func setOrInsertSpeechBackendState(_ id: String, _ state: STTBackendStatus.State) {
        sttBackends = Catalog.insertingOrUpdating(
            sttBackends,
            id: id,
            state: state,
            displayName: sttRegistry[id]?.displayName,
            order: knownSTTBackendOrder()
        )
    }
}
