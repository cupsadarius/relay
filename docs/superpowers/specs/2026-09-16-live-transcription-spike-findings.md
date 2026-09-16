# Live Transcription Spike - Findings

**Date:** 2026-09-16
**Status:** Spike complete (time-boxed proof of concept, not production-ready)

## 1. Goal

Prove that Relay dictation pill can show rolling interim transcription text while the user is
still speaking, then finalize with the existing authoritative batch transcript
(sttRouter.transcribe) on stop, without disturbing the existing batch dictation path.

## 2. Which FluidAudio path was used, and why

Three options were on the table going in:

- Path A (plan): AsrManager.transcribeStreamingChunk plus hand-rolled token-to-text decoding.
- Path B: StreamingEouAsrManager, a turnkey wrapper that downloads a separate parakeetEou model.
- A third option found while reading FluidAudio 0.12.6 source: its own higher-level
  StreamingAsrManager, which already wraps transcribeStreamingChunk and turns tokens into text
  internally.

StreamingAsrManager was tried first and rejected. It requires no extra model (it takes the
same AsrModels Relay already loads) and its output is already text, which looked like a shortcut
past the hand-rolled decoding step. But reading StreamingAsrManager appendSamplesAndProcess and
processWindow in
.derived-data/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift
showed it only emits an update once per chunkSeconds window, 10 to 15 seconds, even with the
shipped .streaming preset (chunkSeconds: 11). Its StreamingAsrConfig.hypothesisChunkSeconds
("Quick hypothesis chunk size for immediate feedback") is documented but dead code in this
version: appendSamplesAndProcess never reads it. Using it would mean the pill sits empty for the
first ~10+ seconds of every utterance, which is not a live pill.

Chosen: Path A, hand-rolled, but simpler than originally scoped. AsrManager.transcribeStreamingChunk
is public. Its decoder state persists per AudioSource across calls, so feeding it small,
non-overlapping ~0.75s windows and letting it decode from where it left off works directly. No
need to overlap chunks or pass previousTokens for de-duplication (that machinery in FluidAudio is
for the overlapping left/right-context windows StreamingAsrManager uses; a spike optimizing for
simplicity does not need it).

Token-to-text turned out not to require the fiddly vocab-file plumbing anticipated going in
(loading Streaming/Tokenizer.swift's public Tokenizer(vocabPath:) from a guessed vocab.json
path). Reading AsrManager.convertTokensWithExistingTimings (in AsrManager.swift, internal, so
not callable from Relay) showed the entire algorithm is: join each token's vocabulary string,
replace the SentencePiece word-boundary marker with a space, then trim whitespace.

AsrModels.vocabulary, an [Int: String] dictionary and the exact one AsrManager uses internally,
is public. So StreamingTranscriber loads its own AsrModels/AsrManager pair and replicates that
three-step algorithm directly: no Tokenizer class, no vocab-file path guessing, no separate model
download. This is implemented in Relay/Backends/StreamingTranscriber.swift, whose doc comment
repeats this reasoning next to the code.

Path B was not needed: no model download, no network dependency introduced.

## 3. What was built

- Relay/Backends/StreamingTranscriber.swift (new actor): loads its own AsrModels/AsrManager
  from the same on-disk cache FluidAudioParakeetEngine uses (AsrModels.defaultCacheDirectory for
  version .v2, network-free; AsrModels.modelsExist gates it so this never triggers a download).
  Buffers raw 16 kHz Float samples into ~0.75s (stepSampleCount = 12,000) non-overlapping steps,
  calls transcribeStreamingChunk per step, accumulates tokens, decodes the running text, and
  calls back with the growing string. Fully best-effort: any failure (models missing, load
  failure, decode failure) silently disables itself for the session rather than throwing; it can
  never affect the batch path.
- Relay/SpeechIn/MicrophoneCapture.swift: added an optional MicrophoneSampleStreaming protocol
  (setSampleObserver), deliberately separate from MicrophoneCapturing so no existing fake or test
  needs to implement it. MicrophoneCapture now conforms to both; the sample observer set before
  start(onLevel:) is captured once at the top of that call and invoked alongside the existing
  accumulate-plus-level path, unchanged.
- Relay/SpeechIn/DictationCoordinator.swift: start() creates a fresh StreamingTranscriber per
  session, only if the concrete microphone implements MicrophoneSampleStreaming (real
  MicrophoneCapture does, every test fake deliberately does not, so the existing test suite never
  touches FluidAudio), wires it as the mic's sample observer, and kicks off its background model
  load. finish() and cancel(sessionID:) tear it down (stopStreamingTranscription()) before the
  batch pipeline or cancellation proceeds. The interim callback hops to the main actor and calls
  activity.updateInterimText(text, sessionID:), guarded by the session still being in .recording.
- Relay/App/ActivityOverlayModel.swift: ActivityOverlayState.listening and .processing gained an
  interimText default-valued String associated value (default value keeps every existing
  construction call site compiling unchanged; pattern-match sites needed an extra underscore).
  process(sessionID:) carries the last interim text forward into .processing so the pill does not
  blank out the instant recording stops. New updateInterimText method added to
  ActivityOverlayModel and the DictationActivityPublishing protocol.
