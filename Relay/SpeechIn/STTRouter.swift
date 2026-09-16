@MainActor
final class STTRouter {
    private enum SelectionStep {
        case use
        case terminal(SpeechBackendError)
        case skip(SpeechBackendError)
    }

    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]
    private var cachedCandidateOrder: [String]?

    init(
        backends: [String: any SpeechToTextBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    func displayName(forBackendID id: String) -> String? {
        backends[id]?.displayName
    }

    func preferredBackendDisplayName() async -> String? {
        let order = backendOrder()
        for (index, id) in order.enumerated() {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                cachedCandidateOrder = Array(order[index...])
                return backend.displayName
            case .terminal:
                cachedCandidateOrder = nil
                return nil
            case .skip:
                continue
            }
        }
        cachedCandidateOrder = nil
        return nil
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        let order = cachedCandidateOrder ?? backendOrder()
        cachedCandidateOrder = nil
        return try await transcribe(audio: audio, options: options, order: order)
    }

    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try await transcribe(audio: audio, options: options, order: backendOrder())
    }

    private func transcribe(audio: AudioInput, options: STTOptions, order: [String]) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")

        for id in order {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                throw error
            case let .skip(error):
                lastError = error
                continue
            }

            do {
                return try await backend.transcribe(audio: audio, options: options)
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                throw error
            }
        }

        throw lastError
    }

    private func classify(_ availability: BackendAvailability) -> SelectionStep {
        switch availability {
        case .available:
            .use
        case .permissionDenied:
            .terminal(.permissionDenied)
        case .unavailable(let reason):
            .skip(.unavailable(reason))
        case .modelNotDownloaded:
            .skip(.modelNotDownloaded)
        case .unsupportedOS:
            .skip(.unsupportedOS)
        case .unsupportedHardware:
            .skip(.unsupportedHardware)
        case .initializing:
            .skip(.unavailable("Backend is initializing"))
        case .failed(let reason):
            .skip(.initializationFailed(reason))
        }
    }
}
