import Foundation
import WhisperKit
import os

/// The seam between `WhisperRuntime` and however inference actually happens (a live WhisperKit
/// context in production, a fake in tests). A `WhisperEngine` is trusted only to load an
/// already-verified local model folder -- it never downloads anything (`WhisperModelStore` owns
/// that) and never decides which model should be active (`WhisperRuntime` owns that).
protocol WhisperEngine: Sendable {
    /// Loads the model at `modelFolder` (a fully verified, already-on-disk directory -- see
    /// `WhisperModelStore.modelDirectory(for:)`) and returns a context ready to transcribe.
    /// Throws if the load fails; on a throw, the caller must not treat any context as loaded.
    func load(modelFolder: URL) async throws -> any LoadedWhisperContext
}

/// One loaded Whisper inference context, holding whatever heavyweight CoreML state a load
/// produced. `WhisperRuntime` guarantees at most one `LoadedWhisperContext` is resident at a
/// time, calling `unload()` before ever loading a replacement.
protocol LoadedWhisperContext: Sendable {
    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String
    func unload() async
}

/// Errors `WhisperRuntime` itself throws (as opposed to a `WhisperEngine`'s own load/transcribe
/// errors, which propagate unchanged).
enum WhisperRuntimeError: Error, Equatable, Sendable {
    /// `transcribe` was called with no model activated (or the last `activate` failed).
    case notLoaded
}

/// Owns the single heavyweight Whisper inference context Relay ever keeps resident, guaranteeing
/// at most one model is loaded at a time. `activate` switches models by unloading whatever is
/// currently loaded (if different) *before* loading the replacement, so a load failure never
/// leaves two contexts resident and never leaves a stale context masquerading as the active one:
/// `loaded` is only assigned once the new context's load has actually succeeded.
///
/// An `actor` because the loaded context is mutable state shared between `activate` and
/// `transcribe` calls that may arrive from different tasks (e.g. a model-picker UI switching
/// models while a previous transcription is still in flight).
actor WhisperRuntime {
    private let engine: any WhisperEngine
    private let modelFolder: @Sendable (WhisperModelID) -> URL
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "whisper")

    private var loaded: (id: WhisperModelID, context: any LoadedWhisperContext)?

    /// The currently-loaded model, if any. `nil` whenever no model has been activated yet, the
    /// last `activate` failed, or `unload()` was called. Lets other components (e.g.
    /// `WhisperModelManager`) decide whether a model switch or removal needs to unload first,
    /// without duplicating `WhisperRuntime`'s own
    /// loaded-state bookkeeping.
    var currentModelID: WhisperModelID? {
        loaded?.id
    }

    /// - Parameters:
    ///   - engine: the seam to a real (or fake) inference backend.
    ///   - modelFolder: resolves a `WhisperModelID` to the local directory its verified files
    ///     live in -- in production, `WhisperModelStore.modelDirectory(for:)`.
    init(engine: any WhisperEngine, modelFolder: @escaping @Sendable (WhisperModelID) -> URL) {
        self.engine = engine
        self.modelFolder = modelFolder
    }

    /// Makes `id` the active model. A no-op if `id` is already active. Otherwise, unloads
    /// whatever is currently loaded (strictly before loading `id`), then loads `id`. If the load
    /// throws, `loaded` is left `nil` -- never the old context, never a half-initialized new one.
    func activate(_ id: WhisperModelID) async throws {
        if let loaded, loaded.id == id {
            return
        }

        if let current = loaded {
            await current.context.unload()
            loaded = nil
        }

        let context = try await engine.load(modelFolder: modelFolder(id))
        loaded = (id: id, context: context)
        logger.debug("Whisper model activated")
    }

    /// Transcribes `samples` using the currently active model. Throws `WhisperRuntimeError
    /// .notLoaded` if no model is active (nothing activated yet, or the last `activate` failed).
    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        guard let loaded else {
            throw WhisperRuntimeError.notLoaded
        }
        return try await loaded.context.transcribe(samples, options: options)
    }

    /// Unloads the active model, if any. A no-op if nothing is loaded.
    func unload() async {
        guard let current = loaded else {
            return
        }
        await current.context.unload()
        loaded = nil
        logger.debug("Whisper model unloaded")
    }
}

