import Foundation
import os

// SPIKE: best-effort live interim transcription for the dictation pill, layered on top of the
// existing batch sttRouter.transcribe path -- it never replaces it. Interim text is
// display-only; the authoritative transcript that actually gets inserted always comes from a
// separate, later call to that same batch path once the user stops speaking.
//
// Revision history (see the spike findings doc for the full writeup):
// The first version of this type drove interim updates from FluidAudio's low-level
// AsrManager.transcribeStreamingChunk, called once per small (about 0.75s) raw audio chunk, with
// token-to-text decoding done by hand. Live testing showed it rendered exactly one update
// ("Mm-hmm.") and then froze for the rest of the utterance, and per-chunk accuracy was poor
// besides. The most likely cause: unlike FluidAudio's own StreamingAsrManager, this fed the
// decoder disjoint, non-overlapping, context-free windows with no per-window frame or
// left-context bookkeeping, and transcribeStreamingChunk's persisted decoder state has
// invariants tied to that machinery -- the second call onward most likely started throwing (or
// returning empty token arrays) against the same decoder state the first call left behind, and
// every error was caught and merely logged at debug level, which is why it read as a silent
// freeze rather than a crash. That path did not need FluidAudio's streaming API to be worth it
// (see below), so it was not root-caused further -- it was simply replaced with an approach that
// reuses the already accurate, already-tested batch decoder instead of a second, fragile decode
// path.
//
// Current approach: periodic growing-window re-transcribe.
// Every tickInterval (about 1s), snapshot however much audio has arrived so far and re-run the
// exact same accurate batch transcription used for the final result (transcribe, injected by the
// caller, in practice STTRouter.transcribe, so this reuses whichever backend and model is already
// loaded for the session rather than loading a second copy of anything). Each call is
// independent and stateless (AsrManager's plain batch transcribe resets decoder state per call,
// unlike the streaming-chunk API above), so there is no persisted-state invariant to violate, and
// quality is the same as the final result would be for that much audio -- the interim text
// degrades gracefully to "slightly stale" rather than "wrong in a new way" each second. The
// trade-off is CPU: re-transcribing a growing buffer from scratch every tick is roughly quadratic
// over the length of an utterance, so the buffer used for the interim snapshot is capped to the
// most recent maxWindowSamples (about 15s) -- for anything shorter than that the window is
// genuinely the whole utterance so far; beyond it, interim quality is based on a rolling last-15s
// window instead. This cap applies to interim display only: the authoritative final transcript is
// produced separately, from MicrophoneCapture's own full, uncapped accumulator.
actor StreamingTranscriber {
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "streaming-transcriber")
    // How often the tick loop re-transcribes. Injectable (default about 1s) so tests can drive a
    // fast loop instead of waiting on real wall-clock time.
    private let tickInterval: Duration
    // Caps the interim snapshot to the most recent window of audio (16 kHz mono Float, default
    // about 15s). Injectable so tests can exercise the rolling-window trim with a small buffer.
    private let maxWindowSamples: Int

    // Injected rather than hard-coded to a specific backend so this stays provider-agnostic and
    // reuses whatever model the caller already has loaded (in practice STTRouter.transcribe,
    // MainActor-isolated -- calling it from this actor is a plain await hop, no Sendable
    // requirement on the router itself since the closure carries the isolation with it).

    private let transcribe: @MainActor (AudioInput) async throws -> Transcript
    private let onInterimText: @Sendable (String) -> Void

    private var samples: [Float] = []
    private var isTranscribing = false
    private var tickTask: Task<Void, Never>?

    init(
        tickInterval: Duration = .seconds(1),
        maxWindowSamples: Int = 15 * 16_000,
        transcribe: @escaping @MainActor (AudioInput) async throws -> Transcript,
        onInterimText: @escaping @Sendable (String) -> Void
    ) {
        self.tickInterval = tickInterval
        self.maxWindowSamples = maxWindowSamples
        self.transcribe = transcribe
        self.onInterimText = onInterimText
    }

    // Starts a fresh interim session: clears any leftover state and begins the about-1s tick
    // loop. Cheap and synchronous aside from the actor hop -- there is no model loading here
    // anymore, so (unlike the previous per-chunk version) there is no window where early samples
    // are lost while something loads in the background.
    func start() {
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        tickTask?.cancel()
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    // Feeds a batch of raw 16 kHz mono Float samples -- the exact format MicrophoneCapture
    // already produces for its own accumulator, so no conversion happens here. Purely
    // accumulates; the actual re-transcription happens on the tick loop, not per call.
    func appendSamples(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        if samples.count > maxWindowSamples {
            samples.removeFirst(samples.count - maxWindowSamples)
        }
    }

    // Stops the tick loop and clears buffered audio. Interim text is display-only, so this
    // deliberately does not return anything -- the authoritative transcript comes from a
    // separate call to the batch path instead.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
    }

    // One tick of the periodic re-transcribe. DEBOUNCE: if a previous tick's transcription is
    // still in flight, this tick is skipped outright rather than queuing -- there is deliberately
    // never more than one transcription in flight at a time.
    private func tick() async {
        guard !isTranscribing, !samples.isEmpty else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        let snapshot = samples
        do {
            let result = try await transcribe(AudioInput(samples: snapshot, sampleRate: 16_000))
            guard !Task.isCancelled else { return }
            onInterimText(result.text)
        } catch is CancellationError {
        } catch {
            logger.debug("Streaming transcriber tick failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
