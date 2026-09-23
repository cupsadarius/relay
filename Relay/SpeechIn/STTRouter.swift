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
    /// Display name of the backend whose error the most recent FINAL `transcribe(audio:options:)`
    /// threw (the one that failed, or the last one skipped as unavailable). `nil` after a
    /// success, or when no registered backend was tried. Interim transcriptions never touch it.
    /// Lets dictation error copy name the backend that needs attention.
    private(set) var lastFailedBackendDisplayName: String?

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
        lastFailedBackendDisplayName = nil
        return try await transcribe(audio: audio, options: options, order: order) { failedName in
            lastFailedBackendDisplayName = failedName
        }
    }

    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try await transcribe(audio: audio, options: options, order: backendOrder()) { _ in }
    }

    /// `onFailure` receives the display name of the backend whose error is about to be thrown
    /// (`nil` when no registered backend was tried), right before the throw.
    private func transcribe(
        audio: AudioInput,
        options: STTOptions,
        order: [String],
        onFailure: (String?) -> Void
    ) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        var lastErrorBackendName: String?

        for id in order {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                onFailure(backend.displayName)
                throw error
            case let .skip(error):
                lastError = error
                lastErrorBackendName = backend.displayName
                continue
            }

            do {
                return try await backend.transcribe(audio: audio, options: options)
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
                lastErrorBackendName = backend.displayName
            } catch {
                onFailure(backend.displayName)
                throw error
            }
        }

        onFailure(lastErrorBackendName)
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
