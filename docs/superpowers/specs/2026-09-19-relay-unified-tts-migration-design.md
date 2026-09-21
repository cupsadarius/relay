# Relay Unified TTS Migration Design

> Settings presentation and model-lifecycle guidance in this document is superseded by
> [Unified Speech Model Settings Design](2026-09-21-unified-speech-model-settings-design.md).
> The audio pipeline and playback architecture below remain current.

**Date:** 2026-09-19  
**Status:** Approved design  
**Repository baseline:** `main` after Whisper merge `7db5e0d`  
**Scope:** TTS model-management unification, provider-neutral audio sources, shared playback, PocketTTS migration, Kokoro long-form chunking, Apple TTS migration, legacy-path removal  
**Supersedes:** `2026-09-18-relay-unified-streaming-tts-design.md`

## 1. Summary

Relay will finish the speech architecture unification started by the Whisper backend work.

Whisper introduced the general `SpeechModelManaging` abstraction and removed STT's dependency on the older one-model `SpeechModelDownloading` protocol. TTS still uses the old path:

```text
KokoroTTSBackend ----+
                     +-- SpeechModelDownloading
PocketTTSBackend ----+
```

TTS also still has three different playback architectures:

```text
Apple
    AVSpeechSynthesizer owns playback

PocketTTS
    FluidAudio streaming
        ↓
    StreamingAudioPlayer

Kokoro
    complete WAV
        ↓
    SynthesizedAudioPlayer / AVAudioPlayer
```

This migration converges those systems in two steps.

First, TTS adopts the post-Whisper model-management pattern:

```text
SpeechModelManaging

Parakeet ------+
Whisper -------+
Kokoro --------+
PocketTTS -----+
```

Then TTS backends stop owning playback and become audio producers:

```text
SpeechRequest
    ↓
SpeechCoordinator
    ↓
TTSRouter
    ↓
TextToSpeechBackend
    ↓
TTSAudioSource
    ↓
StreamingAudioPlayer
    ↓
speakers
```

PocketTTS migrates first because it already produces streaming PCM.

Kokoro migrates next. Its current single-call approximately 510-phoneme limit is replaced by a long-form pipeline:

```text
text
  ↓
Kokoro frontend / G2P
  ↓
resolved phoneme stream
  ↓
KokoroPhonemeChunker
  ↓
safe phoneme segments
  ↓
sequential PCM synthesis
  ↓
PCMFramer
  ↓
bounded TTSAudioPipe
  ↓
shared StreamingAudioPlayer
```

Playback begins after the first Kokoro segment is synthesized. Later segments synthesize sequentially while earlier audio is already playing.

Apple migrates last through `AVSpeechSynthesizer.write(_:toBufferCallback:)`. Final removal of backend-owned playback occurs only after Apple passes its reliability gate.

## 2. Goals

### 2.1 Primary goals

1. Replace TTS's remaining `SpeechModelDownloading` usage with `SpeechModelManaging`.
2. Remove the distinction between backend-owned and Relay-owned playback.
3. Make `TextToSpeechBackend` responsible only for producing audio.
4. Make `StreamingAudioPlayer` the single playback implementation.
5. Preserve current TTS routing and fallback behavior.
6. Preserve `SpeechCoordinator` queue, replay, interruption, overlay, and watchdog semantics.
7. Make Kokoro handle normal long Claude/Codex responses instead of falling through merely because the text exceeds one Kokoro inference window.
8. Start Kokoro playback after the first segment rather than after synthesis of the full response.
9. Continue synthesizing later Kokoro segments while earlier segments play.
10. Preserve explicit model downloads. Speech must never silently download models.
11. Keep all current local TTS providers fully local after model installation.
12. Maintain deterministic cancellation and exactly-one-terminal-event semantics.
13. Keep provider-specific types and concepts out of `SpeechCoordinator` and the shared player.

### 2.2 Secondary goals

- Remove the whole-WAV Kokoro production path.
- Remove duplicated stop/pause/resume implementations.
- Remove duplicated playback lifecycle forwarding.
- Make output-level reporting consistent across providers.
- Make future PCM-producing TTS engines straightforward to integrate.
- Remove playback implementation details from `TTSCapabilities`.

