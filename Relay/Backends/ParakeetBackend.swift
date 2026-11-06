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

/// One model per Parakeet id. A struct with a field per case, so every id always has a model.
struct ParakeetModels: Sendable {
    let unifiedEnglish: ParakeetModel
    let v2: ParakeetModel

    subscript(model: ParakeetModelID) -> ParakeetModel {
        switch model {
        case .unifiedEnglish: unifiedEnglish
        case .v2: v2
        }
    }
}

/// Parakeet load failures. `ParakeetBackend` maps these onto `SpeechBackendError` so the router
/// can classify them the same way it classifies every other backend's failures.
enum ParakeetEngineError: Error, Equatable, Sendable {
    /// The model was not present (or not verifiably intact) on disk and the caller did not allow
    /// a download.
    case modelsNotDownloaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed(String)
}

extension LocalModel where Session == any ParakeetModelSession {
    /// Loads the model when it is on disk. Never downloads; swallows errors.
    func prewarmIfPresent() async {
        guard await modelsArePresent() else { return }
        do {
            try await load()
        } catch {
            Logger.relay("parakeet")
                .debug("Parakeet prewarm failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// On-device speech-to-text backend built on FluidAudio's Parakeet models (English). Fully
/// offline once its model is downloaded; never uploads audio or transcript text anywhere.
final class ParakeetBackend: SpeechToTextBackend {
    let id = BackendID.parakeet

    private let models: ParakeetModels
    private let selectedModel: ParakeetModelSelection

    private var model: ParakeetModel { models[selectedModel() ?? .default] }

    init(models: ParakeetModels, selectedModel: @escaping ParakeetModelSelection) {
        self.models = models
        self.selectedModel = selectedModel
    }

    func availability() async -> BackendAvailability {
        await model.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try audio.requireSTTFormat()

        let session: any ParakeetModelSession
        do {
            session = try await model.load()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapLoadError(error)
        }

        do {
            let text = try await session.transcribe(samples: audio.samples)
            return Transcript(text: text, backendID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.relay("parakeet")
                .debug("Parakeet transcription failed: \(error.localizedDescription, privacy: .private)")
            throw SpeechBackendError.inferenceFailed("Parakeet transcription failed")
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
