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

/// Owns the single heavyweight Whisper inference context Relay ever keeps resident.
///
/// Every change of the resident model is one *transition* (activate to an id, or unload to `nil`).
/// At most one transition runs at a time:
/// - A caller that asks for the transition already in flight joins it, so a concurrent interim
///   tick and final transcription load a model once instead of leaking a second multi-GB context.
/// - A caller that asks for a different target waits for the running transition, then re-checks.
///
/// A transition unloads the current context strictly before loading the replacement, and first
/// waits until no `transcribe` is still using that context. `loaded` is assigned only after a
/// load succeeds, so a failed load leaves nothing resident.
actor WhisperRuntime {
    private struct Transition {
        let target: WhisperModelID?
        let token: UUID
        let task: Task<Void, Error>
    }

    private let engine: any WhisperEngine
    private let modelFolder: @Sendable (WhisperModelID) -> URL
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "whisper")

    private var loaded: (id: WhisperModelID, context: any LoadedWhisperContext)?
    private var inFlightTransition: Transition?
    private var activeTranscriptions = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// The currently-loaded model, if any. `nil` before any activation, after a failed one, after
    /// `unload()`, and while a transition is between unloading the old model and loading the new.
    var currentModelID: WhisperModelID? {
        loaded?.id
    }

    init(engine: any WhisperEngine, modelFolder: @escaping @Sendable (WhisperModelID) -> URL) {
        self.engine = engine
        self.modelFolder = modelFolder
    }

    /// Makes `id` the active model. A no-op if `id` is already active; joins an in-flight
    /// activation of `id`. Throws the load error if loading fails, leaving nothing loaded.
    func activate(_ id: WhisperModelID) async throws {
        try await transition(to: id)
    }

    /// Transcribes with the active model. Throws `WhisperRuntimeError.notLoaded` if none is
    /// active. The context counts as in use until this returns, so no transition unloads it
    /// underneath the call.
    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        guard let loaded else {
            throw WhisperRuntimeError.notLoaded
        }
        activeTranscriptions += 1
        defer {
            activeTranscriptions -= 1
            if activeTranscriptions == 0 {
                let waiters = drainWaiters
                drainWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await loaded.context.transcribe(samples, options: options)
    }

    /// Unloads the active model once in-flight transcriptions finish. Waits for (and then
    /// undoes) an in-flight activation. A no-op if nothing is loaded.
    func unload() async {
        try? await transition(to: nil)
    }

    private func transition(to target: WhisperModelID?) async throws {
        while true {
            if inFlightTransition == nil, loaded?.id == target {
                return
            }
            guard let inFlight = inFlightTransition else { break }
            if inFlight.target == target {
                try await inFlight.task.value
            } else {
                _ = try? await inFlight.task.value
            }
            // Re-evaluate: another transition may have started while this caller waited.
        }

        let token = UUID()
        let task = Task { try await self.performTransition(to: target, token: token) }
        inFlightTransition = Transition(target: target, token: token, task: task)
        try await task.value
    }

    private func performTransition(to target: WhisperModelID?, token: UUID) async throws {
        // Cleared here, on the actor, before the task completes - so every waiter that resumes
        // from `task.value` already sees no transition in flight and cannot spin on a stale one.
        defer {
            if inFlightTransition?.token == token {
                inFlightTransition = nil
            }
        }

        if let current = loaded {
            loaded = nil
            await waitForActiveTranscriptions()
            await current.context.unload()
            logger.debug("Whisper model unloaded")
        }

        guard let target else { return }
        let context = try await engine.load(modelFolder: modelFolder(target))
        loaded = (id: target, context: context)
        logger.debug("Whisper model activated")
    }

    private func waitForActiveTranscriptions() async {
        while activeTranscriptions > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
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
/// one real activation with the network genuinely disabled before relying on Whisper being fully
/// offline in production.
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