## 3. Non-goals

This migration does not:

- change automatic-vs-user-requested speech priority;
- change `SpeechCoordinator` queue capacity or replay policy;
- change agent-session focus behavior;
- change speech preprocessing;
- change STT routing or model behavior;
- merge the STT and TTS Settings screens;
- reinterpret voices as models;
- add cloud TTS;
- add simultaneous speech;
- run several Kokoro inference calls concurrently;
- add voice cloning;
- add SSML;
- add crossfades or artificial inter-segment silence without evidence that they are needed;
- add model removal for FluidAudio TTS models where the underlying engine has no safe removal contract;
- redesign `SpeechModelManaging`.

## 4. Current production state

Relay currently runs FluidAudio `0.15.7`.

The default TTS order is:

```text
PocketTTS
Apple System Voice
Kokoro
```

### 4.1 Model lifecycle

STT has already moved to:

```swift
protocol SpeechModelManaging {
    var backendID: String { get }

    func models() async -> [SpeechModelStatus]

    func downloadModel(
        _ id: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    func removeModel(_ id: String) async throws
    func selectModel(_ id: String) async throws
}
```

Parakeet is the existing one-model implementation.

Whisper is the existing many-model implementation.

TTS still has:

```swift
protocol SpeechModelDownloading {
    func downloadModels(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}
```

implemented directly by Kokoro and PocketTTS. That old protocol is now the last provider-specific model-lifecycle path in Relay.

### 4.2 Playback

`TextToSpeechBackend` currently owns both synthesis and playback:

```swift
@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }

    func availability() async -> BackendAvailability
    func setPlaybackEventHandler(
        _ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void
    )
    func speak(
        text: String,
        options: TTSOptions,
        sessionID: UUID
    ) async throws
    func stop()
    func pause()
    func resume()
}
```

Consequently:

- Apple forwards `AVSpeechSynthesizerDelegate` events.
- Pocket forwards `StreamingAudioPlayer` events.
- Kokoro forwards `SynthesizedAudioPlayer` events.
- `TTSRouter` has to reason about backend-owned playback objects.

The target architecture removes those responsibilities from the backend contract.

## 5. Migration strategy

The migration is intentionally ordered:

```text
1. Unify TTS model management
        ↓
2. Introduce common audio-source/playback boundary
        ↓
3. Migrate PocketTTS
        ↓
4. Migrate Kokoro + long-form chunker
        ↓
5. Migrate Apple TTS
        ↓
6. Remove legacy playback/download paths
```

Model lifecycle and audio transport are separate concerns. They should be unified first so individual backend migrations do not have to carry unrelated legacy abstractions forward.

## 6. TTS model-management unification

### 6.1 Reuse `SpeechModelManaging`

Do not introduce a TTS-specific model-management protocol.

Kokoro and Pocket use the existing `SpeechModelManaging`.

Both are one-model backends, matching `ParakeetModelManager`.

Conceptually:

```swift
struct KokoroModelManager: SpeechModelManaging {
    static let modelID = "kokoro-82m-ane-en"
    let backendID = "kokoro"
}

struct PocketTTSModelManager: SpeechModelManaging {
    static let modelID = "pocket-tts-v2.1-en"
    let backendID = "pocket-tts"
}
```

### 6.2 One-model semantics

Like Parakeet:

```text
models().count == 1
isSelected == true
selectModel(...) == validating no-op
```

Model selection must not be confused with voice selection.

These remain separate:

```text
model
    Kokoro 82M English ANE

voice
    af_heart
    af_bella
    ...
```

and:

```text
model
    PocketTTS v2.1 English

voice
    alba
```

Existing `kokoroVoice` and `pocketVoice` settings remain unchanged.

### 6.3 Model removal

Do not reach behind FluidAudio's loaders and delete cache directories merely to satisfy the protocol.

Until each backend has a safe provider-owned removal operation:

```text
removeModel(...)
    -> removeNotSupported
```