- Relay/App/ActivityOverlayPresentation.swift: the Listening and Processing subtitle (interactive
  layout only; the Minimal capsule has no text at all, 154 by 40) shows the live interim text in
  place of the usual "Microphone"/"Transcribing" placeholder once one exists, truncated to 60
  characters with an ellipsis. The pill's fixed size and the subtitle Text's existing
  lineLimit(1) mean this never grows the capsule.
- RelayTests/SpeechIn/DictationCoordinatorTests.swift: RecordingActivityOverlay (the only other
  DictationActivityPublishing conformer besides ActivityOverlayModel) got a no-op
  updateInterimText to keep conforming.

No other test needed changes: every listening/processing construction call site across the test
suite relies on the new field's default value.

## 4. Interim vs. final reconciliation

Interim text is purely a DictationActivityPublishing/pill concern; it never touches Transcript,
RulesTranscriptProcessor, or TextInserting. The batch path (microphone.stop, then
sttRouter.transcribe, then processor.process, then textInserter.insert) is completely
unmodified. stopStreamingTranscription() runs at the start of finish(), before the batch
pipeline's own Task is even created, so the two paths never race over what gets inserted; only
over what the pill displays a moment earlier.

## 5. Latency and quality feel

Not verified with a live microphone in this environment (see section 8: sandboxed agent, no
audio input). By construction:

- First interim update should land roughly 0.75 seconds (stepSampleCount divided by 16000) after
  speech starts, plus however long the streaming session's own model load takes if that has not
  finished yet; samples arriving before the load completes are silently dropped (best-effort;
  appendSamples no-ops until the manager is set), so the very start of an utterance may be
  missing from the interim text even though it is fully present in the final batch transcript.
- Updates continue roughly every 0.75 seconds afterward.
- Non-overlapping chunks with no left or right context (unlike StreamingAsrManager's windowing)
  means words are more likely to be mis-recognized right at chunk boundaries. Expected and
  acceptable for a best-effort, revise-in-place display; the source comments call this out.

## 6. CPU and memory cost

StreamingTranscriber loads its own AsrModels/AsrManager, separate from the instance
FluidAudioParakeetEngine already holds for the batch path. That means, for the duration of every
dictation session, two full Parakeet TDT model instances live in memory simultaneously; this is
the single biggest thing a production version must fix (see section 7). It was a deliberate
spike trade-off: sharing one loaded model would have meant threading AsrModels out of
FluidAudioParakeetEngine's ParakeetModelLoading/ParakeetModelSession seam, which is more invasive
than a time-boxed spike justified. Per-chunk inference cost itself (~0.75s of audio, TDT decode)
should be small relative to a 15-second-plus batch transcription, but this was not benchmarked.

## 7. What a production version would need

1. Share one loaded model. Thread the already-loaded AsrModels (or the AsrManager instance) from
   FluidAudioParakeetEngine into the streaming path instead of loading a second copy; the biggest
   cost identified in this spike.
2. A settings toggle plus graceful degradation UX. This spike is always-on with no user control
   and no visible indication when it silently disables itself (models missing, load failure).
   Production needs a preference, and probably a way to tell the difference between "no interim
   text yet" and "interim text unavailable this session" in the UI.
3. Chunking quality tuning plus tests. The 0.75s non-overlapping window size was picked for
   "feels live" without measurement; production should benchmark latency versus accuracy
   trade-offs (possibly reintroducing a small left-context overlap the way StreamingAsrManager
   does, without adopting its 10-second-plus cadence), and add unit tests for
   StreamingTranscriber's token accumulation and decode logic (none were added here; spike
   scope, per the brief).
4. Also worth doing, lower priority: an end-to-end manual or automated verification with a real
   microphone. This spike's interim-text rendering path was verified by code review, a clean
   build, the full existing test suite passing, and a smoke-test launch of the built app, but not
   by watching text populate live in the pill (see section 8).

## 8. Verification performed and not performed

- xcodebuild build: BUILD SUCCEEDED, no new warnings from any changed or added file.
- xcodebuild test: TEST SUCCEEDED, 668 tests executed, 5 skipped (pre-existing), 0 failures.
- Launched the built Relay.app directly (open .../Relay.app); it started, stayed running, and
  produced no new crash report in ~/Library/Logs/DiagnosticReports; then quit cleanly.
- Not performed: actually speaking into a microphone and watching the pill's subtitle update
  live. This agent's environment has no audio input device and no interactive GUI control, so
  the "how it feels" question in section 5 is reasoned from the code, not observed firsthand.
  This is the one gap between "builds and runs" and "confirmed working end-to-end"; flagged
  rather than glossed over, per the brief's instruction to report blockers and gaps plainly.

## 9. Dead ends

- StreamingAsrManager (section 2): correct-looking API, wrong cadence for a live pill in this
  FluidAudio version.
- Hand-loading Tokenizer(vocabPath:) from a guessed vocab.json location (the approach
  StreamingEouAsrManager itself uses internally): turned out to be unnecessary once
  AsrModels.vocabulary (already public) was found to be the exact same dictionary, with the
  decode algorithm being a three-step replace and trim.
