import Foundation

/// Errors surfaced by a `ParakeetEngine` implementation. `ParakeetBackend` maps these onto
/// `SpeechBackendError` so the router can classify them the same way it classifies every other
/// backend's failures.
enum ParakeetEngineError: Error, Equatable, Sendable {
    /// The model was not present (or not verifiably intact) on disk and the caller did not allow
    /// a download.
    case modelsNotDownloaded
    /// `transcribe` was called before the engine ever finished a successful `load`.
    case notLoaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed(String)
    /// Inference itself failed once the model was loaded.
    case transcriptionFailed(String)
}

/// The seam between `ParakeetBackend` and the underlying Parakeet runtime (FluidAudio in
/// production, a fake in tests). Kept narrow and provider-neutral so `ParakeetBackend` never
/// touches FluidAudio types directly.
protocol ParakeetEngine: Sendable {
    /// Whether the model files are already present on disk. Never triggers a download.
    func modelsArePresent() async -> Bool
    /// Loads the model, downloading it first when `allowDownload` is true. When `allowDownload`
    /// is false and the model is absent (or fails local validation), throws
    /// `ParakeetEngineError.modelsNotDownloaded` without touching the network. Idempotent once
    /// loaded: concurrent and repeated calls after a successful load are no-ops. `progress` is
    /// called with a fraction in [0, 1] while a download is in flight; it may be called from any
    /// queue.
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Transcribes mono 16 kHz samples. The engine must already be loaded.
    func transcribe(samples: [Float]) async throws -> String
}

extension ParakeetEngine {
    /// Convenience overload for callers that don't need download progress.
    func load(allowDownload: Bool) async throws {
        try await load(allowDownload: allowDownload, progress: { _ in })
    }
}

/// On-device speech-to-text backend built on FluidAudio's Parakeet v2 (English) model. Fully
/// offline once its model is downloaded; never uploads audio or transcript text anywhere.
final class ParakeetBackend: SpeechToTextBackend {
    let id = "parakeet"
    let displayName = "Parakeet"
    let capabilities = STTCapabilities([
        .fullyOffline,
    ])

    private let engine: any ParakeetEngine

    init(engine: any ParakeetEngine = FluidAudioParakeetEngine()) {
        self.engine = engine
    }

    func availability() async -> BackendAvailability {
        await engine.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func prepare() async throws {
        try await ensureLoaded()
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        guard !audio.samples.isEmpty else {
            throw SpeechBackendError.noUsableAudio
        }
        guard audio.sampleRate == 16_000 else {
            throw SpeechBackendError.invalidInput
        }

        try await ensureLoaded()

        do {
            let text = try await engine.transcribe(samples: audio.samples)
            return Transcript(text: text, backendID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechBackendError {
            throw error
        } catch ParakeetEngineError.transcriptionFailed(let reason) {
            throw SpeechBackendError.inferenceFailed(reason)
        } catch ParakeetEngineError.notLoaded {
            throw SpeechBackendError.initializationFailed("Parakeet model is not loaded")
        } catch {
            throw SpeechBackendError.inferenceFailed("Parakeet transcription failed")
        }
    }

    private func ensureLoaded() async throws {
        do {
            try await engine.load(allowDownload: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapLoadError(error)
        }
    }

    private static func mapLoadError(_ error: Error) -> SpeechBackendError {
        switch error {
        case let error as SpeechBackendError:
            error
        case ParakeetEngineError.modelsNotDownloaded:
            .modelNotDownloaded
        case ParakeetEngineError.notLoaded:
            .initializationFailed("Parakeet model is not loaded")
        case ParakeetEngineError.loadFailed(let reason):
            .initializationFailed(reason)
        default:
            .initializationFailed("Parakeet model load failed")
        }
    }
}
