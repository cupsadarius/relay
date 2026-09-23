import FluidAudio
import Foundation
import os

/// A loaded Parakeet model, ready to transcribe. `FluidAudioModelLoader` wraps FluidAudio's
/// `AsrManager` (already a `public actor`, hence already `Sendable` on its own) behind this
/// protocol purely as a test seam, so `FluidAudioParakeetEngine`'s loading logic can be exercised
/// against a fake without constructing real CoreML models.
protocol ParakeetModelSession: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}

/// Wraps FluidAudio's static `AsrModels`/`AsrManager` calls behind a protocol so
/// `FluidAudioParakeetEngine`'s single-flight, validation, and error-mapping logic can be
/// exercised in tests without constructing real CoreML models.
protocol ParakeetModelLoading: Sendable {
    /// Network-free: verifies the model is present on disk AND intact, mirroring FluidAudio's own
    /// `AsrModels.isModelValid`. Slower than a plain existence check (it opens each model file),
    /// so callers should cache a positive result.
    func isModelValid() async throws -> Bool
    /// Loads the model from disk. Must only be called once `isModelValid()` has returned `true`;
    /// FluidAudio's own loader will otherwise delete the cache and re-download on any failure.
    func load() async throws -> any ParakeetModelSession
    /// Downloads the model (if needed) and loads it. The only network access in this type.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession
}

/// Production `ParakeetEngine` backed by FluidAudio's English-only Parakeet TDT v2 model. Loads
/// and runs the model entirely on-device.
///
/// `load(allowDownload: false)` never *initiates* a download: it first calls
/// `AsrModels.isModelValid`, which only opens local files, and refuses to proceed to
/// `AsrModels.load(from:)` unless that succeeds. The one residual risk this cannot fully close is
/// upstream: FluidAudio's `DownloadUtils.loadModels` treats *any* failure while compiling an
/// already-validated model (e.g. a transient CoreML compilation error) as license to delete the
/// cache and redownload from HuggingFace. Only `load(allowDownload: true)` is meant to reach the
/// network; this is the closest to that guarantee this engine can make without patching FluidAudio.
/// Single-flight loading and the local-validation gate live in `ModelSessionLoader`.
actor FluidAudioParakeetEngine: ParakeetEngine {
    private static let version: AsrModelVersion = .v2
    /// FluidAudio requires at least one second of 16 kHz audio (`ASRError.invalidAudioData`);
    /// shorter clips are zero-padded up to this length before transcription.
    private static let minimumSampleCount = 16_000
    private static let logger = Logger(subsystem: "dev.relaymac.Relay", category: "parakeet")

    /// The directory FluidAudio stores the Parakeet model files in. Always
    /// `AsrModels.defaultCacheDirectory(for: .v2)`: FluidAudio's own `AsrModels.isModelValid`
    /// takes no directory parameter and only ever checks that location.
    let modelDirectory: URL

    private let sessionLoader: ModelSessionLoader<any ParakeetModelSession>

    init(
        modelLoader: (any ParakeetModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelDirectory = AsrModels.defaultCacheDirectory(for: Self.version)
        self.modelDirectory = modelDirectory
        let modelLoader = modelLoader ?? FluidAudioModelLoader(modelDirectory: modelDirectory, version: Self.version)
        let logger = Self.logger
        sessionLoader = ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { ParakeetEngineError.modelsNotDownloaded },
            mapLoadFailure: { error in
                logger.debug("Parakeet model load failed: \(error.localizedDescription, privacy: .private)")
                return ParakeetEngineError.loadFailed("Parakeet model load failed")
            },
            validateLocal: {
                do {
                    return try await modelLoader.isModelValid()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.debug("Parakeet model validation failed: \(error.localizedDescription, privacy: .private)")
                    throw ParakeetEngineError.loadFailed("Parakeet model validation failed")
                }
            },
            loadLocal: { try await modelLoader.load() },
            downloadAndLoad: { progress in try await modelLoader.downloadAndLoad(progress: progress) }
        )
    }

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await sessionLoader.load(allowDownload: allowDownload, progress: progress)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let session = await sessionLoader.session else {
            throw ParakeetEngineError.notLoaded
        }

        var paddedSamples = samples
        if paddedSamples.count < Self.minimumSampleCount {
            paddedSamples.append(
                contentsOf: repeatElement(Float(0), count: Self.minimumSampleCount - paddedSamples.count)
            )
        }

        do {
            return try await session.transcribe(samples: paddedSamples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.debug("Parakeet transcription failed: \(error.localizedDescription, privacy: .private)")
            throw ParakeetEngineError.transcriptionFailed("Parakeet transcription failed")
        }
    }
}

/// Live `ParakeetModelLoading` backed by FluidAudio's static `AsrModels`/`AsrManager` API.
private struct FluidAudioModelLoader: ParakeetModelLoading {
    let modelDirectory: URL
    let version: AsrModelVersion

    func isModelValid() async throws -> Bool {
        try await AsrModels.isModelValid(version: version)
    }

    func load() async throws -> any ParakeetModelSession {
        let models = try await AsrModels.load(from: modelDirectory, version: version)
        return try await makeSession(from: models)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        let models = try await AsrModels.downloadAndLoad(
            to: modelDirectory,
            version: version,
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
/// `AsrManager` is a `public actor` - already `Sendable` on its own - so this exists purely to
/// give `FluidAudioParakeetEngine` a protocol seam to fake in tests, not for concurrency safety.
private struct AsrManagerSession: ParakeetModelSession {
    let manager: AsrManager

    func transcribe(samples: [Float]) async throws -> String {
        // FluidAudio 0.15's `transcribe` requires an explicit decoder state (needed for
        // streaming state threading across chunks); a fresh state per call reproduces the old
        // stateless, single-shot `transcribe(_:)` behavior. `decoderLayerCount` matches the
        // loaded model version (2 for v2, which is all this engine ever loads).
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}
