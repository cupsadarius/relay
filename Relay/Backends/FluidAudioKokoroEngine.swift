import FluidAudio
import Foundation
import os

/// A loaded Kokoro model, ready to synthesize speech. `FluidAudioKokoroModelLoader` wraps
/// FluidAudio's `KokoroAneManager` (a `public actor`, already `Sendable` on its own) behind this
/// protocol purely as a test seam, so `FluidAudioKokoroEngine`'s loading logic can be exercised
/// against a fake without constructing real CoreML models.
struct KokoroPCM: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

protocol KokoroModelSession: Sendable {
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
    func phonemes(for text: String) async throws -> String
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM
}

/// Wraps FluidAudio's `KokoroAneManager`/`KokoroAneResourceDownloader` static/instance calls
/// behind a protocol so `FluidAudioKokoroEngine`'s single-flight, presence-check, and
/// error-mapping logic can be exercised in tests without constructing real CoreML models.
protocol KokoroModelLoading: Sendable {
    /// Network-free: true only if a valid model is already on disk. FluidAudio's KokoroAne module
    /// exposes no models-exist API, so this must be hand-rolled against the filesystem.
    func modelsArePresent() async -> Bool
    /// Loads an already-present model. Must only be called once `modelsArePresent()` has
    /// returned `true` - there is no network-free load path in FluidAudio's KokoroAne API, so
    /// this is the only protection against a residual download (see
    /// `FluidAudioKokoroModelLoader`).
    func loadLocal() async throws -> any KokoroModelSession
    /// Downloads the model (if needed) and loads it. The only *intended* network access in this
    /// type.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession
    func removeModels() async throws
}

extension KokoroModelLoading {
    func removeModels() async throws { throw KokoroEngineError.loadFailed }
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
    /// The input text produced more phonemes than a single KokoroAne call can handle (~510).
    /// FluidAudio's `KokoroAneManager` has no built-in chunker for this; `KokoroTTSBackend` maps
    /// this to `SpeechBackendError.inferenceFailed`, which the router treats as fallback-worthy,
    /// so a caller with multiple TTS backends enabled falls through to the next one (e.g.
    /// PocketTTS or Apple) instead of failing outright. See the doc comment on
    /// `FluidAudioKokoroEngine` for what a real chunker would need.
    case textTooLong
    /// A phoneme-safe segment still exceeded Kokoro's baked acoustic-frame cap. Long-form
    /// synthesis may split this specific size failure further; generic inference failures are
    /// never retried as though they were length failures.
    case acousticFramesTooLong
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
    func removeModels() async throws
    /// Synthesizes `text` to a complete WAV (24 kHz mono). The engine must already be loaded.
    /// Throws `KokoroEngineError.textTooLong` if `text` phonemizes to more than KokoroAne's
    /// ~510-phoneme per-call limit - callers must not feed it chunked text themselves without
    /// also handling that case, since there is no built-in chunker to fall back on.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
    /// Resolves exactly the phoneme stream Kokoro would synthesize for `text`.
    func phonemes(for text: String) async throws -> String
    /// Synthesizes an already-resolved phoneme segment directly to raw PCM.
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM
}

extension KokoroEngine {
    /// Convenience overload for callers that don't need download progress.
    func load(allowDownload: Bool) async throws {
        try await load(allowDownload: allowDownload, progress: { _ in })
    }

    func removeModels() async throws {
        throw KokoroEngineError.loadFailed
    }

    /// Compatibility defaults keep existing engine test fakes source-compatible while the live
    /// engine adopts the long-form primitives. Any source path using an old fake fails cleanly.
    func phonemes(for text: String) async throws -> String {
        throw KokoroEngineError.synthesisFailed
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        throw KokoroEngineError.synthesisFailed
    }
}

extension KokoroModelSession {
    func phonemes(for text: String) async throws -> String {
        throw KokoroEngineError.synthesisFailed
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        throw KokoroEngineError.synthesisFailed
    }
}

