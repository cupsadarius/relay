# Live Transcription Spike - Findings

**Date:** 2026-09-16
**Status:** Spike complete, revised after a live test found the first approach broken

## 1. Goal

Prove that Relay dictation pill can show rolling interim transcription text while the user is
still speaking, then finalize with the existing authoritative batch transcript
(sttRouter.transcribe) on stop, without disturbing the existing batch dictation path.

## 2. Summary of the two approaches tried

Two approaches were built and tested in this spike, in order:

1. Per-chunk streaming decode (AsrManager.transcribeStreamingChunk). Built, compiled, tests
   passed -- but live testing showed it rendered exactly one interim update ("Mm-hmm.") and then
   froze for the rest of the utterance, and per-chunk accuracy was poor anyway. Replaced.
2. Periodic growing-window re-transcribe (current). Every ~1s, re-runs the same accurate batch
   transcribe used for the final result over whatever audio has accumulated so far. This is what
   ships from this spike.

Both are described in full below, since the first attempt's failure and diagnosis are relevant to
anyone touching this code later.

## 3. Attempt 1: per-chunk streaming decode (replaced)

Three FluidAudio options were on the table going in: Path A
(AsrManager.transcribeStreamingChunk plus hand-rolled token-to-text decoding), Path B
(StreamingEouAsrManager, which downloads a separate parakeetEou model), and a third option found
while reading FluidAudio 0.12.6 source, its own higher-level StreamingAsrManager.

StreamingAsrManager was tried first and rejected before writing any code against it: reading
StreamingAsrManager appendSamplesAndProcess and processWindow in
.derived-data/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift
showed it only emits an update once per chunkSeconds window, 10 to 15 seconds, even with the
shipped .streaming preset. Its hypothesisChunkSeconds "quick feedback" knob is documented but dead
code in this version.

Path A was chosen and built: AsrManager.transcribeStreamingChunk is public, and reading
AsrManager.convertTokensWithExistingTimings (internal, so not callable from Relay) showed its
token-to-text algorithm is just three steps (join each token's vocabulary string, replace the
SentencePiece word-boundary marker with a space, trim), reproducible using the public
AsrModels.vocabulary dictionary with no separate Tokenizer class or vocab-file path guessing.
Path B was not needed.

This built cleanly and passed the full test suite, but live testing (by the person driving this
spike, not by this agent -- see section 8) found it rendered exactly one interim update
("Mm-hmm.") and then froze, with poor accuracy in that one update besides.

Most likely cause of the freeze (not root-caused further, since the whole approach was replaced
rather than debugged in place): unlike FluidAudio's own StreamingAsrManager, the replaced code fed
the decoder disjoint, non-overlapping, context-free ~0.75s windows with no per-window frame or
left-context bookkeeping, while still relying on transcribeStreamingChunk's persisted
per-AudioSource decoder state across calls. That state's invariants are almost certainly tied to
the windowing/frame-alignment machinery StreamingAsrManager itself provides around it. The second
call onward most likely started throwing (or returning empty token arrays) against the decoder
state the first call left behind; every error was caught and only logged at debug level, which is
exactly why it read as a silent freeze rather than a visible crash.

## 4. Attempt 2 (current): periodic growing-window re-transcribe

Every ~1 second (tickInterval), StreamingTranscriber snapshots however much 16 kHz mono audio has
accumulated since the current utterance started and re-runs the exact same accurate batch
transcription the final result uses (a transcribe closure injected by the caller; in
DictationCoordinator this closure calls sttRouter.transcribe, the same call runProcessingPipeline
makes for the final result), then reports the result as the new interim text.

Why this fixes both problems from attempt 1:

- No freeze: each tick's call is a fresh, independent, stateless batch transcription (the plain
  batch AsrManager.transcribe resets decoder state per call, unlike the streaming-chunk API), so
  there is no persisted decoder state whose invariants can be violated across calls. If one tick's
  call fails, the next tick's call is unrelated and unaffected.
- Better accuracy: every tick decodes the same accurate path the final result uses, over a window
  that is the whole utterance so far (up to the cap described below), rather than an isolated
  0.75s fragment with no context. Interim text should read as "an accurate transcript of what has
  been said so far, occasionally a second stale," rather than "wrong in a new way every chunk."

Debounce: a per-actor isTranscribing boolean guard means a tick that fires while the previous
tick's transcription is still in flight is skipped outright rather than queued -- there is
deliberately never more than one transcription running at a time.