matching Parakeet's precedent.

No Remove button is added to the current one-model TTS UI.

### 6.4 App/runtime wiring

Replace:

```text
SpeechOutputServices.ttsModelDownloaders
AppModel.ttsModelDownloaders
```

with:

```text
SpeechOutputServices.ttsModelManagers
AppModel.ttsModelManagers
```

`TTSBackendCatalog.downloadTTSModel(_:)` resolves the manager's one model and calls `manager.downloadModel(modelID, progress:)`.

The current backend-level TTS Settings UI remains visually unchanged. It does not need a nested per-model UI while all TTS providers expose zero or one model.

### 6.5 Delete old abstraction

Once Kokoro and Pocket are migrated, `SpeechModelDownloading` has no production consumers and is deleted.

This completes the model-management migration started by Whisper.

## 7. Unified audio-source architecture

The target TTS path becomes:

```text
                        SpeechRequest
                             │
                             ▼
                      SpeechCoordinator
                             │
                             ▼
                         TTSRouter
                             │
                     choose provider
                             │
             +---------------+---------------+
             ▼               ▼               ▼
          Pocket           Kokoro           Apple
             │               │               │
          stream          chunks           write()
             │               │               │
             +---------------+---------------+
                             │
                             ▼
                       TTSAudioSource
                             │
                             ▼
                    StreamingAudioPlayer
                             │
              +--------------+--------------+
              ▼              ▼              ▼
           speakers        levels        lifecycle
```

`SpeechCoordinator` remains completely unaware of this change.

## 8. Updated backend contract

The backend becomes a source factory.

Keep the protocol main-actor isolated for this migration. Removing playback ownership does not require simultaneously changing the isolation model of the entire TTS registry.

Target shape:

```swift
@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }

    func availability() async -> BackendAvailability

    func makeAudioSource(
        text: String,
        options: TTSOptions
    ) async throws -> any TTSAudioSource
}
```

Backends no longer implement:

```text
setPlaybackEventHandler
speak
stop
pause
resume
```

A backend owns:

- model preparation;
- voice validation;
- provider-specific options;
- creation of a PCM-producing source.

A backend does not own:

- speakers;
- `AVAudioEngine`;
- `AVAudioPlayer`;
- playback pause/resume;
- playback events;
- output metering.

## 9. Standard PCM contract

```swift
struct TTSAudioFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
}

struct TTSAudioFrame: Sendable {
    /// Interleaved Float32 PCM.
    let samples: [Float]
    let format: TTSAudioFormat
}

protocol TTSAudioSource: Sendable {
    func next() async throws -> TTSAudioFrame?
    func cancel() async
}
```

For the first implementation, source adapters normalize output to Float32 PCM before crossing this boundary.

Pocket and Kokoro are mono 24 kHz sources.

Provider-specific concepts do not cross the boundary.

Do not expose:

- WAV Data;
- FluidAudio `AudioFrame`;
- Kokoro phonemes;
- Kokoro segment ids;
- AVSpeechSynthesizer callback objects;
- Pocket tokens.

`next()` means:

```text
frame     -> next contiguous audio
nil       -> normal end of stream
throw     -> source failed
```

## 10. `TTSAudioPipe`

Kokoro and Apple need a bridge between producer-driven synthesis and pull-driven playback.

Introduce a reusable bounded pipe:

```text
producer
   ↓
TTSAudioPipe.Sink
   ↓
bounded queued PCM
   ↓
TTSAudioPipe.Source
   ↓
StreamingAudioPlayer
```

The pipe measures buffering in seconds of audio, not frame count.

Initial production watermarks:

```text
high watermark: approximately 30 s
low watermark:  approximately 15 s
```

These are constants, not user settings.

When queued audio reaches the high watermark, future producer yields suspend. When the queue drains below the low watermark, the producer resumes.

### 10.1 Important current-state correction

Pipe backpressure alone is not sufficient.

The current `StreamingAudioPlayer` drains its input stream as quickly as frames arrive and schedules them onto `AVAudioPlayerNode`.

If that behavior remained unchanged:

