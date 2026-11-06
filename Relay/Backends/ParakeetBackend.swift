import Foundation
import os

/// The Parakeet models a user can pick between. Raw values are the ids the settings store and
/// `SpeechModelManaging` use; `.v2` keeps its original id so an existing download and selection
/// still map.
enum ParakeetModelID: String, CaseIterable, Sendable {
    case unifiedEnglish = "parakeet-unified-en"
    case v2 = "parakeet-v2"

    static let `default`: ParakeetModelID = .unifiedEnglish
}

typealias ParakeetModelSelection = @Sendable () -> ParakeetModelID?
typealias ParakeetModelSelectionWriter = @MainActor @Sendable (ParakeetModelID?) -> Void

/// One engine per model. A struct with a field per case, so every model always has an engine.
struct ParakeetEngines: Sendable {
    let unifiedEnglish: any ParakeetEngine
    let v2: any ParakeetEngine

    subscript(model: ParakeetModelID) -> any ParakeetEngine {
        switch model {
        case .unifiedEnglish: unifiedEnglish
        case .v2: v2
        }
    }
}

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

    /// Loads the model in the background-friendly way: never downloads, swallows errors.
    func prewarmIfPresent() async {
        guard await modelsArePresent() else { return }
        do {
            try await load(allowDownload: false)
        } catch {
            Logger.relay("parakeet")
                .debug("Parakeet prewarm failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// On-device speech-to-text backend built on FluidAudio's Parakeet models (English). Fully
/// offline once its model is downloaded; never uploads audio or transcript text anywhere.
final class ParakeetBackend: SpeechToTextBackend {
    let id = BackendID.parakeet.rawValue
    let displayName = BackendID.parakeet.displayName

    private let engines: ParakeetEngines
    private let selectedModel: ParakeetModelSelection

    private var engine: any ParakeetEngine { engines[selectedModel() ?? .default] }

    init(engines: ParakeetEngines, selectedModel: @escaping ParakeetModelSelection) {
        self.engines = engines
        self.selectedModel = selectedModel
    }

    func availability() async -> BackendAvailability {
        await engine.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try audio.requireSTTFormat()

        let engine = engine
        try await ensureLoaded(engine)

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

    private func ensureLoaded(_ engine: any ParakeetEngine) async throws {
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
