import Foundation

/// A speech-to-text backend as presented in Settings: its place in the user's preferred order
/// and its current readiness, derived from `AppSettings.sttBackendOrder` plus a live
/// `BackendAvailability` check (or an in-flight download).
struct STTBackendStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case modelNotDownloaded
        case downloading(progress: Double)
        case unsupported(reason: String)
        case unavailable(reason: String)
        case failed
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
    /// download is in flight; it may be called from any queue.
    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension ParakeetBackend: SpeechModelDownloading {}

extension AppModel {
    /// Re-derives `sttBackends` from the current settings order and each registered backend's
    /// live `availability()`. A backend with an in-flight download keeps its `.downloading`
    /// state instead of being reset by this call.
    func refreshSpeechBackendStatuses() async {
        let order = settings.sttBackendOrder
        var updated: [STTBackendStatus] = []

        for id in sttRegistry.keys.sorted() {
            guard let backend = sttRegistry[id] else { continue }

            let isDownloading = downloadingBackendIDs.contains(id)
            let existingState = sttBackends.first(where: { $0.id == id })?.state
            let state = isDownloading
                ? (existingState ?? .downloading(progress: 0))
                : Self.mapAvailability(await backend.availability())

            updated.append(
                STTBackendStatus(
                    id: id,
                    displayName: backend.displayName,
                    state: state,
                    isEnabled: order.contains(id),
                    position: order.firstIndex(of: id) ?? Int.max
                )
            )
        }

        sttBackends = updated
        sortSpeechBackendStatuses()
    }

    /// Enables or disables a backend in `sttBackendOrder`. Refuses to disable the last enabled
    /// backend so the router always has somewhere to fall back to.
    func setSTTBackendEnabled(_ id: String, _ enabled: Bool) {
        guard sttRegistry[id] != nil else { return }
        var order = settings.sttBackendOrder

        if enabled {
            guard !order.contains(id) else { return }
            order.append(id)
        } else {
            guard order.contains(id) else { return }
            guard order.count > 1 else {
                statusText = "At least one speech recognition backend must stay enabled."
                return
            }
            order.removeAll { $0 == id }
        }

        updateSpeechBackendOrder(order)
    }

    /// Moves a backend one place earlier or later in `sttBackendOrder`. No-op if the backend
    /// isn't enabled or is already at that end of the order.
    func moveSTTBackend(_ id: String, up: Bool) {
        var order = settings.sttBackendOrder
        guard let index = order.firstIndex(of: id) else { return }
        let newIndex = up ? index - 1 : index + 1
        guard order.indices.contains(newIndex) else { return }

        order.swapAt(index, newIndex)
        updateSpeechBackendOrder(order)
    }

    /// Downloads the model for `id` (currently only Parakeet has one). Ignored if that backend
    /// has no downloader registered or a download for it is already running.
    func downloadSpeechModel(_ id: String) async {
        guard let downloader = speechModelDownloaders[id] else { return }
        guard !downloadingBackendIDs.contains(id) else { return }

        downloadingBackendIDs.insert(id)
        setSpeechBackendState(id, .downloading(progress: 0))
        let displayName = sttRegistry[id]?.displayName ?? id
        diagnostics.record(.speechModelDownloadStarted(backendID: id))

        do {
            try await downloader.downloadModels(progress: { [weak self] progress in
                Task { @MainActor in
                    self?.setSpeechBackendState(id, .downloading(progress: progress))
                }
            })
            downloadingBackendIDs.remove(id)
            diagnostics.record(.speechModelDownloadFinished(backendID: id))
            await refreshSpeechBackendStatuses()
        } catch {
            downloadingBackendIDs.remove(id)
            setSpeechBackendState(id, .failed)
            diagnostics.record(.speechModelDownloadFailed(backendID: id))
            statusText = "\(displayName) model download failed. Check your connection and try again."
        }
    }

    private func updateSpeechBackendOrder(_ order: [String]) {
        updateSettings { $0.sttBackendOrder = order }
        sttBackends = sttBackends.map { status in
            var updated = status
            updated.isEnabled = order.contains(status.id)
            updated.position = order.firstIndex(of: status.id) ?? Int.max
            return updated
        }
        sortSpeechBackendStatuses()
    }

    private func setSpeechBackendState(_ id: String, _ state: STTBackendStatus.State) {
        guard let index = sttBackends.firstIndex(where: { $0.id == id }) else { return }
        sttBackends[index].state = state
    }

    private func sortSpeechBackendStatuses() {
        sttBackends.sort { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }

    private static func mapAvailability(_ availability: BackendAvailability) -> STTBackendStatus.State {
        switch availability {
        case .available:
            .ready
        case .modelNotDownloaded:
            .modelNotDownloaded
        case .unsupportedOS, .unsupportedHardware:
            .unsupported(reason: "Unsupported on this Mac")
        case .permissionDenied, .unavailable, .initializing:
            .unavailable(reason: "Unavailable")
        case .failed:
            .failed
        }
    }
}
