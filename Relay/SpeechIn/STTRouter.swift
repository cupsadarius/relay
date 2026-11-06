import Foundation

/// The STT backend chosen for one dictation session. `STTRouter.selectBackend()` returns it when
/// listening begins, and the caller passes it back to `transcribe(audio:options:selection:)`.
/// `candidateOrder` starts at the chosen backend, so the final transcription skips backends
/// already ruled out, without the router caching a candidate order between calls.
struct STTSelection: Equatable, Sendable {
    let displayName: String
    let candidateOrder: [BackendID]
}

@MainActor
final class STTRouter {
    private enum SelectionStep {
        case use
        case terminal(SpeechBackendError)
        case skip(SpeechBackendError)
    }

    private let backends: [BackendID: any SpeechToTextBackend]
    private let backendOrder: () -> [BackendID]

    /// Display name of the backend whose error the most recent FINAL
    /// `transcribe(audio:options:selection:)` threw (the one that failed, or the last one skipped
    /// as unavailable). `nil` after a success, when no registered backend was tried, or when the
    /// call was cancelled. Interim transcriptions never touch it. Lets dictation error copy name
    /// the backend that needs attention.
    private(set) var lastFailedBackendDisplayName: String?

    init(
        backends: [BackendID: any SpeechToTextBackend],
        backendOrder: @escaping () -> [BackendID]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    /// The first available backend in the current order, or `nil` if none is available or a
    /// backend reports a terminal state (permission denied).
    func selectBackend() async -> STTSelection? {
        let order = backendOrder()
        for (index, id) in order.enumerated() {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                return STTSelection(displayName: backend.id.displayName, candidateOrder: Array(order[index...]))
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
    /// Announces the transcribe step, and the fallback step for every backend after the first.
    func transcribe(
        audio: AudioInput, options: STTOptions, selection: STTSelection? = nil, tracer: PipelineTracer? = nil
    ) async throws -> Transcript {
        lastFailedBackendDisplayName = nil
        var step: PipelineStep?
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        var lastErrorBackendName: String?

        for id in selection?.candidateOrder ?? backendOrder() {
            try Task.checkCancellation()
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                lastFailedBackendDisplayName = backend.id.displayName
                tracer?.fail(step ?? .transcribe, "\(backend.id.displayName): permission denied")
                throw error
            case let .skip(error):
                lastError = error
                lastErrorBackendName = backend.id.displayName
                continue
            }

            let name = backend.id.displayName
            let current: PipelineStep = step == nil ? .transcribe : .fallback
            step = current
            tracer?.start(current, current == .transcribe ? "Transcribing with \(name)" : "Falling back to \(name)")
            do {
                let transcript = try await backend.transcribe(audio: audio, options: options)
                tracer?.finish(current, name)
                return transcript
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
                lastErrorBackendName = name
                tracer?.fail(current, "\(name) failed")
            } catch is CancellationError {
                tracer?.stop(current, "Cancelled")
                throw CancellationError()
            } catch {
                lastFailedBackendDisplayName = name
                tracer?.fail(current, "\(name) failed")
                throw error
            }
        }

        lastFailedBackendDisplayName = lastErrorBackendName
        if step == nil { tracer?.fail(.transcribe, "No speech-to-text backend is available") }
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
        case .unsupportedHardware:
            .skip(.unsupportedHardware)
        case .failed(let reason):
            .skip(.initializationFailed(reason))
        }
    }
}
