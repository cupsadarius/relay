# Live Transcription Spike - Findings

**Date:** 2026-09-16
**Status:** Spike complete, revised after a live test found the first approach broken.
Sections 6-7 were further updated after a subsequent productionization + polish pass that shipped
`transcribeForInterim`, the 450ms cadence, prefix-stable text diffing, animated resize/scroll, and
the interim-quiescence-before-final fix described there; the rest of this document (sections 1-5,
8-11) still describes the spike as originally built and is left as historical record.

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

## 6. Interim vs. final reconciliation (updated for the shipped production design)

This section described a spike-era wrinkle that no longer exists; it is rewritten here to match
what actually shipped after the productionization pass.

Interim text is still purely a DictationActivityPublishing/pill concern; it never touches
Transcript, RulesTranscriptProcessor, or TextInserting. The batch path (microphone.stop, then
sttRouter.transcribe, then processor.process, then textInserter.insert) is unmodified.

**No more cache sharing.** STTRouter now has two separate transcription entry points instead of
one. `transcribe(audio:options:)` is the router's normal, authoritative call: it still resumes the
selection cached by an immediately preceding `preferredBackendDisplayName()` lookup and clears
that cache afterward, exactly as before. `transcribeForInterim(audio:options:)` is new: it always
walks a fresh `backendOrder()` and never reads or writes `cachedCandidateOrder`. Interim ticks call
`transcribeForInterim`; DictationCoordinator's final call still calls `transcribe`. The two can no
longer interfere with each other's backend selection no matter how they interleave --
`STTRouterTests.testInterimTranscribeCallsDoNotConsumeOrDisturbTheCachedSelectionForTheFinalCall`
proves several interim calls between a lookup and the final call never disturb which backend the
final call resumes with.

**No more interim-vs-final contention on a shared backend actor.** The spike's
`stopStreamingTranscription()` cancelled the tick loop task but never awaited it, so a slow
interim call already in flight on a shared backend actor (in practice, FluidAudio's Parakeet
`AsrManager`) could still be running when the final `sttRouter.transcribe` call started on the
same actor -- the final result would then queue behind up to ~15s of interim audio instead of
running immediately. `StreamingTranscriber.stop()` is now `async` and awaits its tick-loop task's
`.value` before returning: cancelling the loop only stops *future* ticks, so awaiting the task is
what actually blocks until any in-flight `transcribe(...)` call genuinely finishes.
`stopStreamingTranscription()` (called at the start of `finish()`/`cancel(sessionID:)`, before the
batch pipeline's own task is created) now fully quiesces the interim path before the final call
ever starts. Proven by `DictationCoordinatorTests.testFinalTranscribeDoesNotStartUntilTheInFlightInterimCallCompletesAfterStop`,
which uses a gated fake backend to show the final call literally cannot begin until the blocked
interim call is released.

**Sample delivery is now strictly ordered.** Each microphone sample batch used to spawn its own
unstructured `Task { await transcriber.appendSamples(...) }`, whose relative scheduling order
across separate Tasks the Swift runtime does not guarantee. Batches now flow through a single
`AsyncStream<[Float]>`: the sample observer's `yield` call is synchronous, so it preserves arrival
order by construction, and one long-lived background task drains the stream into the transcriber
one batch at a time.

**Settings-gated.** All of the above only runs when `AppSettings.liveTranscriptionEnabled` is
`true` (the default). When it's off, `beginStreamingTranscription` returns immediately -- no
`StreamingTranscriber`, no sample observer, no `transcribeForInterim` calls at all.

## 7. Latency and quality feel (updated for the shipped production design)

Live testing after the spike (by the person driving this work, not this agent -- see section 10)
found the original ~1s cadence laggy, and found each tick's full-string replacement made the pill
read as rewriting rather than extending. Both were addressed in the productionization pass:

- **Cadence lowered to 450ms.** Extracted into `StreamingTranscriber.defaultTickInterval`, a single
  named constant, specifically so it stays easy to tune again. This is close to double the
  re-transcribe rate's CPU cost versus the original 1s spike (see section 8), traded for
  noticeably more responsive-feeling interim text. The skip-if-in-flight debounce is unchanged: a
  tick is still skipped outright (not queued) if the previous tick's transcription hasn't finished,
  so updates can arrive somewhat less often than every 450ms on a slower backend, but never overlap.
- **Interim text no longer reads as a full rewrite each tick.** A new pure helper, `InterimTextDiff`,
  computes the longest common prefix between the previous and current interim string (trimmed back
  to the last completed word, so a word mid-revision never flickers between "stable" and "changed").
  The view renders the stable prefix and the changed tail as one concatenated `Text` -- wrapping
  still flows as a single paragraph -- with `.contentTransition(.opacity)` giving only the tail a
  subtle crossfade. Since the stable prefix's string value is usually unchanged tick to tick,
  SwiftUI's own view diffing leaves it alone; only the genuinely new tail re-renders.
- **The pill's resize and auto-scroll are animated instead of snapping.** The NSPanel's frame
  change (`ActivityOverlayPanelHost.setFrame`) now animates via `NSAnimationContext` once the panel
  is already positioned (the very first placement still snaps in, matching the existing
  scale/opacity entrance transition), and the SwiftUI content frame animates in lockstep. The pill's
  bottom-edge/horizontal-center anchor survives the animation because `ActivityOverlayPlacement`
  keeps both invariants linear in the panel rect, and linearly interpolating between two anchored
  frames stays anchored at every intermediate frame -- proven analytically and by
  `ActivityOverlayWindowControllerTests.testGrowingInterimTextRecentersHorizontallyAndAnchorsTheSameBottomEdgeAsThePanelGrowsTaller`.
  Auto-scroll to the newest text now eases in via `withAnimation` instead of jumping.
- **The pill height math no longer risks gapping or clipping the last visible line.** The pill's
  total height and the `ScrollView`'s frame height (once scrolling kicks in past
  `InterimLayout.maxVisibleLines`) used to be two independently-computed formulas that could drift
  apart. Both now derive from one `InterimLayout.textAreaHeight(visibleLines:)` function, plus a
  small fixed slack constant biasing the character-count wrap estimate toward slightly too tall
  rather than clipped, since SwiftUI wraps on word boundaries and a nearly-full line can wrap
  earlier than pure character math predicts.
- Not independently re-verified with a live microphone by this agent in this pass either (same
  sandboxing constraint as section 10) -- the coordinator will rebuild and the user will retest the
  450ms cadence, the animations, and the text-diffing feel before this merges to main.

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
   **Done in the productionization pass:** `AppSettings.liveTranscriptionEnabled` (default on),
   surfaced as a toggle in a new General settings tab, gates the whole feature off cleanly.
3. Give interim ticks their own backend-selection path (or otherwise avoid sharing
   cachedCandidateOrder with the final call) so the two are fully independent rather than
   incidentally interacting through STTRouter's one-shot cache field (section 6).
   **Done:** see the rewritten section 6 above.
4. Unit tests for StreamingTranscriber's tick loop, debounce, and windowing/cap logic (none were
   added here; spike scope, per the brief, and the type has no dependents in the existing test
   suite to update). **Done:** `RelayTests/Backends/StreamingTranscriberTests.swift`.
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
