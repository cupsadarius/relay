import FluidAudio
import Foundation
import os

/// A loaded PocketTTS model, ready to synthesize speech. Kept as a narrow protocol purely as a
/// test seam, so `FluidAudioPocketTTSEngine`'s loading logic can be exercised against a fake
/// without constructing real CoreML models.
protocol PocketTTSModelSession: Sendable {
    func synthesize(text: String, voice: String) async throws -> Data
    /// Streams synthesized audio as raw Float32 frames instead of a complete WAV, so playback can
    /// start before synthesis finishes. Each frame is 1920 samples (80ms) at
    /// `PocketTtsConstants.audioSampleRate` (24kHz), matching FluidAudio's
    /// `PocketTtsSynthesizer.AudioFrame`.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
}

/// Wraps FluidAudio's `PocketTtsManager`/`PocketTtsResourceDownloader` calls behind a protocol so
/// `FluidAudioPocketTTSEngine`'s single-flight, presence-check, and error-mapping logic can be
/// exercised in tests without constructing real CoreML models.
protocol PocketTTSModelLoading: Sendable {
    /// Network-free: true only if a valid model is already on disk. FluidAudio's PocketTTS module
    /// exposes no models-exist API of its own, so this must be hand-rolled against the filesystem.
    func modelsArePresent() async -> Bool
    /// Loads an already-present model. Must only be called once `modelsArePresent()` has
    /// returned `true` - there is no network-free load path in FluidAudio's PocketTTS API, so
    /// this is the only protection against a residual download (see
    /// `FluidAudioPocketTTSModelLoader`).
    func loadLocal() async throws -> any PocketTTSModelSession
    /// Downloads the model (if needed) and loads it. The only *intended* network access in this
    /// type.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession
}

/// Errors surfaced by a `PocketTTSEngine` implementation. `PocketTTSBackend` maps these onto
/// `SpeechBackendError` so the router can classify them the same way it classifies every other
/// backend's failures. Deliberately carries no associated reason strings (unlike
/// `ParakeetEngineError`): TTS failures must never end up logged or diagnosed with raw error
/// text, per the privacy rule.
enum PocketTTSEngineError: Error, Equatable, Sendable {
    /// The model was not present on disk and the caller did not allow a download.
    case modelsNotDownloaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed
    /// Synthesis failed, including a call made before the engine ever finished a successful load.
    case synthesisFailed
}

/// The seam between `PocketTTSBackend` and the underlying PocketTTS runtime (FluidAudio in
/// production, a fake in tests). Kept narrow and provider-neutral so `PocketTTSBackend` never
/// touches FluidAudio types directly. Unlike `KokoroEngine`, PocketTTS has no speed parameter:
/// `synthesize(text:voice:)` takes none, matching FluidAudio's
/// `PocketTtsManager.synthesize(text:voice:)`, which has no `voiceSpeed` equivalent.
protocol PocketTTSEngine: Sendable {
    /// Whether the model files are already present on disk. Never triggers a download.
    func modelsArePresent() async -> Bool
    /// Loads the model, downloading it first when `allowDownload` is true. When `allowDownload`
    /// is false and the model is absent, throws `PocketTTSEngineError.modelsNotDownloaded`
    /// without touching the network. Idempotent once loaded: concurrent and repeated calls after
    /// a successful load are no-ops. `progress` is called with a fraction in [0, 1] while a
    /// download is in flight; it may be called from any queue.
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Synthesizes `text` to a complete WAV (24 kHz mono). The engine must already be loaded.
    func synthesize(text: String, voice: String) async throws -> Data
    /// Streams synthesized audio as raw Float32 frames (24 kHz mono) instead of a complete WAV,
    /// so a player can begin scheduling audio before synthesis finishes. The engine must already
    /// be loaded - unlike `synthesize(text:voice:)`, callers are expected to call
    /// `load(allowDownload:)` themselves first; this never triggers a load or download.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
}

extension PocketTTSEngine {
    /// Convenience overload for callers that don't need download progress.
    func load(allowDownload: Bool) async throws {
        try await load(allowDownload: allowDownload, progress: { _ in })
    }
}

