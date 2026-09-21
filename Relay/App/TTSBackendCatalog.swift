import Foundation

typealias TTSBackendStatus = BackendStatus
private typealias Catalog = BackendCatalog<any TextToSpeechBackend>

extension AppModel {
    func refreshTTSBackendStatuses() async {
        ttsRefreshGeneration += 1
        let generation = ttsRefreshGeneration
        let order = knownTTSBackendOrder()
        var fresh: [TTSBackendStatus] = []
        for id in ttsRegistry.keys.sorted() {
            guard let backend = ttsRegistry[id] else { continue }
            fresh.append(
                TTSBackendStatus(
                    id: id,
                    displayName: backend.displayName,
                    state: Catalog.mapAvailability(await backend.availability()),
                    isEnabled: order.contains(id),
                    position: order.firstIndex(of: id) ?? Int.max
                )
            )
        }
        guard generation == ttsRefreshGeneration else { return }
        ttsBackends = Catalog.sorted(fresh)
    }

    func setTTSBackendEnabled(_ id: String, _ enabled: Bool) {
        switch Catalog.settingEnabled(
            enabled,
            id: id,
            order: knownTTSBackendOrder(),
            registry: ttsRegistry,
            refusalMessage: "At least one TTS backend must stay enabled."
        ) {
        case .noop: return
        case let .refused(message): setTTSBackendMessage(message)
        case let .apply(order): applyTTSBackendOrder(order)
        }
    }

    func moveTTSBackend(_ id: String, up: Bool) {
        guard let order = Catalog.moved(knownTTSBackendOrder(), id: id, up: up) else { return }
        applyTTSBackendOrder(order)
    }

    private func setTTSBackendMessage(_ message: String?) {
        ttsBackendMessage = message
        if let message { statusText = message }
    }

    private func applyTTSBackendOrder(_ order: [String]) {
        setTTSBackendOrder(order)
        ttsBackends = Catalog.applyingOrder(order, to: ttsBackends)
        setTTSBackendMessage(nil)
    }

    private func knownTTSBackendOrder() -> [String] {
        Catalog.knownOrder(settings.ttsBackendOrder, registry: ttsRegistry)
    }
}
