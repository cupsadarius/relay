import Foundation

/// Errors `ParakeetModelManager` throws. `unknownModel` covers any id other than
/// `ParakeetModelManager.modelID`; `removeNotSupported` is returned by `removeModel` -- see its
/// doc comment for why Parakeet has no remove path today.
enum ParakeetModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

/// The one-model `SpeechModelManaging` implementation for Relay's Parakeet backend. Parakeet
/// (unlike Whisper) has exactly one model, so this is the "0/1 model" counterpart to
/// `WhisperModelManager`'s many-model case: `models()` always returns a single status that is
/// always selected, and `selectModel` is a validating no-op since there is nothing else the
/// selection could ever be.
///
/// Wraps the same `ParakeetEngine` seam `ParakeetBackend` already uses -- `modelsArePresent()`
/// for presence, `load(allowDownload: true, progress:)` for download -- rather than inventing a
/// second seam over the same underlying engine. That means tests fake `ParakeetEngine` (as
/// `ParakeetBackendTests` and `FluidAudioParakeetEngineTests` already do) and never construct
/// FluidAudio/CoreML types. Every stored property is itself `Sendable` (`ParakeetEngine` is
/// `Sendable`), so this can be a plain struct like `WhisperModelManager`, with no isolation of
/// its own.
struct ParakeetModelManager: SpeechModelManaging {
    /// Relay's one Parakeet model id. FluidAudio has no public string id for this model (only
    /// `AsrModelVersion.v2` and a cache-folder name, `parakeet-tdt-0.6b-v2`), so this is minted
    /// here as the id this `SpeechModelManaging` surface exposes.
    static let modelID = "parakeet-v2"

    let backendID = "parakeet"

    private let engine: any ParakeetEngine

    init(engine: any ParakeetEngine = FluidAudioParakeetEngine()) {
        self.engine = engine
    }

    /// Always exactly one status. `isSelected` is always true: a one-model backend's only model
    /// is always "the selection". `isLoaded` is always reported false -- `ParakeetEngine` exposes
    /// no query for "is a session currently loaded in memory" (only presence, and a `load` call
    /// that has the side effect of loading), and widening that seam purely for this cosmetic
    /// field isn't worth it; see `WhisperModelManager.models()` for the many-model case where
    /// loaded state is tracked for real.
    func models() async -> [SpeechModelStatus] {
        let present = await engine.modelsArePresent()
        return [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                installState: present ? .downloaded : .notDownloaded,
                isSelected: true,
                isLoaded: false
            )
        ]
    }

    /// Validates `id`, then delegates to the engine's own download-and-load, the same path
    /// `ParakeetBackend.downloadModels(progress:)` uses.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validate(id)
        try await engine.load(allowDownload: true, progress: progress)
    }

    /// No-op beyond validating `id`: with exactly one model, "select" can't change anything.
    func selectModel(_ id: String) async throws {
        try Self.validate(id)
    }

    /// Parakeet has no remove path today -- `ParakeetEngine` exposes no delete, only presence and
    /// load. Unlike Whisper's per-model removal (one of eleven, with ten others to fall back to),
    /// deleting Relay's only always-offline STT model is enough of a distinct, consequential
    /// action that it deserves its own explicit support later rather than a half-built delete
    /// here that reaches into `FluidAudioParakeetEngine.modelDirectory` behind the engine's back.
    /// So this validates `id` (an unknown id still reports `unknownModel`, not
    /// `removeNotSupported`) and then always throws `removeNotSupported`.
    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw ParakeetModelManagerError.removeNotSupported
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "Parakeet v2",
        detail: "English only",
        approximateDownloadBytes: nil
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw ParakeetModelManagerError.unknownModel(id)
        }
    }
}
