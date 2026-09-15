@MainActor
final class STTRouter {
    /// The outcome of classifying one backend's `availability()` result, shared by
    /// `preferredBackendDisplayName()` and `transcribe`'s selection loop so the two can never
    /// disagree about which availability states are skip-worthy vs. terminal for the whole router.
    private enum SelectionStep {
        case use
        case terminal(SpeechBackendError)
        case skip(SpeechBackendError)
    }

    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]
    /// The tail of the most recent `backendOrder()` walk, starting at the backend
    /// `preferredBackendDisplayName()` last found `.available`. Lets a `transcribe()` call that
    /// immediately follows skip re-probing the backends already ruled out by that lookup, instead
    /// re-checking only from where it left off. Consumed (and cleared) by the very next
    /// `transcribe()` call, whether or not it was actually able to use it, so a cached selection
    /// never outlives a single lookup-then-transcribe pairing.
    private var cachedCandidateOrder: [String]?

    init(
        backends: [String: any SpeechToTextBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    /// The display name of the configured backend with the given ID, if any. Used to look up the
    /// backend that actually produced a given `Transcript` via its `backendID`.
    func displayName(forBackendID id: String) -> String? {
        backends[id]?.displayName
    }

    /// The display name of the first configured backend that is currently `.available`,
    /// mirroring `transcribe`'s own selection order. `nil` if none are available, including when
    /// a backend reports `.permissionDenied` — a terminal condition for the whole router, exactly
    /// as in `transcribe`, so no backend after it is ever considered.
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
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        let order = cachedCandidateOrder ?? backendOrder()
        cachedCandidateOrder = nil

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
