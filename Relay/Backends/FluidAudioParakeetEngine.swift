import FluidAudio
import Foundation
import os

/// A loaded Parakeet model, ready to transcribe. Wraps FluidAudio's `AsrManager` behind an actor
/// so the non-`Sendable` manager never has to cross an isolation boundary.
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

/// Production `ParakeetEngine` backed by FluidAudio's Parakeet TDT v3 model. Loads and runs the
/// model entirely on-device.
///
/// `load(allowDownload: false)` never *initiates* a download: it first calls
/// `AsrModels.isModelValid`, which only opens local files, and refuses to proceed to
/// `AsrModels.load(from:)` unless that succeeds. The one residual risk this cannot fully close is
/// upstream: FluidAudio's `DownloadUtils.loadModels` treats *any* failure while compiling an
/// already-validated model (e.g. a transient CoreML compilation error) as license to delete the
/// cache and redownload from HuggingFace. Only `load(allowDownload: true)` is meant to reach the
/// network; this is the closest to that guarantee this engine can make without patching FluidAudio.
actor FluidAudioParakeetEngine: ParakeetEngine {
    private static let version: AsrModelVersion = .v3
    /// FluidAudio requires at least one second of 16 kHz audio (`ASRError.invalidAudioData`);
    /// shorter clips are zero-padded up to this length before transcription.
    private static let minimumSampleCount = 16_000

    /// The directory FluidAudio stores (or expects to find) the Parakeet model files in. Must
    /// equal `AsrModels.defaultCacheDirectory(for: .v3)` for `AsrModels.isModelValid` to see the
    /// same location this engine checks: FluidAudio's `isModelValid()` takes no directory
    /// parameter and always resolves the default cache path for the given version itself.
    let modelDirectory: URL

    private let modelLoader: any ParakeetModelLoading
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "parakeet")

    private var session: (any ParakeetModelSession)?
    private var inFlightLoad: Task<Void, Error>?
    /// Caches a positive `isModelValid()` result for the process lifetime so repeated `load`
    /// attempts (e.g. from repeated `prepare()` calls before the first one settles) don't re-open
    /// every model file each time. Never caches a negative result, since the user may download
    /// the model between calls.
    private var validatedModelsPresent = false

    init(
        modelDirectory: URL = AsrModels.defaultCacheDirectory(for: FluidAudioParakeetEngine.version),
        modelLoader: (any ParakeetModelLoading)? = nil
    ) {
        self.modelDirectory = modelDirectory
        self.modelLoader = modelLoader ?? FluidAudioModelLoader(modelDirectory: modelDirectory, version: Self.version)
    }

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if session != nil {
            return
        }

        if let inFlightLoad {
            try await inFlightLoad.value
            return
        }

        let task = Task { try await self.performLoad(allowDownload: allowDownload, progress: progress) }
        inFlightLoad = task

        do {
            try await task.value
            inFlightLoad = nil
        } catch is CancellationError {
            inFlightLoad = nil
            throw CancellationError()
        } catch {
            inFlightLoad = nil
            throw error
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let session else {
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
            logger.debug("Parakeet transcription failed: \(error.localizedDescription, privacy: .private)")
            throw ParakeetEngineError.transcriptionFailed("Parakeet transcription failed")
        }
    }

    private func performLoad(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if !allowDownload {
            guard try await modelsAreValidatedLocally() else {
                throw ParakeetEngineError.modelsNotDownloaded
            }
        }

        let loadedSession: any ParakeetModelSession
        do {
            loadedSession =
                if allowDownload {
                    try await modelLoader.downloadAndLoad(progress: progress)
                } else {
                    try await modelLoader.load()
                }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("Parakeet model load failed: \(error.localizedDescription, privacy: .private)")
            throw ParakeetEngineError.loadFailed("Parakeet model load failed")
        }

        session = loadedSession
        validatedModelsPresent = true
    }

    /// Network-free. Returns the cached positive result when available; otherwise asks the
    /// loader, which mirrors `AsrModels.isModelValid` (existence plus a local CoreML open of each
    /// model file).
    private func modelsAreValidatedLocally() async throws -> Bool {
        if validatedModelsPresent {
            return true
        }

        do {
            let valid = try await modelLoader.isModelValid()
            if valid {
                validatedModelsPresent = true
            }
            return valid
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("Parakeet model validation failed: \(error.localizedDescription, privacy: .private)")
            throw ParakeetEngineError.loadFailed("Parakeet model validation failed")
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
        try await manager.initialize(models: models)
        return AsrManagerSession(manager: manager)
    }
}

/// Isolates FluidAudio's non-`Sendable` `AsrManager` so it never has to cross an actor boundary.
private actor AsrManagerSession: ParakeetModelSession {
    private let manager: AsrManager

    init(manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(samples: [Float]) async throws -> String {
        let result = try await manager.transcribe(samples)
        return result.text
    }
}
