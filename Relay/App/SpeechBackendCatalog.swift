import Foundation

typealias STTBackendStatus = BackendStatus
private typealias Catalog = BackendCatalog<any SpeechToTextBackend>

extension AppModel {
    func refreshSpeechBackendStatuses() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let order = knownSTTBackendOrder()
        var fresh: [STTBackendStatus] = []
        for id in sttRegistry.keys.sorted() {
            guard let backend = sttRegistry[id] else { continue }
            fresh.append(
                STTBackendStatus(
                    id: id,
                    displayName: backend.displayName,
                    state: Catalog.mapAvailability(await backend.availability()),
                    isEnabled: order.contains(id),
                    position: order.firstIndex(of: id) ?? Int.max
                )
            )
        }
        guard generation == refreshGeneration else { return }
        sttBackends = Catalog.sorted(fresh)
    }

    func setSTTBackendEnabled(_ id: String, _ enabled: Bool) {
        switch Catalog.settingEnabled(
            enabled,
            id: id,
            order: knownSTTBackendOrder(),
            registry: sttRegistry,
            refusalMessage: "At least one speech recognition backend must stay enabled."
        ) {
        case .noop: return
        case let .refused(message): setSpeechBackendMessage(message)
        case let .apply(order): applySpeechBackendOrder(order)
        }
    }

    func moveSTTBackend(_ id: String, up: Bool) {
        guard let order = Catalog.moved(knownSTTBackendOrder(), id: id, up: up) else { return }
        applySpeechBackendOrder(order)
    }

    private func setSpeechBackendMessage(_ message: String?) {
        speechBackendMessage = message
        if let message { statusText = message }
    }

    private func applySpeechBackendOrder(_ order: [String]) {
        settingsController.setSTTBackendOrder(order)
        sttBackends = Catalog.applyingOrder(order, to: sttBackends)
        setSpeechBackendMessage(nil)
    }

    private func knownSTTBackendOrder() -> [String] {
        Catalog.knownOrder(settings.sttBackendOrder, registry: sttRegistry)
    }
}