```text
Kokoro
  ↓
pipe
  ↓ immediately drained
AVAudioPlayerNode scheduled buffers
```

the pipe would rarely reach its high watermark, and long responses could still be synthesized and scheduled arbitrarily far ahead.

Therefore the shared player must also use bounded demand.

It tracks:

```text
scheduled audio duration
-
played audio duration
=
scheduled-ahead duration
```

and stops calling `source.next()` when its own scheduled-ahead window is full.

Initial player scheduling target:

```text
approximately 1-2 seconds ahead of audible playback
```

As buffers complete, the player requests more frames.

This creates real end-to-end backpressure:

```text
speaker
   ↑
small scheduled-ahead window
   ↑
TTSAudioSource
   ↑
30-second bounded pipe
   ↑
Kokoro producer
```

Pausing playback must therefore eventually backpressure synthesis rather than allowing the entire remaining response to accumulate inside `AVAudioPlayerNode`.

## 11. Pipe terminal semantics

### 11.1 Normal completion

Producer yields frames and then finishes. Consumer receives every queued frame and finally `next() -> nil`. After the last scheduled audio finishes playing, `.finished` is emitted exactly once.

### 11.2 Producer failure after valid PCM

Valid audio already produced should not be thrown away merely because later synthesis failed.

The pipe records the failure, allows valid frames to drain, then throws the stored error after the final valid frame.

If audio had already started, the player remembers that source failure until already-scheduled PCM finishes, then emits `.failed` exactly once.

### 11.3 Failure before audible start

If the source fails while the player is still prebuffering:

```text
no .started
discard candidate PCM
throw from startPlayback
```

The router may then try the next backend.

A failed backend must not speak half a sentence and then restart the response through another provider.

### 11.4 Cancellation

Cancellation is immediate:

```text
Stop
 ↓
cancel source
 ↓
cancel producer
 ↓
discard pipe frames
 ↓
discard scheduled playback
 ↓
wake blocked producer/consumer
 ↓
.cancelled
```

Cancellation never drains queued speech.

## 12. Shared `StreamingAudioPlayer`

`StreamingAudioPlayer` becomes Relay's only production PCM playback implementation.

New conceptual API:

```swift
func startPlayback(
    _ source: any TTSAudioSource,
    sessionID: UUID
) async throws
```

It preserves useful parts of the current implementation:

- approximately 0.6 s startup prebuffer;
- playback-start return semantics;
- conversion outside the real-time render callback;
- player node connected at mixer/output format;
- no task allocation from the audio render thread;
- PCM-derived output levels;
- deterministic stale-session rejection;
- exactly one terminal event.

It adds:

- per-frame `TTSAudioFormat`;
- bounded source demand;
- variable frame sizes;
- generic channel/sample-rate conversion;
- source cancellation;
- delayed terminal failure after draining valid already-produced audio.

The old Pocket-specific assumptions about 1920-sample 24 kHz frames disappear from generic player bookkeeping.

Frame duration is calculated from actual samples, channels, and sample rate.

## 13. Router lifecycle and backend commitment

`TTSRouter` remains the owner of backend choice.

It now owns two conceptual states: candidate and active.

### 13.1 Candidate

Before audible playback, a candidate carries backend, source, and session id. A candidate may fail without committing Relay to that backend.

### 13.2 Active

The backend becomes active when the shared player emits `.started`.

After that point, no fallback is allowed for the session.

### 13.3 `.scheduled`

The router emits `.scheduled` once per Relay speech session, not once per backend attempt.

This prevents fallback attempts from producing duplicate scheduled lifecycle events.

### 13.4 Fallback rules

Allowed before start:

- backend unavailable;
- `makeAudioSource` failure when fallback-worthy;
- model missing;
- model load failure;
- source failure during prebuffer;
- player setup/start failure before `.started`.

Not allowed after `.started`:

- Pocket source failure later;
- Kokoro segment N failure;
- Apple generation failure later;
- audio route/playback failure.

After commitment, the current session terminates as `.failed`. Relay does not restart the full response in another voice.

## 14. PocketTTS migration