/// Live `WhisperEngine` backed by WhisperKit. Always constructs with `download: false` --
/// `WhisperModelStore` is solely responsible for fetching and verifying model files; this type
/// only ever loads an already-verified local folder.
///
/// `tokenizerFolder: modelFolder` is passed alongside `modelFolder` so the local `tokenizer.json`
/// `WhisperModelStore`/`HuggingFaceWhisperDownloader` now fetch+verify into the model folder
/// (colocated with the `.mlmodelc` bundle -- see `WhisperKitContext`'s doc comment below) is found
/// by WhisperKit's local-first tokenizer search without any further code change here.
struct WhisperKitEngine: WhisperEngine {
    func load(modelFolder: URL) async throws -> any LoadedWhisperContext {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelFolder,
            load: false,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        try await whisperKit.loadModels()
        return WhisperKitContext(whisperKit: whisperKit)
    }
}

/// Live `LoadedWhisperContext` wrapping one `WhisperKit` instance.
///
/// `@unchecked Sendable`: WhisperKit's own type does not conform to `Sendable`, but every call
/// into it here is `await`-ed and `WhisperRuntime` (an actor) only ever holds one
/// `LoadedWhisperContext` at a time and never accesses it concurrently, so there is no actual
/// shared-mutable-state hazard -- only a missing annotation upstream.
///
/// GAP CLOSED (previously "CONFIRMED GAP" here; verified against the resolved WhisperKit 1.1.0
/// source -- `WhisperKit.swift`'s `loadTokenizerIfNeeded()`, `ModelUtilities.loadTokenizer`, and
/// `ArgmaxCore`'s `LanguageModelConfigurationFromHub.loadConfig(modelFolder:)`/
/// `AutoTokenizer.from(modelFolder:)`): a Whisper model's first `activate()` used to NOT be fully
/// offline, because `WhisperKitConfig(download: false)` only gates the MODEL WEIGHTS path
/// (`WhisperKit.setupModels`) -- `loadTokenizerIfNeeded()` never checks it -- and
/// `argmaxinc/whisperkit-coreml`'s per-model runtime-artifact folders never carried a
/// `tokenizer.json`, so WhisperKit's local-first tokenizer search (which checks `modelFolder`
/// second, per the `tokenizerFolder: modelFolder` passed above) always missed and fell back to a
/// live fetch from a SEPARATE Hugging Face repo per model family (`WhisperModelDescriptor
/// .tokenizerRepo`, resolved the same way `ModelUtilities.tokenizerNameForVariant` does).
/// `WhisperModelStore`/`HuggingFaceWhisperDownloader` now also fetch+verify `tokenizer.json` and
/// `tokenizer_config.json` from that repo into the model folder before a model is ever considered
/// downloaded (`WhisperModelStore.requiredTokenizerFileName`/`WhisperModelStoreError
/// .missingTokenizer`), so `modelFolder/tokenizer.json` exists by the time `activate()` runs and
/// this file's `tokenizerFolder: modelFolder` resolves it locally -- no further code change here.
/// A model downloaded before this change lacks the tokenizer files and must be re-downloaded (its
/// `.verified` manifest won't list them, so `presence(of:)` now correctly reports it as not
/// downloaded). This closes the gap for any NEWLY downloaded model; the owner should still verify
/// one real activation with the network genuinely disabled before relying on `.fullyOffline` in
/// `WhisperBackend.capabilities` in production.
struct WhisperKitContext: LoadedWhisperContext, @unchecked Sendable {
    private let whisperKit: WhisperKit

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        // `skipSpecialTokens: true` -- WhisperKit 1.1.0's `DecodingOptions` (`Configurations.swift`)
        // -- suppresses genuine `<|...|>` special tokens (e.g. `<|startoftranscript|>`) at the
        // source. It does NOT suppress bracketed non-speech markers like `[BLANK_AUDIO]`: those
        // aren't special tokens, they're ordinary word tokens the model itself decodes for
        // silence/noise segments. `WhisperTranscriptCleanup.clean` below is the defensive,
        // conservative strip for both -- see its doc comment.
        let decodeOptions = DecodingOptions(skipSpecialTokens: true)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: decodeOptions)
        let joined = results.map(\.text).joined()
        return WhisperTranscriptCleanup.clean(joined)
    }

    func unload() async {
        await whisperKit.unloadModels()
    }
}