Reuse instead of a second loaded model: the transcribe closure is injected by DictationCoordinator
as sttRouter.transcribe, so interim ticks reuse whichever backend and model the session's final
transcription will use, with no separate AsrManager/AsrModels instance loaded for interim
purposes. (Attempt 1 did load its own separate AsrModels/AsrManager pair, duplicating memory; that
concern is now moot; see section 6.)

CPU cap: re-transcribing a growing buffer from scratch every tick is roughly quadratic in the
length of an utterance if left unbounded. StreamingTranscriber caps the buffer it keeps to the
most recent ~15s of audio (maxWindowSamples), dropping older samples as new ones arrive past that
point. For anything under 15s -- most dictation utterances -- the interim window is genuinely the
whole utterance so far; beyond 15s, interim quality is based on a rolling last-15s window instead.
This cap applies to interim display only: the authoritative final transcript still comes from
MicrophoneCapture's own separate, uncapped accumulator, untouched by any of this.

## 5. What was built (current state)

- Relay/Backends/StreamingTranscriber.swift (actor, rewritten from attempt 1): owns a growing
  (capped to ~15s) sample buffer, an about-1s tick loop implemented as a simple
  Task-plus-Task.sleep while-loop (no FluidAudio import at all now -- it is provider-agnostic),
  an isTranscribing debounce guard, and a caller-supplied transcribe closure
  (@MainActor (AudioInput) async throws -> Transcript) plus an onInterimText callback. start()
  resets state and begins ticking; appendSamples buffers (and trims) incoming audio; stop() cancels
  the tick loop and clears state; tick() is the debounced, one-at-a-time re-transcribe step. Fully
  best-effort: a failed tick is logged at debug level and simply skipped, never surfaced.
- Relay/SpeechIn/MicrophoneCapture.swift: unchanged from the previous revision of this spike. Still
  exposes the optional MicrophoneSampleStreaming protocol (setSampleObserver) alongside the
  existing accumulate-plus-level path, deliberately separate from MicrophoneCapturing so no
  existing fake or test needs to implement it.
- Relay/SpeechIn/DictationCoordinator.swift: beginStreamingTranscription now constructs
  StreamingTranscriber with a transcribe closure that calls
  sttRouter.transcribe(audio:options:) (the exact call the final batch path also makes) instead of
  loading a second FluidAudio model. Everything else (creating a fresh transcriber per session,
  gating on the microphone implementing MicrophoneSampleStreaming, tearing it down in finish() and
  cancel(sessionID:) before the batch pipeline or cancellation proceeds, hopping the interim
  callback to the main actor) is unchanged from the previous revision.
- Relay/App/ActivityOverlayModel.swift and Relay/App/ActivityOverlayPresentation.swift: unchanged
  from the previous revision -- the interimText field on .listening/.processing and its rendering
  in the pill's interactive-layout subtitle do not depend on which transcription approach feeds
  them.
- RelayTests/SpeechIn/DictationCoordinatorTests.swift: unchanged from the previous revision (the
  no-op updateInterimText stub added there still applies). No test needed updating for the pivot
  itself: every existing microphone test fake deliberately does not implement
  MicrophoneSampleStreaming, so beginStreamingTranscription's guard already skips
  StreamingTranscriber entirely in the whole existing test suite, regardless of what
  StreamingTranscriber's internals do. There was nothing timer-driven under test to update.

## 6. Interim vs. final reconciliation

Unchanged in spirit from before, and simpler now: interim text is purely a
DictationActivityPublishing/pill concern; it never touches Transcript,
RulesTranscriptProcessor, or TextInserting. The batch path (microphone.stop, then
sttRouter.transcribe, then processor.process, then textInserter.insert) is completely
unmodified. stopStreamingTranscription() runs at the start of finish(), before the batch
pipeline's own Task is even created, cancelling the tick loop so no further interim call can
start; the two paths never race over what gets inserted, only over what the pill displays a
moment earlier. Because interim ticks now call the same sttRouter.transcribe the final call
uses, and STTRouter's cachedCandidateOrder field is consumed by whichever transcribe() call
happens to run next, an interim tick landing between the final backend-availability lookup and
the final transcribe call would consume that one-shot cache first; this is a minor, accepted
spike wrinkle (worst case, the final call re-probes backend availability instead of reusing a
cached selection) rather than a correctness problem -- see section 7.

