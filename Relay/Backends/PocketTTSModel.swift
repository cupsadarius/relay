import FluidAudio
import Foundation
import os

/// A loaded PocketTTS model, ready to synthesize speech.
protocol PocketTTSModelSession: Sendable {
    /// Streams synthesized audio as raw Float32 frames, so playback can start before synthesis
    /// finishes. Each frame is 1920 samples (80ms) at `PocketTtsConstants.audioSampleRate`
    /// (24kHz), matching FluidAudio's `PocketTtsSynthesizer.AudioFrame`.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
}

/// Wraps FluidAudio's `PocketTtsManager`/`PocketTtsResourceDownloader` calls so the PocketTTS load
/// path can be exercised in tests without constructing real CoreML models.
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

/// PocketTTS load failures. `PocketTTSBackend` maps these onto `SpeechBackendError`. Deliberately
/// carries no reason strings: TTS failures must never end up logged or diagnosed with raw error
/// text, per the privacy rule.
enum PocketTTSEngineError: Error, Equatable, Sendable {
    /// The model was not present on disk and the caller did not allow a download.
    case modelsNotDownloaded
    /// Loading (or downloading) the model failed for a reason other than the model being absent.
    case loadFailed
    case synthesisFailed
}

typealias PocketTTSModel = LocalModel<any PocketTTSModelSession>

extension LocalModel where Session == any PocketTTSModelSession {
    /// FluidAudio's PocketTTS CoreML model, run entirely on-device.
    ///
    /// **There is no network-free load path in FluidAudio's PocketTTS API.**
    /// `PocketTtsManager.initialize()` downloads any missing models before loading. The hand-rolled
    /// `modelsArePresent()` gate on a local-only load is therefore the ONLY protection against
    /// reaching the network - there is no way to close that gap further without patching FluidAudio.
    static func pocketTTS(loader: (any PocketTTSModelLoading)? = nil) -> Self {
        let loader = loader ?? FluidAudioPocketTTSModelLoader(cacheDirectory: pocketTTSCacheDirectory())
        let logger = Logger.relay("pocket-tts")
        return LocalModel(
            isPresent: { await loader.modelsArePresent() },
            loader: ModelSessionLoader(
                modelsNotDownloaded: { PocketTTSEngineError.modelsNotDownloaded },
                mapLoadFailure: { _ in
                    logger.debug("PocketTTS model load failed")
                    return PocketTTSEngineError.loadFailed
                },
                validateLocal: { await loader.modelsArePresent() },
                loadLocal: { try await loader.loadLocal() },
                downloadAndLoad: { progress in try await loader.downloadAndLoad(progress: progress) }
            ),
            removal: Removal(deleteFiles: { try await loader.removeModels() }, filesRemain: PocketTTSEngineError.loadFailed)
        )
    }

    private static func pocketTTSCacheDirectory() -> URL {
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

/// Adapts FluidAudio's PocketTTS frame stream to raw sample arrays without an intermediate buffer
/// or task: each pull on the returned stream pulls exactly one upstream element. FluidAudio's
/// generator still runs ahead into its own unbounded buffer (its `makeStream` yields from an eager
/// task and `yield` never suspends), so this cannot throttle synthesis itself. It removes Relay's
/// second copy and forwarding task; the bounded `TTSAudioPipe` downstream bounds what Relay holds.
enum PocketTTSFrameStream {
    static func samples<Element>(
        from upstream: AsyncThrowingStream<Element, Error>,
        transform: @escaping @Sendable (Element) -> [Float]
    ) -> AsyncThrowingStream<[Float], Error> {
        let iterator = IteratorBox(upstream.makeAsyncIterator())
        return AsyncThrowingStream(unfolding: {
            guard let element = try await iterator.next() else { return nil }
            return transform(element)
        })
    }

    /// The upstream iterator is not `Sendable`. `AsyncThrowingStream(unfolding:)` calls its
    /// closure serially from the single consumer, so the box is never accessed concurrently.
    private final class IteratorBox<Element>: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Element, Error>.Iterator

        init(_ iterator: AsyncThrowingStream<Element, Error>.Iterator) {
            self.iterator = iterator
        }

        func next() async throws -> Element? {
            try await iterator.next()
        }
    }
}

/// Wraps FluidAudio's `PocketTtsManager`, an `actor`, so concurrent calls into it are serialized
/// by Swift itself.
private struct PocketTtsManagerSession: PocketTTSModelSession {
    let manager: PocketTtsManager

    /// Adapts FluidAudio's `AudioFrame` stream down to raw samples, pulling lazily (see
    /// `PocketTTSFrameStream`). Cancelling the consumer drops the upstream iterator, which ends
    /// FluidAudio's stream and cancels its generator task.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let frames = try await manager.synthesizeStreaming(text: text, voice: voice)
        return PocketTTSFrameStream.samples(from: frames) { $0.samples }
    }
}
