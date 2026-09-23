import FluidAudio
import Foundation
import os

/// A loaded PocketTTS model, ready to synthesize speech. Kept as a narrow protocol purely as a
/// test seam, so `FluidAudioPocketTTSEngine`'s loading logic can be exercised against a fake
/// without constructing real CoreML models.
protocol PocketTTSModelSession: Sendable {
    /// Streams synthesized audio as raw Float32 frames, so playback can start before synthesis
    /// finishes. Each frame is 1920 samples (80ms) at `PocketTtsConstants.audioSampleRate`
    /// (24kHz), matching FluidAudio's `PocketTtsSynthesizer.AudioFrame`.
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
    func removeModels() async throws
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
/// touches FluidAudio types directly. Unlike `KokoroEngine`, PocketTTS has no speed parameter,
/// matching FluidAudio's `PocketTtsManager.synthesizeStreaming(text:voice:)`.
protocol PocketTTSEngine: Sendable {
    /// Whether the model files are already present on disk. Never triggers a download.
    func modelsArePresent() async -> Bool
    /// Loads the model, downloading it first when `allowDownload` is true. When `allowDownload`
    /// is false and the model is absent, throws `PocketTTSEngineError.modelsNotDownloaded`
    /// without touching the network. Idempotent once loaded: concurrent and repeated calls after
    /// a successful load are no-ops. `progress` is called with a fraction in [0, 1] while a
    /// download is in flight; it may be called from any queue.
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    func removeModels() async throws
    /// Streams synthesized audio as raw Float32 frames (24 kHz mono), so a player can begin
    /// scheduling audio before synthesis finishes. The engine must already be loaded - callers
    /// are expected to call `load(allowDownload:)` themselves first; this never triggers a load or
    /// download.
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
/// meant to reach the network. Single-flight loading and the local-validation gate live in
/// `ModelSessionLoader`.
actor FluidAudioPocketTTSEngine: PocketTTSEngine {
    private static let logger = Logger(subsystem: "dev.relaymac.Relay", category: "pocket-tts")

    private let modelLoader: any PocketTTSModelLoading
    private let sessionLoader: ModelSessionLoader<any PocketTTSModelSession>

    init(
        modelLoader: (any PocketTTSModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelLoader = modelLoader ?? FluidAudioPocketTTSModelLoader(cacheDirectory: Self.defaultCacheDirectory())
        self.modelLoader = modelLoader
        let logger = Self.logger
        sessionLoader = ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { PocketTTSEngineError.modelsNotDownloaded },
            mapLoadFailure: { _ in
                logger.debug("PocketTTS model load failed")
                return PocketTTSEngineError.loadFailed
            },
            validateLocal: { await modelLoader.modelsArePresent() },
            loadLocal: { try await modelLoader.loadLocal() },
            downloadAndLoad: { progress in try await modelLoader.downloadAndLoad(progress: progress) }
        )
    }

    func modelsArePresent() async -> Bool {
        await modelLoader.modelsArePresent()
    }

    func removeModels() async throws {
        await sessionLoader.reset()
        try await modelLoader.removeModels()
        guard await !modelLoader.modelsArePresent() else {
            throw PocketTTSEngineError.loadFailed
        }
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await sessionLoader.load(allowDownload: allowDownload, progress: progress)
    }

    /// Does not remap errors that occur while draining the returned stream: a stream, once
    /// returned, is consumed outside of any `do`/`catch` this method could wrap around it, so a
    /// source failure propagates to the caller as-is. The only error this method itself throws is
    /// the "not loaded" guard (`PocketTTSEngineError.synthesisFailed`), before any session call.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let session = await sessionLoader.session else {
            throw PocketTTSEngineError.synthesisFailed
        }

        return try await session.synthesizeStream(text: text, voice: voice)
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

    func removeModels() async throws {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelsDirectory)
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

/// Wraps FluidAudio's `PocketTtsManager`, an `actor`, so concurrent calls into it are serialized
/// by Swift itself.
private struct PocketTtsManagerSession: PocketTTSModelSession {
    let manager: PocketTtsManager

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