Pocket is the first audio backend migrated.

Current:

```text
PocketTtsManager.synthesizeStreaming
    ↓
AsyncThrowingStream<[Float]>
    ↓
PocketTTSBackend
    ↓
StreamingAudioPlayer
```

Target:

```text
PocketTtsManager.synthesizeStreaming
    ↓
PocketTTSAudioSource
    ↓
shared StreamingAudioPlayer
```

`PocketTTSAudioSource` owns iteration of FluidAudio's stream.

Each existing frame becomes a `TTSAudioFrame` with 24 kHz mono metadata.

Cancellation of the source must terminate stream consumption and propagate to FluidAudio's forwarding task.

The migration must preserve:

- startup latency;
- current Pocket audio quality;
- local-only loading;
- voice selection;
- no rate support;
- fallback when the model is absent;
- immediate Stop.

Once migrated, `PocketTTSBackend` contains no player.

## 15. Kokoro engine seam migration

The current Kokoro seam ends at text-to-WAV synthesis, which forces Relay through WAV even though FluidAudio 0.15.7 exposes the primitives Relay needs.

The new model-session seam becomes conceptually:

```swift
protocol KokoroModelSession: Sendable {
    func phonemes(for text: String) async throws -> String

    func synthesize(
        phonemes: String,
        voice: String,
        speed: Float
    ) async throws -> KokoroPCM
}

struct KokoroPCM: Sendable {
    let samples: [Float]
    let sampleRate: Double
}
```

The live adapter uses:

```text
KokoroAneManager.phonemes(for:)
KokoroAneManager.synthesizeFromPhonemesDetailed(...)
```

The detailed result exposes raw Float32 PCM and its sample rate.

Relay therefore stops creating WAV, decoding WAV, writing temporary WAV for level analysis, and feeding WAV to `AVAudioPlayer` in Kokoro's production path.

## 16. Kokoro long-form frontend

### 16.1 Phonemize first

Relay resolves the whole input through Kokoro's frontend before chunking:

```text
original text
    ↓
Kokoro normalization
    ↓
G2P
    ↓
resolved phoneme stream
    ↓
chunker
```

Do not character-chunk the original prose and independently phonemize arbitrary slices.

Using the full Kokoro frontend first preserves its handling of numbers, currency, abbreviations, lexicon entries, weak pronunciation forms, punctuation/prosody, and G2P fallback behavior.

### 16.2 Current FluidAudio limit

The pinned FluidAudio version enforces a maximum phoneme length of 510 characters.

Relay does not target that exact ceiling.

Initial safe target:

```text
preferred target approximately 480 phoneme characters
hard maximum = FluidAudio's validated 510-character limit
```

The hard limit comes from the pinned API constant when available rather than from an unexplained duplicate magic number.

## 17. `KokoroPhonemeChunker`

Introduce a pure deterministic component:

```swift
struct KokoroPhonemeChunker {
    func chunks(from phonemes: String) -> [String]
}
```

It contains no model, audio, actor, networking, or playback code.

### 17.1 Boundary preference

When choosing a split near the target size, prefer:

1. sentence-ending punctuation;
2. clause/pause punctuation;
3. whitespace;
4. hard phoneme split only as a last resort.

Punctuation should remain attached to the segment it semantically closes whenever possible.

### 17.2 Search policy

For a long remaining stream:

1. inspect the region ending near the preferred target;
2. search backward for the strongest natural boundary;
3. if none exists, search forward only within the absolute model-safe limit for a natural boundary;
4. if no usable boundary exists, hard-split at the conservative target.

Every returned chunk must satisfy the FluidAudio hard phoneme limit.

### 17.3 Preservation invariant

Concatenating chunk content must preserve the resolved phoneme sequence except for explicitly allowed normalization of boundary whitespace.

The chunker must never silently delete meaningful phonemes or punctuation.

## 18. Secondary Kokoro size guard

FluidAudio also has an acoustic-frame ceiling.

A phoneme chunk below 510 characters can still theoretically produce too many acoustic frames.

Therefore long-form synthesis gets one bounded adaptive decomposition strategy.

