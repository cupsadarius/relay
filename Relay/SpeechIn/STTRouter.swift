import Foundation

/// The STT backend chosen for one dictation session. `STTRouter.selectBackend()` returns it when
/// listening begins, and the caller passes it back to `transcribe(audio:options:selection:)`.
/// `candidateOrder` starts at the chosen backend, so the final transcription skips backends
/// already ruled out, without the router caching a candidate order between calls.
struct STTSelection: Equatable, Sendable {
    let backendID: String
    let displayName: String
    let candidateOrder: [String]
}

@MainActor
final class STTRouter {
    private enum SelectionStep {
        case use
        case terminal(SpeechBackendError)
        case skip(SpeechBackendError)
    }

    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]

    /// Display name of the backend whose error the most recent FINAL
    /// `transcribe(audio:options:selection:)` threw (the one that failed, or the last one skipped
    /// as unavailable). `nil` after a success, when no registered backend was tried, or when the
    /// call was cancelled. Interim transcriptions never touch it. Lets dictation error copy name
    /// the backend that needs attention.
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

    /// The first available backend in the current order, or `nil` if none is available or a
    /// backend reports a terminal state (permission denied).
    func selectBackend() async -> STTSelection? {
        let order = backendOrder()
        for (index, id) in order.enumerated() {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                return STTSelection(backendID: id, displayName: backend.displayName, candidateOrder: Array(order[index...]))
            case .terminal:
                return nil
            case .skip:
                continue
            }
        }
        return nil
    }

    /// Final transcription with fallback. It walks `selection.candidateOrder` when given, else the
    /// current backend order, and stops at the next backend once the task is cancelled.
    func transcribe(audio: AudioInput, options: STTOptions, selection: STTSelection? = nil) async throws -> Transcript {
        lastFailedBackendDisplayName = nil
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        var lastErrorBackendName: String?

        for id in selection?.candidateOrder ?? backendOrder() {
            try Task.checkCancellation()
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                lastFailedBackendDisplayName = backend.displayName
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailedBackendDisplayName = backend.displayName
                throw error
            }
        }

        lastFailedBackendDisplayName = lastErrorBackendName
        throw lastError
    }

    /// Interim (live preview) transcription runs every ~450 ms. It uses only the first
    /// available backend and never falls back: a fallback here would load a second model on
    /// every tick just to draw a preview. It never touches `lastFailedBackendDisplayName`.
    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")

        for id in backendOrder() {
            try Task.checkCancellation()
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                return try await backend.transcribe(audio: audio, options: options)
            case let .terminal(error):
                throw error
            case let .skip(error):
                lastError = error
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
        case .failed(let reason):
            .skip(.initializationFailed(reason))
        }
    }
}
