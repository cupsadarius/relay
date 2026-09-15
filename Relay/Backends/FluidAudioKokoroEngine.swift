import FluidAudio
import Foundation
import os

/// A loaded Kokoro model, ready to synthesize speech. `FluidAudioKokoroModelLoader` wraps
/// FluidAudio's `KokoroTtsManager` (a plain, non-actor class) behind this protocol purely as a
/// test seam, so `FluidAudioKokoroEngine`'s loading logic can be exercised against a fake without
/// constructing real CoreML models. It is itself an actor (not just a struct wrapping the
/// manager) so that concurrent calls into the underlying, non-`Sendable` `KokoroTtsManager` are
/// always serialized, matching the safety `AsrManagerSession` gets for free from `AsrManager`
/// already being an actor.
protocol KokoroModelSession: Sendable {
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

/// Wraps FluidAudio's `TtsModels`/`KokoroTtsManager` static/instance calls behind a protocol so
/// `FluidAudioKokoroEngine`'s single-flight, presence-check, and error-mapping logic can be
/// exercised in tests without constructing real CoreML models.
protocol KokoroModelLoading: Sendable {
    /// Network-free: true only if a valid model is already on disk. Unlike ASR, FluidAudio's TTS
    /// module exposes no models-exist API, so this must be hand-rolled against the filesystem.
    func modelsArePresent() async -> Bool
    /// Loads an already-present model. Must only be called once `modelsArePresent()` has
    /// returned `true` - there is no network-free load path in FluidAudio's TTS API, so this is
    /// the only protection against a residual download (see `FluidAudioKokoroModelLoader`).
    func loadLocal() async throws -> any KokoroModelSession
    /// Downloads the model (if needed) and loads it. The only *intended* network access in this
    /// type.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession
}

/// Errors surfaced by a `KokoroEngine` implementation. `KokoroTTSBackend` maps these onto
/// `SpeechBackendError` so the router can classify them the same way it classifies every other
/// backend's failures. Deliberately carries no associated reason strings (unlike
/// `ParakeetEngineError`): TTS failures must never end up logged or diagnosed with raw error
/// text, per the privacy rule.
enum KokoroEngineError: Error, Equatable, Sendable {
    /// The model was not present on disk and the caller did not allow a download.
    case modelsNotDownloaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed
    /// Synthesis failed, including a call made before the engine ever finished a successful load.
    case synthesisFailed
}

/// The seam between `KokoroTTSBackend` and the underlying Kokoro runtime (FluidAudio in
/// production, a fake in tests). Kept narrow and provider-neutral so `KokoroTTSBackend` never
/// touches FluidAudio types directly.
protocol KokoroEngine: Sendable {
    /// Whether the model files are already present on disk. Never triggers a download.
    func modelsArePresent() async -> Bool
    /// Loads the model, downloading it first when `allowDownload` is true. When `allowDownload`
    /// is false and the model is absent, throws `KokoroEngineError.modelsNotDownloaded` without
    /// touching the network. Idempotent once loaded: concurrent and repeated calls after a
    /// successful load are no-ops. `progress` is called with a fraction in [0, 1] while a
    /// download is in flight; it may be called from any queue.
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Synthesizes `text` to a complete WAV (24 kHz mono). The engine must already be loaded.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

extension KokoroEngine {
    /// Convenience overload for callers that don't need download progress.
    func load(allowDownload: Bool) async throws {
        try await load(allowDownload: allowDownload, progress: { _ in })
    }
}

/// Production `KokoroEngine` backed by FluidAudio's Kokoro CoreML TTS model. Loads and runs the
/// model entirely on-device.
///
/// **There is no network-free load path in FluidAudio's TTS API.** Unlike `AsrModels`, which
/// offers `isModelValid`/`load(from:)`, `TtsModels` offers only `download(directory:)`, which
/// loads from disk when files are present but *re-downloads* if any are absent or corrupt. The
/// hand-rolled `modelsArePresent()` presence gate on `load(allowDownload: false)` is therefore
/// the ONLY protection against `TtsModels.download` reaching the network when a caller asked for
/// a local-only load - there is no way to close that gap further without patching FluidAudio.
/// Only `load(allowDownload: true)` is meant to reach the network.
actor FluidAudioKokoroEngine: KokoroEngine {
    /// Which flavor of load is in flight, tracked alongside its task. A caller with a different
    /// `allowDownload` value decides whether to join it, ignore it and start its own, or refuse
    /// to wait on it - see `load(allowDownload:progress:)`.
    private enum LoadKind: Equatable {
        case localOnly
        case download
    }

    private let modelLoader: any KokoroModelLoading
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "kokoro")

    private var session: (any KokoroModelSession)?
    private var inFlightLoad: (task: Task<Void, Error>, kind: LoadKind)?
    /// Caches a positive `modelsArePresent()` result for as long as it remains trustworthy:
    /// cleared on any load failure, since FluidAudio's own failure handling can delete and
    /// redownload files out from under us (see the type-level doc comment), so a stale `true`
    /// could let a later `allowDownload: false` call reach `TtsModels.download` ungated. Never
    /// caches a negative result, since the user may download the model between calls. Only ever
    /// set by a `localOnly` load's own presence check - a `download` load never touches it
    /// directly.
    private var validatedModelsPresent: Bool