If a chunk fails specifically because generated acoustic frames exceed the model cap:

```text
offending phoneme chunk
    ↓
split again at best internal boundary
    ↓
retry smaller chunks sequentially
```

Requirements:

- retry only the known size-related condition;
- each retry strictly reduces chunk size;
- preserve ordering;
- keep a bounded recursion/decomposition depth;
- if no further meaningful split is possible, fail the source.

A normal inference failure must not be recursively retried as if it were a length problem.

## 19. Kokoro producer

`KokoroTTSBackend.makeAudioSource(...)`:

1. ensures the local model is loaded without download;
2. resolves the configured voice;
3. maps Relay's rate to Kokoro speed exactly as today;
4. phonemizes the complete text;
5. chunks the resolved phonemes;
6. creates a bounded `TTSAudioPipe`;
7. launches one producer task;
8. returns the pipe-backed source.

Producer:

```text
for chunk in chunks:
    check cancellation
    synthesize chunk
    frame PCM
    yield frames to pipe
finish pipe
```

Only one call into Kokoro synthesis runs at a time.

## 20. Kokoro synthesis/playback concurrency

Required behavior:

```text
synthesize segment 1
    ↓
PCM 1 enters pipe
    ↓
player begins segment 1
    ║
    ╚════ synthesize segment 2

segment 2 completes
    ↓
PCM 2 enters pipe
    ║
    ╚════ synthesize segment 3
```

Critical invariant:

> Synthesis of segment 3 does not wait for playback of segment 2 to begin.

Kokoro waits only for the previous synthesis call to finish, bounded pipe backpressure, or cancellation. It does not wait for playback segment boundaries.

This is pipeline concurrency, not parallel inference.

## 21. Kokoro PCM framing

A Kokoro inference result can contain several seconds of PCM.

Do not pass one complete segment as a giant `TTSAudioFrame`.

Introduce a generic framer that produces approximately 80 ms frames. The exact duration is an implementation constant.

Benefits:

- responsive Stop;
- useful player scheduling windows;
- accurate duration accounting;
- smooth level metering;
- smaller audio buffers;
- provider-consistent playback behavior.

The final frame may be shorter.

## 22. Kokoro failure behavior

### Before playback starts

If model load, phonemization, first-segment synthesis, source prebuffer, or player startup fails before `.started`, the router may fall back to the next configured provider when the failure is classified as fallback-worthy.

### After playback starts

If segment N fails:

1. no more Kokoro segments are produced;
2. already-valid PCM remains playable;
3. the stored source failure follows that PCM;
4. the shared player drains valid audio;
5. the session terminates as `.failed`;
6. Relay does not restart the answer through Pocket or Apple.

### Long text

Ordinary long input must no longer produce a routine `textTooLong -> fallback` path.

Long-form chunking makes long input normal supported input.

An over-limit chunk reaching FluidAudio after chunking is an invariant failure, not routine routing behavior.

## 23. Apple TTS migration

Apple is migrated last.

Target:

```text
AVSpeechUtterance
    ↓
AVSpeechSynthesizer.write(_:toBufferCallback:)
    ↓
AppleTTSAudioSource
    ↓
shared StreamingAudioPlayer
```

The adapter converts callback buffers into shared Float32 PCM.

Generation and playback become separate:

```text
AVSpeechSynthesizer -> PCM generation
StreamingAudioPlayer -> speakers
```

Pause/resume therefore belongs entirely to the shared player.

A small bounded callback bridge is acceptable internally because Apple's callback is push-driven.

### 23.1 Apple reliability gate

Before the old native playback path can be deleted, verify:

- short text;
- long text;
- immediate Stop;
- pause/resume;
- stop before audible start;
- cancellation while `write` is generating;
- rapid replacement by user-requested speech;
- no stale callback after cancellation reaches the next session;
- stable memory across repeated requests;
- acceptable startup latency;
- voice and rate parity with the current path.

If Apple's write path fails this gate, Pocket/Kokoro migration may ship independently, but the overall unified-TTS migration is not considered complete and legacy Apple playback remains temporarily isolated.

