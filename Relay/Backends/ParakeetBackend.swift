import Foundation

/// Errors surfaced by a `ParakeetEngine` implementation. `ParakeetBackend` maps these onto
/// `SpeechBackendError` so the router can classify them the same way it classifies every other
/// backend's failures.
enum ParakeetEngineError: Error, Equatable, Sendable {
    /// The model was not present on disk and the caller did not allow a download.
    case modelsNotDownloaded
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
    /// is false and the model is absent, throws `ParakeetEngineError.modelsNotDownloaded` without
    /// touching the network. Idempotent once loaded.
    func load(allowDownload: Bool) async throws
    /// Transcribes mono 16 kHz samples. The engine must already be loaded.
    func transcribe(samples: [Float]) async throws -> String
}

/// On-device speech-to-text backend built on FluidAudio's Parakeet TDT v3 model. Fully offline
/// once its model is downloaded; never uploads audio or transcript text anywhere.
final class ParakeetBackend: SpeechToTextBackend {
    let id = "parakeet"
    let displayName = "Parakeet"
    let capabilities = STTCapabilities([
        .multilingual,
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

    /// Downloads the model if needed, then loads it. Not part of `SpeechToTextBackend`; intended
    /// for a future Settings "Download" action.
    func downloadModels() async throws {
        do {
            try await engine.load(allowDownload: true)
        } catch {
            throw Self.mapLoadError(error)
        }
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        guard !audio.samples.isEmpty else {
            throw SpeechBackendError.noUsableAudio
        }

        try await ensureLoaded()

        do {
            let text = try await engine.transcribe(samples: audio.samples)
            return Transcript(text: text, backendID: id)
        } catch let error as SpeechBackendError {
            throw error
        } catch ParakeetEngineError.transcriptionFailed(let reason) {
            throw SpeechBackendError.inferenceFailed(reason)
        } catch {
            throw SpeechBackendError.inferenceFailed("Parakeet transcription failed")
        }
    }

    private func ensureLoaded() async throws {
        do {
            try await engine.load(allowDownload: false)
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
        case ParakeetEngineError.loadFailed(let reason):
            .initializationFailed(reason)
        default:
            .initializationFailed("Parakeet model load failed")
        }
    }
}