## 7. Latency and quality feel

Not verified with a live microphone by this agent (see section 10: sandboxed agent, no audio
input; the coordinator ran the live test that found attempt 1 broken and will verify attempt 2).
By construction:

- First interim update should land roughly 1 second (tickInterval) after speech starts, using
  whatever audio has accumulated in that first second.
- Updates continue roughly every 1 second afterward, each one a fresh, complete re-transcription
  of the growing (capped) buffer -- so later updates should read as increasingly complete and
  accurate sentences, not accumulating small chunk-boundary errors the way attempt 1 did.
- A tick is skipped (not queued) if the previous tick is still transcribing, so on a slower machine
  or with a slower backend, updates may arrive somewhat less often than exactly once per second,
  but never overlap or race.
- Minor architectural wrinkle carried over from reusing STTRouter directly for interim: repeated
  availability polling of every configured backend once per tick, and the cachedCandidateOrder
  interaction noted in section 6. Neither breaks anything; both are spike-acceptable.

## 8. CPU and memory cost

No second AsrModels/AsrManager is loaded anymore -- interim ticks reuse whichever backend and
model sttRouter.transcribe already uses for the final result, so this pivot actually removed the
double-model-memory concern the first attempt had. The remaining cost is CPU: each tick re-runs a
full accurate batch transcription over up to ~15s of audio, once per second, for as long as the
user keeps talking. This is more total CPU work than attempt 1's small per-chunk decodes, in
exchange for correctness and accuracy; it was not benchmarked, and is the main thing worth
measuring before shipping this beyond a spike (see section 9).

## 9. What a production version would need

1. Measure and tune the CPU cost of re-transcribing a growing/rolling buffer once per second,
   especially on lower-power Macs; consider a longer tick interval, a shorter window cap, or
   throttling ticks once the buffer is long, if it turns out to be too hot.
2. A settings toggle plus graceful degradation UX. This spike is always-on with no user control.
3. Give interim ticks their own backend-selection path (or otherwise avoid sharing
   cachedCandidateOrder with the final call) so the two are fully independent rather than
   incidentally interacting through STTRouter's one-shot cache field (section 6).
4. Unit tests for StreamingTranscriber's tick loop, debounce, and windowing/cap logic (none were
   added here; spike scope, per the brief, and the type has no dependents in the existing test
   suite to update).
5. An end-to-end manual or automated verification with a real microphone, run inside this
   environment rather than only by a human tester -- this agent's environment has no audio input
   device (see section 10).

## 10. Verification performed and not performed

- xcodebuild build (including a clean build): BUILD SUCCEEDED, no new warnings from any changed
  or added file.
- xcodebuild test: TEST SUCCEEDED, 668 tests executed, 5 skipped (pre-existing), 0 failures, both
  before and after the pivot in this document.
- Launched the built Relay.app directly (open .../Relay.app) after both the original
  implementation and the pivot; each time it started, stayed running, and produced no new crash
  report in ~/Library/Logs/DiagnosticReports, then was quit cleanly.
- Not performed by this agent: speaking into a microphone and watching the pill update live. The
  original per-chunk approach was live-tested by the person driving this spike, who reported the
  freeze-after-one-update behavior that section 3 diagnoses and section 4 fixes; this agent's
  environment has no audio input device and no interactive GUI control, so the growing-window
  pivot's actual live behavior still needs the same kind of human (or automated-with-real-audio)
  verification before being trusted further than "builds, runs, and is logically sound."

## 11. Dead ends

- StreamingAsrManager: correct-looking API, wrong cadence (10-15s per update) for a live pill in
  this FluidAudio version. Never built against; ruled out by reading its source first.
- Hand-loading Tokenizer(vocabPath:) from a guessed vocab.json location -- unnecessary once
  AsrModels.vocabulary (already public) was found to be the exact dictionary needed, with a
  three-step decode algorithm. This finding is no longer load-bearing (attempt 2 does not decode
  tokens by hand at all), but is left here since it may be useful if a future streaming-chunk
  attempt is made.
- Attempt 1 in full (section 3): compiled, passed the test suite, and looked correct on paper, but
  froze after one update under live audio. Kept in this document rather than deleted from history,
  since the reasoning about why it likely failed is exactly the kind of thing worth knowing before
  reaching for FluidAudio's low-level streaming-chunk API again.