Do not permanently complicate the common source protocol merely to accommodate a failed Apple experiment.

## 24. Playback capabilities cleanup

Current `TTSCapability` contains playback implementation details such as pause/resume, output level, and streaming.

After every backend is on the shared player, those are properties of Relay's playback pipeline, not provider capabilities.

Remove them.

Backends retain synthesis/provider properties such as:

```text
voiceSelection
fullyOffline
```

Future synthesis-specific capabilities can be added when a real feature needs them.

## 25. SpeechCoordinator invariants

`SpeechCoordinator` is deliberately not redesigned.

The migration must preserve:

- user-requested speech interrupts automatic speech;
- automatic speech queues;
- queue cap behavior;
- Replay Last;
- session-aware stop;
- current activity-overlay transitions;
- watchdog behavior;
- exactly-one terminal-event handling.

`SpeechCoordinator` continues to receive:

```text
scheduled
started
level
finished
cancelled
failed
```

It must not know about `TTSAudioSource`, `TTSAudioPipe`, PCM, Kokoro chunks, Pocket streams, or Apple callbacks.

## 26. Settings behavior

The TTS Settings experience stays familiar.

Backend rows remain PocketTTS, Apple System Voice, and Kokoro, with enabled/disabled state, order, readiness, and Download for model-backed providers.

Kokoro and Pocket still present a simple aggregate Download action because each has one model.

Do not introduce nested model UI for one-model providers merely because the underlying protocol supports it.

Existing voice controls remain Apple Voice, Kokoro Voice, and PocketTTS Voice.

Existing speech-rate behavior remains:

- Apple consumes the configured rate directly.
- Kokoro retains its current mapping where Relay `0.5` corresponds to Kokoro `1.0`.
- Pocket continues to ignore rate until the provider has a real speed control.

## 27. Privacy

No new persistent content is introduced.

Ephemeral:

- speech text;
- phoneme stream;
- Kokoro chunks;
- PCM frames;
- audio pipe buffers;
- Apple generated buffers.

Nothing above is written to history.

Diagnostics may contain only structural information such as backend id, source creation duration, first-frame latency, time to audible start, Kokoro segment count and lengths, per-segment synthesis duration, buffered-audio duration, player scheduled-ahead duration, backpressure counts, failure category, cancellation, and fallback-before-start.

Never log speech text, phoneme contents, PCM/audio data, agent-response content, or raw provider errors that may contain user content.

## 28. Testing strategy

### 28.1 TTS model managers

Kokoro and Pocket tests prove one model, always-selected semantics, presence mapping, explicit download delegation, progress, unknown id handling, unsupported removal, voice/model independence, and that normal speech never invokes download.

### 28.2 `TTSAudioPipe`

Tests prove FIFO order, duration accounting, high/low watermark hysteresis, finish, failure-after-buffer, cancellation, blocked producer wakeup, blocked consumer wakeup, and no suspended waiter after terminal state.

### 28.3 Shared player

Tests prove prebuffer semantics, per-frame duration, multiple source sample rates, source failure before start, short source start, normal completion, post-start failure draining, Stop, pause/resume, stale-session rejection, source cancellation, output level, scheduled-ahead bound, and eventual backpressure while paused.

### 28.4 Router

Tests prove source-creation fallback, pre-start player/source fallback, `.started` commitment, no post-start fallback, backend identity, one `.scheduled`, and session-aware Stop.

### 28.5 Pocket adapter

Tests prove frame order, 24 kHz mono metadata, finish, source error, cancellation, and no backend-owned player after cutover.

### 28.6 Kokoro chunker

Tests prove hard-cap safety, boundary priority, no accidental word/phoneme loss, punctuation preservation, preservation of the source phoneme sequence, blank input, and deterministic hard splitting.

### 28.7 Kokoro producer

Tests prove sequential inference, segment ordering, synthesis-playback overlap, backpressure-only suspension, cancellation, bounded acoustic-frame retry, valid-buffer draining after later failure, and repeated-run state cleanup.

Required regression:

