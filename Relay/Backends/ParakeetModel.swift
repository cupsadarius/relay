import FluidAudio
import Foundation
import os

/// A loaded Parakeet model, ready to transcribe.
protocol ParakeetModelSession: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}

/// One Parakeet model's FluidAudio calls and per-model facts, so the load path can be exercised in
/// tests without constructing real CoreML models.
protocol ParakeetModelLoading: Sendable {
    /// Zero samples appended after every clip before transcription.
    var trailingSilenceSampleCount: Int { get }
    /// Network-free: whether the model files are on disk. Never opens them.
    func modelsArePresent() async -> Bool
    /// Network-free: verifies the model is present on disk AND intact. Slower than
    /// `modelsArePresent()`: it can open each model file.
    func isModelValid() async throws -> Bool
    /// Loads the model from disk. Must only be called once `isModelValid()` has returned `true`;
    /// FluidAudio's own loader will otherwise delete the cache and re-download on any failure.
    func load() async throws -> any ParakeetModelSession
    /// Downloads the model (if needed) and loads it. The only network access in this type.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession
}

typealias ParakeetModel = LocalModel<any ParakeetModelSession>

extension LocalModel where Session == any ParakeetModelSession {
    /// A FluidAudio English Parakeet model, run entirely on-device. Has no removal.
    ///
    /// A local-only load never *initiates* a download: it validates local files first. The one
    /// residual risk is upstream: FluidAudio's `DownloadUtils.loadModels` treats *any* failure
    /// while compiling an already-validated model as license to delete the cache and redownload.
    static func parakeet(loader: any ParakeetModelLoading) -> Self {
        let logger = Logger.relay("parakeet")
        let trailingSilence = loader.trailingSilenceSampleCount
        return LocalModel(
            isPresent: { await loader.modelsArePresent() },
            loader: ModelSessionLoader(
                modelsNotDownloaded: { ParakeetEngineError.modelsNotDownloaded },
                mapLoadFailure: { error in
                    logger.debug("Parakeet model load failed: \(error.localizedDescription, privacy: .private)")
                    return ParakeetEngineError.loadFailed("Parakeet model load failed")
                },
                validateLocal: {
                    do {
                        return try await loader.isModelValid()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logger.debug(
                            "Parakeet model validation failed: \(error.localizedDescription, privacy: .private)")
                        throw ParakeetEngineError.loadFailed("Parakeet model validation failed")
                    }
                },
                loadLocal: {
                    PaddedParakeetSession(session: try await loader.load(), trailingSilenceSampleCount: trailingSilence)
                },
                downloadAndLoad: { progress in
                    PaddedParakeetSession(
                        session: try await loader.downloadAndLoad(progress: progress),
                        trailingSilenceSampleCount: trailingSilence
                    )
                }
            ),
            removal: nil
        )
    }
}

/// Pads audio the way FluidAudio needs before the loaded model sees it.
private struct PaddedParakeetSession: ParakeetModelSession {
    /// FluidAudio requires at least one second of 16 kHz audio (`ASRError.invalidAudioData`).
    private static let minimumSampleCount = Int(AudioInput.sttSampleRate)

    let session: any ParakeetModelSession
    let trailingSilenceSampleCount: Int

    func transcribe(samples: [Float]) async throws -> String {
        var padded = samples
        padded.append(contentsOf: repeatElement(Float(0), count: trailingSilenceSampleCount))
        if padded.count < Self.minimumSampleCount {
            padded.append(contentsOf: repeatElement(Float(0), count: Self.minimumSampleCount - padded.count))
        }
        return try await session.transcribe(samples: padded)
    }
}

/// Live loader for Parakeet TDT v2, backed by FluidAudio's static `AsrModels`/`AsrManager` API.
struct ParakeetV2ModelLoader: ParakeetModelLoading {
    private static let version: AsrModelVersion = .v2

    /// Always FluidAudio's default: `AsrModels.isModelValid` takes no directory and only ever
    /// checks that location.
    let modelDirectory = AsrModels.defaultCacheDirectory(for: ParakeetV2ModelLoader.version)
    let trailingSilenceSampleCount = 0

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func isModelValid() async throws -> Bool {
        try await AsrModels.isModelValid(version: Self.version)
    }

    func load() async throws -> any ParakeetModelSession {
        let models = try await AsrModels.load(from: modelDirectory, version: Self.version)
        return try await makeSession(from: models)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        let models = try await AsrModels.downloadAndLoad(
            to: modelDirectory,
            version: Self.version,
            progressHandler: { downloadProgress in progress(downloadProgress.fractionCompleted) }
        )
        return try await makeSession(from: models)
    }

    private func makeSession(from models: AsrModels) async throws -> any ParakeetModelSession {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return AsrManagerSession(manager: manager)
    }
}

/// Thin wrapper around FluidAudio's `AsrManager` so it can conform to `ParakeetModelSession`.
private struct AsrManagerSession: ParakeetModelSession {
    let manager: AsrManager

    func transcribe(samples: [Float]) async throws -> String {
        // FluidAudio 0.15's `transcribe` requires an explicit decoder state (needed for
        // streaming state threading across chunks); a fresh state per call reproduces the old
        // stateless, single-shot `transcribe(_:)` behavior. `decoderLayerCount` matches the
        // loaded model version (2 for v2, which is all this loader ever loads).
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}

/// Live loader for Parakeet Unified. FluidAudio has no network-free validity check for it, so
/// validity is the presence of every file `UnifiedAsrManager` requires.
struct ParakeetUnifiedModelLoader: ParakeetModelLoading {
    let modelDirectory = AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()
        .appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    /// Unified drops the final full stop or question mark without trailing silence.
    let trailingSilenceSampleCount = 6_400

    func modelsArePresent() async -> Bool {
        let names = ModelNames.ParakeetUnified.self
        return [
            names.offlineEncoderFile(precision: .int8), names.decoderFile, names.jointDecisionFile, names.vocab,
        ].allSatisfy { FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }
    }

    func isModelValid() async throws -> Bool {
        await modelsArePresent()
    }

    func load() async throws -> any ParakeetModelSession {
        let manager = UnifiedAsrManager()
        try await manager.loadModels(from: modelDirectory)
        return UnifiedAsrSession(manager: manager)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        let manager = UnifiedAsrManager()
        try await manager.loadModels(
            to: modelDirectory.deletingLastPathComponent(),
            progressHandler: { progress($0.fractionCompleted) }
        )
        return UnifiedAsrSession(manager: manager)
    }
}

private struct UnifiedAsrSession: ParakeetModelSession {
    let manager: UnifiedAsrManager

    func transcribe(samples: [Float]) async throws -> String {
        try await manager.transcribe(samples)
    }
}