/// Production `KokoroEngine` backed by FluidAudio's `KokoroAneManager` (the ANE-resident,
/// 7-stage Kokoro 82M CoreML chain). Loads and runs the model entirely on-device.
///
/// **There is no network-free load path in FluidAudio's KokoroAne API.** `KokoroAneManager`'s
/// `initialize()` downloads any missing models before loading, and is a no-op download when
/// files are already present. The hand-rolled `modelsArePresent()` presence gate on
/// `load(allowDownload: false)` is therefore the primary protection against `initialize()`
/// reaching the network when a caller asked for a local-only load. It must cover every asset
/// `initialize()` can trigger a download for - not just the ANE chain itself but also the shared
/// G2P CoreML assets `initialize()` separately hard-downloads into a different cache directory
/// (see `FluidAudioKokoroModelLoader.modelsArePresent()`) - since a gate that only checks part of
/// what `initialize()` might download would still let a local-only load reach the network on a
/// partial cache. Only `load(allowDownload: true)` is meant to reach the network.
///
/// Relay now performs long-form chunking above this engine: the full text is resolved through
/// `phonemes(for:)`, safe phoneme segments are synthesized through the raw-PCM overload, and a
/// bounded audio source feeds the shared player. The legacy whole-WAV `synthesize(text:...)`
/// stays temporarily for the compatibility path while the unified-player migration settles.
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
    /// could let a later `allowDownload: false` call reach the network ungated. Never caches a
    /// negative result, since the user may download the model between calls. Only ever set by a
    /// `localOnly` load's own presence check - a `download` load never touches it directly.
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

    func removeModels() async throws {
        if let inFlightLoad {
            inFlightLoad.task.cancel()
            _ = try? await inFlightLoad.task.value
            clearIfCurrent(inFlightLoad.task)
        }
        session = nil
        validatedModelsPresent = false
        try await modelLoader.removeModels()
        guard await !modelLoader.modelsArePresent() else {
            throw KokoroEngineError.loadFailed
        }
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
        } catch KokoroAneError.phonemeSequenceTooLong {
            throw KokoroEngineError.textTooLong
        } catch {
            throw KokoroEngineError.synthesisFailed
        }
    }

    func phonemes(for text: String) async throws -> String {
        guard let session else {
            throw KokoroEngineError.synthesisFailed
        }

        do {
            return try await session.phonemes(for: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KokoroEngineError.synthesisFailed
        }
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        guard let session else {
            throw KokoroEngineError.synthesisFailed
        }

        do {
            return try await session.synthesize(phonemes: phonemes, voice: voice, speed: speed)
        } catch is CancellationError {
            throw CancellationError()
        } catch KokoroAneError.phonemeSequenceTooLong {
            throw KokoroEngineError.textTooLong
        } catch KokoroAneError.acousticFramesExceedCap {
            throw KokoroEngineError.acousticFramesTooLong
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

    /// The directory `KokoroAneManager`/`KokoroAneResourceDownloader` treat as their "Models"
    /// root - i.e. what gets passed as their `directory:` parameter directly, with no further
    /// path segment appended by Relay. Mirrors `KokoroAneResourceDownloader`'s own default
    /// (`TtsCacheDirectory.ensure()/Models`) so a caller that doesn't override the loader gets
    /// the exact same on-disk location FluidAudio would pick on its own.
    private static func defaultCacheDirectory() -> URL {
        (try? TtsCacheDirectory.ensure().appendingPathComponent(KokoroAneResourceDownloader.modelsSubdirectory))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models")
    }
}

/// Live `KokoroModelLoading` backed by FluidAudio's `KokoroAneManager`/
/// `KokoroAneResourceDownloader` API. Always loads the English variant - Relay exposes only the
/// Kokoro-82M v1.0 English voice catalog (`KokoroAneConstants.englishVoices`), never Mandarin or
/// Japanese.
///
/// `modelsArePresent()` is deliberately hand-rolled with `FileManager` rather than relying on
/// `KokoroAneManager.isAvailable()`: that's only true once the models are already loaded into
/// memory (i.e. after a successful `initialize()`), not a network-free "is it on disk" check -
/// exactly the same "cache directory always exists" trap the old `TtsModels.cacheDirectoryURL()`
/// had, just moved one level: `TtsCacheDirectory.ensure()` still creates
/// `~/.cache/fluidaudio` if missing. Instead this checks for the actual compiled model bundles
/// and auxiliary files FluidAudio's downloader places at `<cacheDirectory>/kokoro-82m-coreml/ANE/*`
/// (the ANE chain itself) - **and**, since `KokoroAneManager.initialize()` (English variant) also
/// hard-downloads the shared G2P CoreML assets it needs for text -> IPA conversion into a
/// different folder, at `<cacheDirectory>/kokoro/*` (see `ModelNames.G2P.requiredModels` and
/// `KokoroAneResourceDownloader.ensureG2PAssets`). Both sets must be present on disk for
/// `modelsArePresent()` to report `true`; a cache with only one half present (e.g. a G2P fetch
/// that previously failed) must not be reported as ready.
struct FluidAudioKokoroModelLoader: KokoroModelLoading {
    /// The directory `KokoroAneManager` and `KokoroAneResourceDownloader.ensureModels` treat as
    /// their "Models" root when passed as `directory:` - NOT the same as the old FluidAudio API's
    /// cache root, which had a "Models" subdirectory appended internally. See
    /// `FluidAudioKokoroEngine.defaultCacheDirectory()`.
    let cacheDirectory: URL

    private static let variant: KokoroAneVariant = .english

    private var modelsDirectory: URL {
        cacheDirectory.appendingPathComponent(Self.variant.repo.folderName)
    }

    /// Where `KokoroAneResourceDownloader.ensureG2PAssets` places the shared G2P encoder/decoder
    /// (`G2PEncoder.mlmodelc`, `G2PDecoder.mlmodelc`, `g2p_vocab.json`): `Repo.kokoro.folderName`
    /// ("kokoro") under the same "Models" root as `modelsDirectory` - a sibling of
    /// `kokoro-82m-coreml/ANE`, not nested under it. `KokoroAneManager.initialize()` actually
    /// fetches these via `ensureG2PAssets(directory: nil)`, which always resolves to FluidAudio's
    /// own default cache root rather than honoring a caller-supplied `directory:` - but that
    /// default is exactly what `FluidAudioKokoroEngine.defaultCacheDirectory()` passes as
    /// `cacheDirectory` here, so this stays correct as long as nothing overrides that default.
    private var g2pDirectory: URL {
        cacheDirectory.appendingPathComponent(Repo.kokoro.folderName)
    }

    func modelsArePresent() async -> Bool {
        Self.allFilesExist(ModelNames.KokoroAne.requiredModels, in: modelsDirectory)
            && Self.allFilesExist(ModelNames.G2P.requiredModels, in: g2pDirectory)
    }

    func removeModels() async throws {
        try removeIfPresent(modelsDirectory)
        try removeIfPresent(g2pDirectory)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// `.mlmodelc` entries are directories and `.json`/other auxiliary entries are plain files,
    /// but `FileManager.fileExists(atPath:)` doesn't care which - so this stays correct for both
    /// the ANE set and the G2P set without needing a per-entry `isDirectory` check.
    private static func allFilesExist(_ fileNames: Set<String>, in directory: URL) -> Bool {
        for fileName in fileNames {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) else {
                return false
            }
        }
        return true
    }

    func loadLocal() async throws -> any KokoroModelSession {
        try await makeSession(progress: nil)
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        try await makeSession(progress: progress)
    }

    private func makeSession(progress: (@Sendable (Double) -> Void)?) async throws -> any KokoroModelSession {
        let manager = KokoroAneManager(variant: Self.variant, directory: cacheDirectory)
        try await manager.initialize()
        progress?(1.0)
        return KokoroAneManagerSession(manager: manager)
    }
}

/// Thin wrapper around FluidAudio's `KokoroAneManager` so it can conform to `KokoroModelSession`.
/// `KokoroAneManager` is a `public actor` - already `Sendable` and self-serializing - so, unlike
/// the old plain-class `KokoroTtsManager`, this needs no acquire/release wrapping to keep
/// concurrent calls from interleaving inside it.
private struct KokoroAneManagerSession: KokoroModelSession {
    let manager: KokoroAneManager

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice, speed: speed)
    }

    func phonemes(for text: String) async throws -> String {
        try await manager.phonemes(for: text)
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        let result = try await manager.synthesizeFromPhonemesDetailed(
            phonemes,
            voice: voice,
            speed: speed
        )
        return KokoroPCM(samples: result.samples, sampleRate: Double(result.sampleRate))
    }
}