```text
synthesis 1 finishes
playback 1 starts

synthesis 2 finishes
playback 1 still active

assert synthesis 3 has already started
```

### 28.8 Apple

Before removing native Apple playback, test callback ordering, end-of-stream detection, generation stop, stale callback rejection, long input, rapid replacement, voice/rate parity, and repeated-run memory behavior.

## 29. Migration phases

### Phase 1 - model lifecycle convergence

Add `KokoroModelManager` and `PocketTTSModelManager`, replace `ttsModelDownloaders` with `ttsModelManagers`, migrate TTS download actions to `SpeechModelManaging`, and delete `SpeechModelDownloading`.

No playback behavior changes.

### Phase 2 - common audio transport

Add `TTSAudioFormat`, `TTSAudioFrame`, `TTSAudioSource`, `TTSAudioPipe`, and `PCMFramer`.

Generalize `StreamingAudioPlayer` and add demand-bounded scheduling.

### Phase 3 - PocketTTS

Introduce `PocketTTSAudioSource` and preserve current low-latency streaming behavior through the shared player.

### Phase 4 - Kokoro long-form

Add `KokoroPhonemeChunker` and a Kokoro source/producer. Change the engine seam to phoneme plus PCM operations. Add phoneme chunking, bounded acoustic-size retry, sequential segment synthesis, PCM framing, and bounded pipe buffering. Remove Kokoro's whole-WAV production path.

### Phase 5 - Apple

Implement the `AVSpeechSynthesizer.write` adapter and run the reliability gate. Migrate Apple only if it passes.

### Phase 6 - cleanup

After all three production backends use the shared path, remove `SynthesizedAudioPlayer`, legacy stream overloads, backend event forwarding, backend stop/pause/resume, backend-owned playback state, and obsolete playback-related TTS capabilities.

## 30. Architectural invariants

The finished implementation must satisfy all of the following:

1. `SpeechModelManaging` is the only model-management protocol used by production speech backends.
2. `SpeechModelDownloading` no longer exists.
3. A TTS backend produces audio; it does not own speaker playback.
4. One Relay speech session has one shared player.
5. Only one speech session is active in the router.
6. `.scheduled` is emitted once per Relay speech session.
7. Fallback is permitted only before `.started`.
8. After `.started`, provider failure terminates that session rather than restarting it elsewhere.
9. Stop cancels generation and playback and discards queued PCM.
10. The shared player does not greedily drain an unbounded amount of future audio.
11. Backpressure reflects actual audio ahead of playback, not merely queue occupancy at one transient layer.
12. Kokoro phonemizes before normal chunking.
13. No Kokoro chunk exceeds FluidAudio's hard phoneme limit.
14. A known acoustic-frame overflow may trigger bounded further splitting.
15. Kokoro runs at most one inference call at a time.
16. Kokoro synthesis may run concurrently with playback.
17. Kokoro synthesis never waits for the next segment to begin playback unless downstream backpressure requires it.
18. Pocket retains its existing streaming latency characteristics.
19. No backend silently downloads a model while speaking.
20. Voice selection remains distinct from model selection.
21. `SpeechCoordinator` remains ignorant of PCM, chunking, model runtimes, and provider APIs.
22. Speech text, phonemes, and audio remain ephemeral.

## 31. Completion criteria

The migration is complete when:

```text
KokoroModelManager ---+
PocketModelManager ---+
ParakeetModelManager -+-- SpeechModelManaging
WhisperModelManager --+
```

and:

```text
Pocket --+
Kokoro --+-- TTSAudioSource -- StreamingAudioPlayer
Apple ---+
```

with:

```text
SpeechModelDownloading      deleted
SynthesizedAudioPlayer      deleted
backend playback ownership  deleted
whole-WAV Kokoro playback   deleted
```

and Kokoro can read a long agent response through multiple phoneme-safe segments while synthesis and playback overlap correctly.

The architectural payoff is:

```text
many speech providers
        ↓
one model-management pattern
        +
one audio-source contract
        +
one playback lifecycle
```

rather than a collection of backend-specific special cases.
