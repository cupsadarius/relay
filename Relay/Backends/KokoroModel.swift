import FluidAudio
import Foundation
import os

struct KokoroPCM: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

/// A loaded Kokoro model, ready to synthesize speech. Throws `KokoroEngineError` (or
/// `CancellationError`), never raw FluidAudio errors.
protocol KokoroModelSession: Sendable {
    /// Resolves exactly the phoneme stream Kokoro would synthesize for `text`.
    func phonemes(for text: String) async throws -> String
    /// Synthesizes an already-resolved phoneme segment directly to raw PCM.
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM
}

/// Wraps FluidAudio's `KokoroAneManager`/`KokoroAneResourceDownloader` calls so the Kokoro load
/// path can be exercised in tests without constructing real CoreML models.
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

/// Kokoro load and synthesis failures. `KokoroTTSBackend` maps these onto `SpeechBackendError`.
/// Deliberately carries no reason strings: TTS failures must never end up logged or diagnosed
/// with raw error text, per the privacy rule.
enum KokoroEngineError: Error, Equatable, Sendable {
    /// The model was not present on disk and the caller did not allow a download.
    case modelsNotDownloaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed
    case synthesisFailed
    /// A phoneme segment exceeded KokoroAne's ~510-phoneme per-call limit. `KokoroTTSBackend`
    /// splits long-form text with `KokoroPhonemeChunker` (hard maximum
    /// `KokoroAneConstants.maxPhonemeLength`) before synthesis, so this indicates an unexpected
    /// segment rather than long input; it maps to `SpeechBackendError.inferenceFailed`, which the
    /// router treats as fallback-worthy.
    case textTooLong
    /// A phoneme-safe segment still exceeded Kokoro's baked acoustic-frame cap. Long-form
    /// synthesis may split this specific size failure further; generic inference failures are
    /// never retried as though they were length failures.
    case acousticFramesTooLong

    /// Maps a FluidAudio synthesis failure. `CancellationError` passes through unchanged.
    static func synthesis(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: error
        case KokoroAneError.phonemeSequenceTooLong: KokoroEngineError.textTooLong
        case KokoroAneError.acousticFramesExceedCap: KokoroEngineError.acousticFramesTooLong
        default: KokoroEngineError.synthesisFailed
        }
    }
}

typealias KokoroModel = LocalModel<any KokoroModelSession>

extension LocalModel where Session == any KokoroModelSession {
    /// The Kokoro 82M ANE model (FluidAudio's 7-stage CoreML chain), run entirely on-device.
    ///
    /// **There is no network-free load path in FluidAudio's KokoroAne API.** `KokoroAneManager`'s
    /// `initialize()` downloads any missing models before loading. The hand-rolled
    /// `modelsArePresent()` gate on a local-only load is therefore the primary protection against
    /// reaching the network. It must cover every asset `initialize()` can download - the ANE chain
    /// and the shared G2P assets (see `FluidAudioKokoroModelLoader.modelsArePresent()`).
    static func kokoro(loader: (any KokoroModelLoading)? = nil) -> Self {
        let loader = loader ?? FluidAudioKokoroModelLoader(cacheDirectory: kokoroCacheDirectory())
        let logger = Logger.relay("kokoro")
        return LocalModel(
            isPresent: { await loader.modelsArePresent() },
            loader: ModelSessionLoader(
                modelsNotDownloaded: { KokoroEngineError.modelsNotDownloaded },
                mapLoadFailure: { _ in
                    logger.debug("Kokoro model load failed")
                    return KokoroEngineError.loadFailed
                },
                validateLocal: { await loader.modelsArePresent() },
                loadLocal: { try await loader.loadLocal() },
                downloadAndLoad: { progress in try await loader.downloadAndLoad(progress: progress) }
            ),
            removal: Removal(deleteFiles: { try await loader.removeModels() }, filesRemain: KokoroEngineError.loadFailed)
        )
    }

    /// The directory `KokoroAneManager`/`KokoroAneResourceDownloader` treat as their "Models"
    /// root - i.e. what gets passed as their `directory:` parameter directly, with no further
    /// path segment appended by Relay. Mirrors `KokoroAneResourceDownloader`'s own default
    /// (`TtsCacheDirectory.ensure()/Models`) so a caller that doesn't override the loader gets
    /// the exact same on-disk location FluidAudio would pick on its own.
    private static func kokoroCacheDirectory() -> URL {
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
    /// `LocalModel.kokoroCacheDirectory()`.
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
    /// default is exactly what `LocalModel.kokoroCacheDirectory()` passes as
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
/// `KokoroAneManager` is a `public actor` - already `Sendable` and self-serializing - so this
/// needs no acquire/release wrapping to keep concurrent calls from interleaving inside it.
private struct KokoroAneManagerSession: KokoroModelSession {
    let manager: KokoroAneManager

    func phonemes(for text: String) async throws -> String {
        do {
            return try await manager.phonemes(for: text)
        } catch {
            throw KokoroEngineError.synthesis(error)
        }
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        do {
            let result = try await manager.synthesizeFromPhonemesDetailed(phonemes, voice: voice, speed: speed)
            return KokoroPCM(samples: result.samples, sampleRate: Double(result.sampleRate))
        } catch {
            throw KokoroEngineError.synthesis(error)
        }
    }
}