/// Production `PocketTTSEngine` backed by FluidAudio's PocketTTS CoreML model. Loads and runs the
/// model entirely on-device.
///
/// **There is no network-free load path in FluidAudio's PocketTTS API.** `PocketTtsManager.initialize()`
/// downloads any missing models (via `PocketTtsResourceDownloader.ensureModels`) before loading,
/// and is a no-op download when files are already present. The hand-rolled `modelsArePresent()`
/// presence gate on `load(allowDownload: false)` is therefore the ONLY protection against
/// `initialize()` reaching the network when a caller asked for a local-only load - there is no
/// way to close that gap further without patching FluidAudio. Only `load(allowDownload: true)` is
/// meant to reach the network.
actor FluidAudioPocketTTSEngine: PocketTTSEngine {
    /// Which flavor of load is in flight, tracked alongside its task. A caller with a different
    /// `allowDownload` value decides whether to join it, ignore it and start its own, or refuse
    /// to wait on it - see `load(allowDownload:progress:)`.
    private enum LoadKind: Equatable {
        case localOnly
        case download
    }

    private let modelLoader: any PocketTTSModelLoading
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "pocket-tts")

    private var session: (any PocketTTSModelSession)?
    private var inFlightLoad: (task: Task<Void, Error>, kind: LoadKind)?
    /// Caches a positive `modelsArePresent()` result for as long as it remains trustworthy:
    /// cleared on any load failure, since FluidAudio's own failure handling can delete and
    /// redownload files out from under us (see the type-level doc comment), so a stale `true`
    /// could let a later `allowDownload: false` call reach the network ungated. Never caches a
    /// negative result, since the user may download the model between calls. Only ever set by a
    /// `localOnly` load's own presence check - a `download` load never touches it directly.
    private var validatedModelsPresent: Bool

    init(
        modelLoader: (any PocketTTSModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        self.modelLoader = modelLoader ?? FluidAudioPocketTTSModelLoader(cacheDirectory: Self.defaultCacheDirectory())
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
                    throw PocketTTSEngineError.modelsNotDownloaded
                }
                try await awaitAndClear(inFlightLoad.task)
                return
            }
        }

        try await startLoad(allowDownload: allowDownload, progress: progress)
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        guard let session else {
            throw PocketTTSEngineError.synthesisFailed
        }

        do {
            return try await session.synthesize(text: text, voice: voice)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PocketTTSEngineError.synthesisFailed
        }
    }

    /// Unlike `synthesize(text:voice:)`, does not remap errors that occur while draining the
    /// returned stream: a stream, once returned, is consumed outside of any `do`/`catch` this
    /// method could wrap around it, so a source failure propagates to the caller as-is. The only
    /// error this method itself throws is the same "not loaded" guard `synthesize(text:voice:)`
    /// throws, before any session call is made.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let session else {
            throw PocketTTSEngineError.synthesisFailed
        }

        return try await session.synthesizeStream(text: text, voice: voice)
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
                throw PocketTTSEngineError.modelsNotDownloaded
            }
        }

        let loadedSession: any PocketTTSModelSession
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
            logger.debug("PocketTTS model load failed")
            throw PocketTTSEngineError.loadFailed
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
        (try? TtsCacheDirectory.ensure())
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio")
    }
}

/// Live `PocketTTSModelLoading` backed by FluidAudio's `PocketTtsManager`/
/// `PocketTtsResourceDownloader` API.
///
/// `modelsArePresent()` is deliberately hand-rolled with `FileManager` rather than relying on
/// `PocketTtsModelStore.repoDir()` - that accessor only returns a value once a model has already
/// been loaded, and the default cache directory helper it's built on
/// (`TtsModels.cacheDirectoryURL()`/FluidAudio's internal PocketTTS cache helper) creates
/// `~/.cache/fluidaudio` if missing, so a plain "does the cache directory exist" check would
/// always be true and falsely report the model as ready. Instead this checks for the actual
/// compiled model bundles and constants directory FluidAudio's downloader places at
/// `<cacheDirectory>/Models/pocket-tts/v2.1/english/*` - the exact path
/// `PocketTtsResourceDownloader.ensureModels` itself checks before deciding whether to download.
struct FluidAudioPocketTTSModelLoader: PocketTTSModelLoading {
    let cacheDirectory: URL

    private var modelsDirectory: URL {
        // FluidAudio 0.15 nests each language pack under a versioned subdirectory
        // (`v2.1/<language>/`); `PocketTtsLanguage.english.repoSubdirectory` gives that segment
        // so this stays in sync with wherever `PocketTtsResourceDownloader.ensureModels` actually
        // places the files.
        cacheDirectory
            .appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory)
            .appendingPathComponent(Repo.pocketTts.folderName)
            .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
    }

    func modelsArePresent() async -> Bool {
        let directory = modelsDirectory
        for fileName in ModelNames.PocketTTS.requiredModels {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(fileName).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
        }
        return true
    }

    func loadLocal() async throws -> any PocketTTSModelSession {
        let manager = PocketTtsManager(directory: cacheDirectory)
        try await manager.initialize()
        return PocketTtsManagerSession(manager: manager)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession {
        _ = try await PocketTtsResourceDownloader.ensureModels(
            language: .english,
            directory: cacheDirectory,
            progressHandler: { downloadProgress in progress(downloadProgress.fractionCompleted) }
        )
        let manager = PocketTtsManager(directory: cacheDirectory)
        try await manager.initialize()
        return PocketTtsManagerSession(manager: manager)
    }
}

/// Wraps FluidAudio's `PocketTtsManager`, which - unlike `KokoroTtsManager` - is already an
/// `actor`, so concurrent calls into it are serialized by Swift itself without needing the extra
/// acquire/release wrapping `KokoroTtsManagerSession` uses for Kokoro's plain, non-actor manager
/// class.
private struct PocketTtsManagerSession: PocketTTSModelSession {
    let manager: PocketTtsManager

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }

    /// Adapts FluidAudio's `AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error>` (each
    /// frame carrying 1920 Float32 samples plus chunk/frame bookkeeping this layer doesn't need)
    /// down to a plain `AsyncThrowingStream<[Float], Error>` of raw samples, forwarding elements
    /// and the terminal error or finish exactly as FluidAudio produces them.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let frames = try await manager.synthesizeStreaming(text: text, voice: voice)
        return AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                do {
                    for try await frame in frames {
                        continuation.yield(frame.samples)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forwardingTask.cancel() }
        }
    }
}
