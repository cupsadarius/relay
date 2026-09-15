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
actor FluidAudioParakeetEngine: ParakeetEngine {
    private static let version: AsrModelVersion = .v2
    /// FluidAudio requires at least one second of 16 kHz audio (`ASRError.invalidAudioData`);
    /// shorter clips are zero-padded up to this length before transcription.
    private static let minimumSampleCount = 16_000

    /// Which flavor of load is in flight, tracked alongside its task. A caller with a different
    /// `allowDownload` value decides whether to join it, ignore it and start its own, or refuse
    /// to wait on it - see `load(allowDownload:progress:)`.
    private enum LoadKind: Equatable {
        case localOnly
        case download
    }

    /// The directory FluidAudio stores the Parakeet model files in. Always
    /// `AsrModels.defaultCacheDirectory(for: .v2)`: FluidAudio's own `AsrModels.isModelValid`
    /// takes no directory parameter and only ever checks that location, so this can't safely be
    /// pointed anywhere else.
    let modelDirectory: URL

    private let modelLoader: any ParakeetModelLoading
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "parakeet")

    private var session: (any ParakeetModelSession)?
    private var inFlightLoad: (task: Task<Void, Error>, kind: LoadKind)?
    /// Caches a positive `isModelValid()` result for as long as it remains trustworthy: cleared
    /// on any load failure, since FluidAudio's own failure handling can delete and redownload
    /// files out from under us (see the type-level doc comment), so a stale `true` could let a
    /// later `allowDownload: false` call reach `AsrModels.load` ungated. Never caches a negative
    /// result, since the user may download the model between calls. Only ever set by a
    /// `localOnly` load's own validation step - a `download` load never touches it directly.
    private var validatedModelsPresent: Bool

    init(
        modelLoader: (any ParakeetModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelDirectory = AsrModels.defaultCacheDirectory(for: Self.version)
        self.modelDirectory = modelDirectory
        self.modelLoader = modelLoader ?? FluidAudioModelLoader(modelDirectory: modelDirectory, version: Self.version)
        self.validatedModelsPresent = validatedModelsPresent
    }

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if session != nil {
            return
        }

        if let inFlightLoad {
            switch (inFlightLoad.kind, allowDownload) {
            case (.localOnly, false), (.download, true):
                // Same kind of load already running: just join it.
                try await awaitAndClear(inFlightLoad.task)
                return

            case (.localOnly, true):
                // A local-only load is running. A download caller wants a fresh download
                // regardless of that load's outcome, so it waits for it to get out of the way
                // (ignoring whether it succeeded or failed) and only then starts its own
                // download - unless the local-only load already produced a session.
                _ = try? await inFlightLoad.task.value
                clearIfCurrent(inFlightLoad.task)
                if session != nil {
                    return
                }
                try await startLoad(allowDownload: true, progress: progress)
                return

            case (.download, false):
                // A download (potentially ~1 GB) is running. Only worth waiting on if we already
                // know the model is locally valid; otherwise fail fast rather than block a caller
                // that only asked for a local load on a transfer it never requested.
                guard validatedModelsPresent else {
                    throw ParakeetEngineError.modelsNotDownloaded
                }
                try await awaitAndClear(inFlightLoad.task)
                return
            }
        }

        try await startLoad(allowDownload: allowDownload, progress: progress)
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

    /// Starts a fresh load of the given kind, registers it as in flight, and awaits it.
    private func startLoad(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let kind: LoadKind = allowDownload ? .download : .localOnly
        let task = Task { try await self.performLoad(allowDownload: allowDownload, progress: progress) }
        inFlightLoad = (task, kind)
        try await awaitAndClear(task)
    }

    /// Awaits `task`, then clears `inFlightLoad` - but only if it still refers to this exact
    /// task, so a newer load started while we were suspended (e.g. by a joiner that decided to
    /// start its own load once we finished) is never clobbered. A failure also invalidates any
    /// cached local validation, since we can no longer trust the on-disk state matches what was
    /// last checked.
    private func awaitAndClear(_ task: Task<Void, Error>) async throws {
        do {
            try await task.value
            clearIfCurrent(task)
        } catch is CancellationError {
            clearIfCurrent(task)
            throw CancellationError()
        } catch {
            clearIfCurrent(task)
            validatedModelsPresent = false
            throw error
        }
    }

    private func clearIfCurrent(_ task: Task<Void, Error>) {
        if inFlightLoad?.task == task {
            inFlightLoad = nil
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

/// Thin wrapper around FluidAudio's `AsrManager` so it can conform to `ParakeetModelSession`.
/// `AsrManager` is a `public actor` - already `Sendable` on its own - so this exists purely to
/// give `FluidAudioParakeetEngine` a protocol seam to fake in tests, not for concurrency safety.
private struct AsrManagerSession: ParakeetModelSession {
    let manager: AsrManager

    func transcribe(samples: [Float]) async throws -> String {
        let result = try await manager.transcribe(samples)
        return result.text
    }
}
