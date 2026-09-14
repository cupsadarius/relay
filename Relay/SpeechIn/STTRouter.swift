@MainActor
final class STTRouter {
    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]

    init(
        backends: [String: any SpeechToTextBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")

        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            switch await backend.availability() {
            case .available:
                break
            case .permissionDenied:
                throw SpeechBackendError.permissionDenied
            case .unavailable(let reason):
                lastError = .unavailable(reason)
                continue
            case .modelNotDownloaded:
                lastError = .modelNotDownloaded
                continue
            case .unsupportedOS:
                lastError = .unsupportedOS
                continue
            case .unsupportedHardware:
                lastError = .unsupportedHardware
                continue
            case .initializing:
                lastError = .unavailable("Backend is initializing")
                continue
            case .failed(let reason):
                lastError = .initializationFailed(reason)
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
}
