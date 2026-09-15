@MainActor
final class STTRouter {
    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]
    /// The backend that produced the most recently returned transcript, so callers can detect
    /// a mid-call fallback (the preferred backend picked before transcription started differs
    /// from the one that actually succeeded).
    private(set) var lastUsedBackendDisplayName: String?

    init(
        backends: [String: any SpeechToTextBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    /// The display name of the first configured backend that is currently `.available`,
    /// mirroring `transcribe`'s own selection order. `nil` if none are available.
    func preferredBackendDisplayName() async -> String? {
        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            if case .available = await backend.availability() {
                return backend.displayName
            }
        }
        return nil
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
                let transcript = try await backend.transcribe(audio: audio, options: options)
                lastUsedBackendDisplayName = backend.displayName
                return transcript
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                throw error
            }
        }

        throw lastError
    }
}
