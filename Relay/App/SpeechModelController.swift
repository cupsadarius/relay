import Foundation
import Observation

enum SpeechModelDomain: Hashable, Sendable {
    case dictation
    case textToSpeech
}

struct SpeechModelBackendKey: Hashable, Sendable {
    let domain: SpeechModelDomain
    let backendID: String
}

private struct SpeechModelOperationKey: Hashable, Sendable {
    let backend: SpeechModelBackendKey
    let modelID: String
}

@MainActor
@Observable
final class SpeechModelController {
    typealias Managers = [SpeechModelBackendKey: any SpeechModelManaging]
    typealias BackendRefresh = @MainActor @Sendable (SpeechModelDomain) async -> Void
    typealias PreRemoval = @MainActor @Sendable (SpeechModelBackendKey) async -> Void

    private(set) var models: [SpeechModelBackendKey: [SpeechModelStatus]] = [:]
    private(set) var messages: [SpeechModelDomain: String] = [:]
    var backendKeys: Set<SpeechModelBackendKey> { Set(managers.keys) }

    @ObservationIgnored private let managers: Managers
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private var refreshBackends: BackendRefresh = { _ in }
    @ObservationIgnored private var beforeRemoval: PreRemoval = { _ in }
    @ObservationIgnored private var generations: [SpeechModelDomain: Int] = [:]
    @ObservationIgnored private var downloads: Set<SpeechModelOperationKey> = []

    init(managers: Managers, diagnostics: DiagnosticsRecorder) {
        self.managers = managers
        self.diagnostics = diagnostics
    }

    func configureHooks(
        refreshBackends: @escaping BackendRefresh,
        beforeRemoval: @escaping PreRemoval
    ) {
        self.refreshBackends = refreshBackends
        self.beforeRemoval = beforeRemoval
    }

    func refresh(domain: SpeechModelDomain) async {
        let generation = (generations[domain] ?? 0) + 1
        generations[domain] = generation
        var fresh: [SpeechModelBackendKey: [SpeechModelStatus]] = [:]
        for key in managers.keys.filter({ $0.domain == domain }).sorted(by: { $0.backendID < $1.backendID }) {
            guard let manager = managers[key] else { continue }
            fresh[key] = await manager.models()
        }
        guard generations[domain] == generation else { return }

        var next = models.filter { $0.key.domain != domain }
        for (key, rows) in fresh {
            next[key] = merged(fresh: rows, live: models[key] ?? [], backend: key)
        }
        models = next
    }

    func download(_ modelID: String, in backend: SpeechModelBackendKey) async {
        guard let manager = managers[backend] else { return }
        let operation = SpeechModelOperationKey(backend: backend, modelID: modelID)
        guard downloads.insert(operation).inserted else { return }

        messages.removeValue(forKey: backend.domain)
        setInstallState(.downloading(progress: 0), modelID: modelID, backend: backend)
        diagnostics.record(.speechModelDownloadStarted(backendID: backend.backendID))
        do {
            try await manager.downloadModel(modelID) { [weak self] progress in
                Task { @MainActor in
                    self?.applyProgress(progress, operation: operation)
                }
            }
            downloads.remove(operation)
            diagnostics.record(.speechModelDownloadFinished(backendID: backend.backendID))
            await refresh(domain: backend.domain)
            await refreshBackends(backend.domain)
        } catch {
            downloads.remove(operation)
            setInstallState(.downloadFailed, modelID: modelID, backend: backend)
            diagnostics.record(.speechModelDownloadFailed(backendID: backend.backendID))
            messages[backend.domain] = "\(displayName(for: backend.backendID)) model download failed. Check your connection and try again."
        }
    }

    func select(_ modelID: String, in backend: SpeechModelBackendKey) async {
        guard let manager = managers[backend] else { return }
        let previous = models[backend]
        do {
            try await manager.selectModel(modelID)
            diagnostics.record(.speechModelSelectionFinished(backendID: backend.backendID))
            messages.removeValue(forKey: backend.domain)
            await refresh(domain: backend.domain)
            await refreshBackends(backend.domain)
        } catch {
            models[backend] = previous
            diagnostics.record(.speechModelSelectionFailed(backendID: backend.backendID))
            messages[backend.domain] = "\(displayName(for: backend.backendID)) model selection failed. Try again."
        }
    }

    func remove(_ modelID: String, in backend: SpeechModelBackendKey) async {
        guard let manager = managers[backend] else { return }
        do {
            await beforeRemoval(backend)
            try await manager.removeModel(modelID)
            diagnostics.record(.speechModelRemovalFinished(backendID: backend.backendID))
            messages.removeValue(forKey: backend.domain)
            await refresh(domain: backend.domain)
            await refreshBackends(backend.domain)
        } catch {
            diagnostics.record(.speechModelRemovalFailed(backendID: backend.backendID))
            messages[backend.domain] = "\(displayName(for: backend.backendID)) model removal failed. Try again."
            await refresh(domain: backend.domain)
            await refreshBackends(backend.domain)
        }
    }

    private func merged(
        fresh: [SpeechModelStatus],
        live: [SpeechModelStatus],
        backend: SpeechModelBackendKey
    ) -> [SpeechModelStatus] {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        return fresh.map { candidate in
            guard let current = liveByID[candidate.id] else { return candidate }
            let operation = SpeechModelOperationKey(backend: backend, modelID: candidate.id)
            let preserveFailure = current.installState == .downloadFailed
            guard downloads.contains(operation) || preserveFailure else { return candidate }
            var result = candidate
            result.installState = current.installState
            return result
        }
    }

    private func applyProgress(_ value: Double, operation: SpeechModelOperationKey) {
        guard downloads.contains(operation) else { return }
        let progress = min(1, max(0, value))
        guard case let .downloading(current)? = models[operation.backend]?
            .first(where: { $0.id == operation.modelID })?.installState,
              progress >= current
        else { return }
        setInstallState(.downloading(progress: progress), modelID: operation.modelID, backend: operation.backend)
    }

    private func setInstallState(
        _ state: SpeechModelInstallState,
        modelID: String,
        backend: SpeechModelBackendKey
    ) {
        var rows = models[backend] ?? []
        if let index = rows.firstIndex(where: { $0.id == modelID }) {
            rows[index].installState = state
        } else {
            rows.append(
                SpeechModelStatus(
                    descriptor: .init(id: modelID, displayName: modelID, detail: nil, approximateDownloadBytes: nil),
                    capabilities: [.download, .select, .remove],
                    installState: state,
                    isSelected: false,
                    isLoaded: false
                )
            )
        }
        models[backend] = rows
    }

    private func displayName(for backendID: String) -> String {
        switch backendID {
        case "apple-speech": "Apple Speech"
        case "parakeet": "Parakeet"
        case "whisper": "Whisper"
        case "kokoro": "Kokoro"
        case "pocket-tts": "PocketTTS"
        case "apple-tts": "Apple"
        default: backendID
        }
    }
}