    init(
        modelLoader: (any KokoroModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        self.modelLoader = modelLoader ?? FluidAudioKokoroModelLoader(cacheDirectory: Self.defaultCacheDirectory())
        self.validatedModelsPresent = validatedModelsPresent
    }

    func modelsArePresent() async -> Bool {
        await modelLoader.modelsArePresent()
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
                // A download is running. Only worth waiting on if we already know the model is
                // locally present; otherwise fail fast rather than block a caller that only
                // asked for a local load on a transfer it never requested.
                guard validatedModelsPresent else {
                    throw KokoroEngineError.modelsNotDownloaded
                }
                try await awaitAndClear(inFlightLoad.task)
                return
            }
        }

        try await startLoad(allowDownload: allowDownload, progress: progress)
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        guard let session else {
            throw KokoroEngineError.synthesisFailed
        }

        do {
            return try await session.synthesize(text: text, voice: voice, speed: speed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KokoroEngineError.synthesisFailed
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
    /// cached presence result, since we can no longer trust the on-disk state matches what was
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
            guard await modelsAreValidatedLocally() else {
                throw KokoroEngineError.modelsNotDownloaded
            }
        }

        let loadedSession: any KokoroModelSession
        do {
            loadedSession =
                if allowDownload {
                    try await modelLoader.downloadAndLoad(progress: progress)
                } else {
                    try await modelLoader.loadLocal()
                }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("Kokoro model load failed")
            throw KokoroEngineError.loadFailed
        }

        session = loadedSession
    }

    /// Network-free. Returns the cached positive result when available; otherwise asks the
    /// loader's hand-rolled filesystem check.
    private func modelsAreValidatedLocally() async -> Bool {
        if validatedModelsPresent {
            return true
        }

        let present = await modelLoader.modelsArePresent()
        if present {
            validatedModelsPresent = true
        }
        return present
    }

    private static func defaultCacheDirectory() -> URL {
        (try? TtsModels.cacheDirectoryURL())
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio")
    }
}

/// Live `KokoroModelLoading` backed by FluidAudio's `TtsModels`/`KokoroTtsManager` API.
///
/// `modelsArePresent()` is deliberately hand-rolled with `FileManager` rather than relying on
/// `TtsModels.cacheDirectoryURL()` existing: that call creates `~/.cache/fluidaudio` if missing,
/// so a plain "does the cache directory exist" check would always be true and falsely report the
/// model as ready. Instead this checks for the actual compiled model bundles FluidAudio's
/// downloader places at `<cacheDirectory>/Models/kokoro/<variant>.mlmodelc`.
struct FluidAudioKokoroModelLoader: KokoroModelLoading {
    let cacheDirectory: URL

    private var modelsDirectory: URL {
        cacheDirectory
            .appendingPathComponent(TtsConstants.defaultModelsSubdirectory)
            .appendingPathComponent(Repo.kokoro.folderName)
    }

    func modelsArePresent() async -> Bool {
        let directory = modelsDirectory
        for fileName in ModelNames.TTS.Variant.allCases.map(\.fileName) {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(fileName).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
        }
        return true
    }

    func loadLocal() async throws -> any KokoroModelSession {
        let models = try await TtsModels.download(directory: cacheDirectory)
        return try await makeSession(from: models)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        let models = try await TtsModels.download(
            directory: cacheDirectory,
            progressHandler: { downloadProgress in progress(downloadProgress.fractionCompleted) }
        )
        return try await makeSession(from: models)
    }

    private func makeSession(from models: TtsModels) async throws -> any KokoroModelSession {
        let manager = KokoroTtsManager(directory: cacheDirectory)
        try await manager.initialize(models: models)
        return KokoroTtsManagerSession(manager: manager)
    }
}

/// Serializes access to FluidAudio's `KokoroTtsManager`, which is a plain, non-`Sendable`,
/// non-actor class (unlike `AsrManager`, which is already an actor) with internal mutable state
/// (cached voice embeddings, etc.). Wrapping it in our own actor is not, by itself, enough:
/// actors are reentrant, so two overlapping calls to `synthesize` could still both be suspended
/// inside `manager.synthesize` at once. `manager` is therefore held `nonisolated(unsafe)` and
/// every call is funneled through an explicit acquire/release queue so at most one call into the
/// manager is ever in flight, giving `AsrManagerSession`'s safety guarantee back without
/// depending on FluidAudio making the type Sendable.
private actor KokoroTtsManagerSession: KokoroModelSession {
    private nonisolated(unsafe) let manager: KokoroTtsManager
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(manager: KokoroTtsManager) {
        self.manager = manager
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        await acquire()
        defer { release() }
        return try await manager.synthesize(text: text, voice: voice, voiceSpeed: speed)
    }

    private func acquire() async {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isBusy = true
    }

    private func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        // Ownership passes directly to the next waiter; `isBusy` stays true throughout.
        let next = waiters.removeFirst()
        next.resume()
    }
}
