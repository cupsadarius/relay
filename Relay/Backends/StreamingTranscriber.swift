import FluidAudio
import Foundation
import os

/// SPIKE: best-effort *live* interim transcription for the dictation pill, layered on top of the
/// existing batch `sttRouter.transcribe(...)` path — it never replaces it. Interim text is
/// display-only; the authoritative transcript that actually gets inserted always comes from the
/// batch path once the user stops speaking.
///
/// ## Why this exists instead of reusing FluidAudio's own `StreamingAsrManager`
/// FluidAudio 0.12.6 ships a higher-level `StreamingAsrManager` that already turns
/// `AsrManager.transcribeStreamingChunk`'s token ids into text. It was the first thing tried here,
/// but it only emits an update once per `chunkSeconds` window (10-15s, even with the `.streaming`
/// preset) — its `hypothesisChunkSeconds` "quick feedback" knob exists in `StreamingAsrConfig` but
/// is dead: `appendSamplesAndProcess`/`processWindow` never read it in this version. That cadence
/// would make the pill sit empty for the first ~10+ seconds of every utterance, which defeats the
/// point of a *live* pill. So this type hand-rolls the same "Path A" FluidAudio itself uses
/// internally, at a much shorter, tunable step size:
///
/// 1. Feed small, non-overlapping windows of raw mic samples (`stepSampleCount`, ~0.75s) to the
///    public `AsrManager.transcribeStreamingChunk(_:source:previousTokens:isLastChunk:)`. Its
///    decoder state persists across calls per `source`, so consecutive windows continue decoding
///    where the previous one left off without needing to be re-fed as context.
/// 2. Convert the returned token ids to text ourselves via `AsrModels.vocabulary` (`[Int: String]`,
///    public), replicating `AsrManager`'s own (module-`internal`, hence inaccessible here)
///    `convertTokensWithExistingTimings`: join each token's string, replace the SentencePiece word
///    boundary marker "▁" with a space, then trim. Confirmed by reading that method's source.
///
/// This runs on its own `AsrManager`/`AsrModels` pair, loaded from the same on-disk cache
/// `FluidAudioParakeetEngine` already uses (no extra download — the model is already present) but
/// **not** the same in-memory instance, so this doubles the Parakeet model's memory footprint for
/// as long as a streaming session is active. Acceptable for a spike; a production version should
/// share one loaded `AsrModels` between the batch engine and this type instead. See the spike
/// findings doc for the full list of production follow-ups.
actor StreamingTranscriber {
    private static let version: AsrModelVersion = .v2
    /// ~0.75s of 16 kHz audio per step: short enough to feel live, long enough for the TDT decoder
    /// to produce a reasonable hypothesis. Chunks are fed *without* overlap and without re-passing
    /// `previousTokens`, so there is nothing to de-duplicate between steps — the persisted decoder
    /// state alone is what makes each step continue the same utterance.
    private static let stepSampleCount = 12_000

    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "streaming-transcriber")
    private let onInterimText: @Sendable (String) -> Void

    private var manager: AsrManager?
    private var vocabulary: [Int: String] = [:]
    private var pendingSamples: [Float] = []
    private var accumulatedTokens: [Int] = []
    private var isProcessingStep = false
    /// Set once `start()` has determined the models aren't available locally (or failed to load),
    /// so every subsequent `appendSamples` call can no-op immediately instead of retrying.
    private var isDisabled = false

    init(onInterimText: @escaping @Sendable (String) -> Void) {
        self.onInterimText = onInterimText
    }

    /// Best-effort: any failure here (models not downloaded, load failure, ...) silently disables
    /// interim text for this session. It never throws — the caller's dictation flow must never be
    /// affected by this being unavailable.
    func start() async {
        manager = nil
        vocabulary = [:]
        pendingSamples.removeAll(keepingCapacity: true)
        accumulatedTokens.removeAll(keepingCapacity: true)
        isDisabled = false

        let modelDirectory = AsrModels.defaultCacheDirectory(for: Self.version)
        guard AsrModels.modelsExist(at: modelDirectory, version: Self.version) else {
            logger.debug("Streaming transcriber disabled: Parakeet models not present locally")
            isDisabled = true
            return
        }

        do {
            let models = try await AsrModels.load(from: modelDirectory, version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.manager = manager
            self.vocabulary = models.vocabulary
        } catch is CancellationError {
            isDisabled = true
        } catch {
            logger.debug("Streaming transcriber failed to start: \(error.localizedDescription, privacy: .private)")
            isDisabled = true
        }
    }

    /// Feeds a batch of raw 16 kHz mono Float samples — the exact format `MicrophoneCapture`
    /// already produces for its own accumulator, so no conversion happens here. Buffers samples
    /// until `stepSampleCount` is reached, then transcribes that window in the background. Steps
    /// never overlap: if a step is still in flight when more samples arrive, they simply keep
    /// buffering for the next step rather than spawning concurrent decodes against the same
    /// decoder state.
    func appendSamples(_ samples: [Float]) async {
        guard !isDisabled, let manager else { return }
        pendingSamples.append(contentsOf: samples)
        guard !isProcessingStep, pendingSamples.count >= Self.stepSampleCount else { return }

        let step = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        isProcessingStep = true
        defer { isProcessingStep = false }

        do {
            let (tokens, _, _, _) = try await manager.transcribeStreamingChunk(
                step,
                source: .microphone,
                previousTokens: [],
                isLastChunk: false
            )
            guard !tokens.isEmpty else { return }
            accumulatedTokens.append(contentsOf: tokens)
            onInterimText(Self.decode(tokens: accumulatedTokens, vocabulary: vocabulary))
        } catch is CancellationError {
        } catch {
            logger.debug("Streaming transcriber step failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Tears down the session. Interim text is display-only, so this deliberately does not return
    /// anything — the authoritative transcript comes from `sttRouter.transcribe(...)` instead.
    func stop() async {
        manager = nil
        vocabulary = [:]
        pendingSamples.removeAll(keepingCapacity: true)
        accumulatedTokens.removeAll(keepingCapacity: true)
        isProcessingStep = false
        isDisabled = false
    }

    /// Mirrors `AsrManager.convertTokensWithExistingTimings`'s text-assembly step exactly (that
    /// method itself is module-`internal` and so isn't callable from here): join each token's
    /// vocabulary string, replace the SentencePiece word-boundary marker with a space, then trim.
    private static func decode(tokens: [Int], vocabulary: [Int: String]) -> String {
        let joined = tokens.compactMap { vocabulary[$0] }.joined()
        return joined.replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
