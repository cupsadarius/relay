# Relay — OpenAI Whisper Local Models Feasibility Spike

**Date:** 2026-09-18  
**Status:** Proposed feasibility spike  
**Repository baseline:** `cupsadarius/relay` `main` at `d17988ceba55c9c7604cce60fc47ae3dbe032fb3`  
**Scope:** Add the official OpenAI Whisper model family as a local dictation backend with explicit model download/selection and one-model-at-a-time memory residency.

---

## 1. Summary

Relay already has the right outer architecture for another local STT backend:

```text
MicrophoneCapture
      │
      ▼
AudioInput
      │
      ▼
STTRouter
      │
      ├── Apple Speech
      ├── Parakeet
      └── OpenAI Whisper
```

The new backend should be **one backend**:

```text
Backend: OpenAI Whisper
```

with an internal selected model:

```text
Model: small.en
```

Whisper model variants are not separate Relay STT backends.

The central feasibility question is:

> Can Relay run the official OpenAI Whisper model family locally on Apple Silicon with a clean model selector, explicit downloads, and exactly one selected Whisper model resident in inference memory at a time?

This spike should answer that before production integration.

---

# 2. Desired Product Behavior

The intended Settings experience is approximately:

```text
Dictation

Apple Speech
Parakeet
OpenAI Whisper
    Selected model: small.en

    Models

    tiny.en      Downloaded
    tiny         Download
    base.en      Downloaded
    base         Download
    small.en     Active
    small        Download
    medium.en    Download
    medium       Download
    large-v1     Download
    large-v2     Download
    large-v3     Download
    turbo        Downloaded
```

Selecting a downloaded model:

```text
small.en
   ↓ unload
turbo
   ↓ load
```

At steady state:

```text
Disk
────────────────
tiny.en      ✓
base.en      ✓
small.en     ✓
turbo        ✓

Inference memory
────────────────
small.en only
```

Downloaded models may coexist on disk.

Loaded inference models may not.

---

# 3. Hard Requirements

1. Whisper runs locally.
2. Dictation audio is not uploaded.
3. Model downloads are explicit user actions.
4. Dictation never silently downloads a model.
5. Relay can show which Whisper models are:
   - not downloaded
   - downloading
   - downloaded
   - active
   - failed/corrupt
6. Only the selected Whisper model is loaded for inference.
7. Switching models unloads the previous inference context before loading the next.
8. Existing Apple Speech and Parakeet backends remain unchanged.
9. Whisper consumes Relay's existing `AudioInput`.
10. Whisper does not own the microphone.
11. A Whisper failure must remain isolated behind `STTRouter`.
12. No Python, PyTorch, or `ffmpeg` runtime dependency is acceptable in the shipping Relay app.
13. No third-party Whisper fine-tunes are part of the initial catalog.
14. Initial model support means official OpenAI Whisper checkpoints only, even if a runtime-specific converted representation is required.

---

# 4. Official Model Catalog

OpenAI currently exposes these canonical Whisper checkpoints relevant to Relay:

| Relay model id | OpenAI checkpoint | English only | Approx. parameters |
|---|---|---:|---:|
| `tiny.en` | `tiny.en` | yes | 39M |
| `tiny` | `tiny` | no | 39M |
| `base.en` | `base.en` | yes | 74M |
| `base` | `base` | no | 74M |
| `small.en` | `small.en` | yes | 244M |
| `small` | `small` | no | 244M |
| `medium.en` | `medium.en` | yes | 769M |
| `medium` | `medium` | no | 769M |
| `large-v1` | `large-v1` | no | ~1.55B |
| `large-v2` | `large-v2` | no | ~1.55B |
| `large-v3` | `large-v3` | no | ~1.55B |
| `turbo` | `large-v3-turbo` / `turbo` | no | ~809M |

OpenAI also exposes aliases:

```text
large          → large-v3
large-v3-turbo → turbo
```

Relay should not show aliases as duplicate downloadable models.

Canonical UI catalog:

```text
tiny.en
tiny
base.en
base
small.en
small
medium.en
medium
large-v1
large-v2
large-v3
turbo
```

---

# 5. Licensing / Cost

OpenAI publishes Whisper code and model weights under the MIT License.

The intended Relay backend is therefore:

```text
local
offline after download
no OpenAI API key
no per-request API charge
```

The runtime chosen for macOS must also have a license compatible with Relay.

---

# 6. Runtime Candidates

## Candidate A — whisper.cpp

**Recommended first probe.**

`whisper.cpp` is a native C/C++ implementation of OpenAI Whisper with first-class Apple Silicon support.

It currently supports:

```text
macOS arm64
Metal
Accelerate
optional Core ML encoder acceleration
CPU inference
quantization
C API
all major official Whisper model variants
```

It explicitly lists:

```text
tiny.en
tiny
base.en
base
small.en
small
medium.en
medium
large-v1
large-v2
large-v3
large-v3-turbo
```

### Advantages for Relay

- no Python/PyTorch runtime
- direct process-local inference
- explicit model/context lifetime
- easy to reason about one-model-at-a-time residency
- Apple Silicon optimized
- consumes 16 kHz speech input naturally
- supports the entire desired OpenAI model family
- model loading can remain entirely behind a Swift wrapper

### Risks

- C/C++ integration in the Xcode project
- runtime model files use a whisper.cpp representation rather than OpenAI `.pt` directly
- we must establish trusted provenance/checksums for converted model artifacts
- Metal/Core ML build configuration must not destabilize Relay's existing Swift package graph

---

## Candidate B — WhisperKit

WhisperKit is a Swift/Core ML Whisper implementation optimized for Apple hardware.

### Advantages

- Swift-facing API
- Core ML-native
- explicit model load/unload API
- strong Apple Silicon fit

### Risks

- runtime artifacts are third-party Core ML conversions of Whisper checkpoints
- model naming/catalog does not map as directly to the complete official OpenAI catalog
- introduces a larger Swift/Core ML dependency surface
- we still need to establish one-to-one provenance for every model Relay exposes

---

## Candidate C — Official Python OpenAI Whisper

Not a shipping candidate.

It would require:

```text
Python
PyTorch
Python package management
ffmpeg for normal CLI/file paths
```

That conflicts with Relay's native, self-contained macOS architecture.

It remains useful only as a reference implementation when validating transcript equivalence.

---

# 7. Spike Runtime Decision

Probe `whisper.cpp` first.

Only investigate WhisperKit if `whisper.cpp` fails one of these requirements:

```text
native Relay build
acceptable Apple Silicon performance
safe model lifetime/unload
clean Swift integration
complete official model coverage
```

Do not build two production Whisper backends.

---

# 8. Model Provenance Rule

The user's request is specifically for the free OpenAI Whisper models.

Therefore:

> The model *identity* must be an official OpenAI Whisper checkpoint. A runtime-specific conversion is permitted; a third-party fine-tune is not.

Allowed:

```text
OpenAI large-v3
      ↓ deterministic/runtime conversion
whisper.cpp-compatible large-v3 artifact
```

Not part of the initial feature:

```text
Distil-Whisper
community fine-tunes
domain fine-tunes
third-party optimized Whisper variants with changed weights
```

The production catalog should record enough metadata to establish provenance.

Conceptually:

```swift
struct WhisperModelDescriptor {
    let id: WhisperModelID
    let upstreamCheckpoint: String
    let runtimeArtifact: String
    let expectedSHA256: String
    let englishOnly: Bool
    let approximateDiskBytes: Int64
}
```

Exact artifact hashes should come from the selected runtime/distribution source, not be invented in Relay.

---

# 9. Existing Relay Fit

Current Relay contract:

```swift
protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: STTCapabilities { get }

    func availability() async -> BackendAvailability
    func prepare() async throws

    func transcribe(
        audio: AudioInput,
        options: STTOptions
    ) async throws -> Transcript
}
```

Current audio shape:

```swift
struct AudioInput: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}
```

That is a good fit.

Desired production shape:

```swift
final actor WhisperBackend: SpeechToTextBackend {
    let id = "whisper"
    let displayName = "OpenAI Whisper"

    // delegates to one selected model runtime
}
```

The rest of Relay should not know whether the selected model is:

```text
tiny.en
small.en
large-v3
turbo
```

---

# 10. Generalize Relay's Existing Speech-Model Abstraction

Relay's current `SpeechModelDownloading` abstraction assumes roughly:

```text
one backend
    ↓
one downloadable model
```

That works for Parakeet today, but it is too narrow for Whisper.

The right fix is **not** a Whisper-specific manager.

Generalize Relay's speech-model abstraction so any speech backend may expose:

```text
zero models
one model
many models
```

Examples:

```text
Apple Speech
    └── zero downloadable models

Parakeet
    └── parakeet-v2

OpenAI Whisper
    ├── tiny.en
    ├── tiny
    ├── base.en
    ├── base
    ├── small.en
    ├── small
    ├── medium.en
    ├── medium
    ├── large-v1
    ├── large-v2
    ├── large-v3
    └── turbo
```

Do not solve Whisper by creating twelve STT backends.

`STTRouter` should still see exactly one backend:

```text
whisper
```

The model layer should become a reusable Relay capability.

A good generalized shape is:

```swift
struct SpeechModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let detail: String?
    let approximateDownloadBytes: Int64?
}

enum SpeechModelInstallState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case downloadFailed
}

struct SpeechModelStatus: Identifiable, Equatable, Sendable {
    let descriptor: SpeechModelDescriptor
    var installState: SpeechModelInstallState
    var isSelected: Bool
    var isLoaded: Bool

    var id: String { descriptor.id }
}

protocol SpeechModelManaging: Sendable {
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

The exact names can change during implementation, but the semantics should remain.

Important distinction:

```text
downloaded ≠ selected ≠ loaded
```

For example:

```text
Whisper small.en
    downloaded = true
    selected   = true
    loaded     = false
```

is valid while Relay is idle.

On the next dictation:

```text
prepare()
    ↓
load selected model
    ↓
loaded = true
```

Likewise, a downloaded but unselected model should stay on disk without consuming inference memory.

---

## 10.1 Parakeet Should Use the Same Abstraction

Parakeet becomes the simple one-model case:

```text
backendID: parakeet

models:
    parakeet-v2
```

Conceptually:

```swift
ParakeetBackend
    +
ParakeetModelManager
```

where:

```text
models().count == 1
```

This replaces the special-case assumption encoded by `SpeechModelDownloading`.

The existing Parakeet user experience can remain effectively unchanged:

```text
Parakeet
    Download
```

The generic model API does not force the UI to show a nested selector when a backend has only one model.

---

## 10.2 Whisper Is the Multi-Model Case

Whisper uses the same interface:

```text
backendID: whisper

models:
    tiny.en
    tiny
    base.en
    base
    ...
    turbo
```

No Whisper-only downloader abstraction is required.

The UI may choose to expand a multi-model backend into a model list, but that presentation decision sits above the generic model manager.

---

## 10.3 TTS Can Reuse This Later

The abstraction should be speech-wide rather than STT-only.

That does **not** mean voices become models.

For example:

```text
PocketTTS model
    └── runtime/model asset

PocketTTS voices
    └── voice selection
```

Those remain different concepts.

But if a TTS backend later supports several heavyweight downloadable model variants, the same `SpeechModelManaging` capability can represent them.

Do not force Kokoro/PocketTTS migrations into this Whisper spike unless required to compile.

---

## 10.4 Backend Availability Still Stays Generic

`BackendCatalog` should continue answering only:

```text
Is this backend usable right now?
```

For a model-backed backend:

```text
selected model downloaded
    → backend may be .available

selected model missing
    → .modelNotDownloaded
```

The backend catalog should not become responsible for rendering or tracking every model row.

This keeps the current backend ordering/fallback architecture simple.

---

# 11. Proposed Model Components

Production direction if the spike passes:

```text
WhisperBackend
      │
      ├── WhisperModelCatalog
      │      static official model metadata
      │
      ├── WhisperModelStore
      │      disk presence
      │      download
      │      checksum verification
      │      remove
      │
      └── WhisperRuntime
             selected model
             exactly one loaded context
             transcribe
             unload
```

Responsibilities should stay separate.

---

# 12. WhisperModelCatalog

Pure metadata.

No network.

No inference state.

Example:

```swift
enum WhisperModelID: String, CaseIterable, Codable, Sendable {
    case tinyEn = "tiny.en"
    case tiny
    case baseEn = "base.en"
    case base
    case smallEn = "small.en"
    case small
    case mediumEn = "medium.en"
    case medium
    case largeV1 = "large-v1"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"
    case turbo
}
```

The spike must prove every catalog entry maps to a real runtime artifact.

---

# 13. WhisperModelStore

Owns model files on disk.

Preferred eventual location:

```text
~/Library/Application Support/Relay/Models/Whisper/
```

Example:

```text
Whisper/
├── tiny.en/
├── base.en/
├── small.en/
└── turbo/
```

The exact runtime file layout depends on the engine.

Required behavior:

```text
not downloaded
      ↓ explicit Download
temporary/incomplete file
      ↓ verify
atomic promote
      ↓
downloaded
```

Interrupted/corrupt downloads must never appear as ready.

---

# 14. WhisperRuntime

Owns heavyweight inference state.

Hard invariant:

> There is never more than one loaded Whisper inference context owned by Relay.

Conceptually:

```swift
actor WhisperRuntime {
    private var loaded: LoadedWhisperModel?

    func activate(_ model: WhisperModelID) async throws {
        if loaded?.id == model {
            return
        }

        unloadCurrentModel()
        loaded = try load(model)
    }
}
```

The real implementation must handle failures more carefully than this sketch.

A failed switch must not accidentally leave two contexts resident.

---

# 15. Switching Semantics

Preferred sequence:

```text
selected = small.en
loaded   = small.en

user selects turbo
      ↓
verify turbo exists on disk
      ↓
stop accepting new Whisper transcription
      ↓
destroy small.en inference context
      ↓
load turbo
      ↓
selected = turbo
```

If `turbo` fails to load:

```text
turbo load failed
      ↓
no corrupt half-active runtime
      ↓
surface failure
      ↓
Apple / Parakeet remain usable
```

Whether Relay automatically reloads the old Whisper model after a failed switch is a production-design decision.

The spike only needs to prove failure leaves memory/runtime state coherent.

---

# 16. Model Selection vs Download

Selecting a model that is absent should **not** automatically start a large download.

Desired interaction:

```text
Select large-v3
      ↓
Not downloaded
      ↓
Download large-v3?
```

After successful download:

```text
Downloaded
      ↓
user activates/selects
      ↓
load
```

Downloading is not loading.

Loading is not downloading.

Keep them separate.

---

# 17. Removing Models

Because the full model family can consume substantial disk space, production Relay should eventually allow downloaded Whisper models to be removed.

Rules:

```text
inactive downloaded model
      → Remove allowed

active model
      → unload/switch first
      → then Remove
```

The spike should at minimum prove a downloaded runtime artifact can be deleted and rediscovered as `notDownloaded`.

---

# 18. Memory Residency Experiment

This is one of the most important spike tests.

Test sequence:

```text
baseline Relay/probe RSS

load base.en
measure

unload base.en
measure

load small.en
measure

unload small.en
measure

load turbo
measure

unload turbo
measure
```

Then alternate:

```text
base.en ↔ small.en
```

for at least 10 switches.

Success does not require macOS RSS to return byte-for-byte to baseline because allocators/framework caches may retain pages.

Success requires:

1. the old Whisper inference context is explicitly destroyed before the new one is created;
2. memory does not approach the sum of every model ever loaded;
3. repeated model switching reaches a stable plateau rather than monotonically growing;
4. only the selected model can service transcription.

If switching models causes unbounded memory growth, the architecture fails the spike.

---

# 19. Experiment 1 — Native Runtime Build

Create a disposable probe target outside production Relay behavior.

Goal:

```text
Swift
  ↓
thin wrapper
  ↓
whisper.cpp
  ↓
base.en
```

Input:

```text
[Float]
16 kHz
mono
```

Output:

```text
String transcript
```

Pass when:

- arm64 macOS 26 builds cleanly;
- no Python process;
- no child CLI process;
- no network after model exists;
- one short prerecorded fixture transcribes successfully.

The production backend should call the library directly rather than shelling out to `whisper-cli`.

---

# 20. Experiment 2 — Official Model Catalog

Build a disposable catalog containing all canonical IDs:

```text
tiny.en
tiny
base.en
base
small.en
small
medium.en
medium
large-v1
large-v2
large-v3
turbo
```

For every entry verify:

- runtime artifact exists upstream;
- it corresponds to the intended OpenAI checkpoint;
- disk size can be reported;
- checksum/provenance can be established;
- Relay can distinguish downloaded/not-downloaded without loading it.

Aliases are not separate rows.

---

# 21. Experiment 3 — Download / Verify / Remove

Using at least:

```text
tiny.en
base.en
small.en
```

prove:

```text
notDownloaded
      ↓
download
      ↓
verify checksum
      ↓
downloaded
      ↓
remove
      ↓
notDownloaded
```

Also intentionally interrupt one download.

Pass when the interrupted artifact never becomes selectable as a ready model.

Do not require every multi-gigabyte model to be downloaded merely to prove the downloader state machine.

---

# 22. Experiment 4 — Single-Model Residency

Use at least three materially different sizes:

```text
base.en
small.en
turbo
```

Measure process memory before/after each load, unload, and switch.

Run 10 alternating switches.

Pass when the old runtime is demonstrably released and memory reaches a stable plateau.

---

# 23. Experiment 5 — All-Model Smoke Coverage

Full product support means every canonical model must be loadable.

Run one short fixed transcription through each model:

```text
tiny.en
tiny
base.en
base
small.en
small
medium.en
medium
large-v1
large-v2
large-v3
turbo
```

This can be done sequentially.

Never load multiple models concurrently.

For each model record:

```text
downloaded
load succeeded
load time
peak memory
transcription succeeded
transcription latency
unload succeeded
```

If hardware resources make a very large model impractical, Relay may still list it, but the spike must record the real behavior and decide whether the product should:

```text
support it
warn about memory
or exclude it
```

Do not claim "all models supported" without attempting them.

---

# 24. Experiment 6 — Dictation Quality Benchmark

Use one fixed prerecorded corpus across every backend.

Do not compare live takes recorded separately for each model.

Suggested corpus:

```text
10 short everyday dictations
10 coding-oriented dictations
5 punctuation-heavy dictations
5 long dictations
5 noisy/room-distance dictations
1+ non-English fixtures for multilingual smoke testing
```

Coding vocabulary should include terms Relay users actually encounter, for example:

```text
Swift
SwiftUI
Xcode
Core ML
GitHub
Claude
Codex
async await
AppModel
RelayRuntime
Unix socket
AVAudioEngine
```

Compare representative Whisper models:

```text
tiny.en
base.en
small.en
medium.en
large-v3
turbo
```

against:

```text
Parakeet v2
Apple Speech
```

Record:

- exact raw transcript
- normalized WER or edit distance
- proper-name/coding-term errors
- final transcription latency
- real-time factor
- cold model-load time
- peak process memory

The spike should not declare a winner based on one sentence.

---

# 25. Performance Target

Not every Whisper model needs to be a practical default.

The spike should identify:

```text
fastest acceptable model
best-quality practical model
best overall default candidate
```

A provisional dictation target for a recommended default candidate:

```text
5-second utterance
→ final transcript in roughly <= 2.5 seconds warm
```

That is a probe target, not a permanent product SLO.

The user may deliberately select a slower larger model for quality.

Relay should not hide those models solely because smaller models are faster.

---

# 26. Language Behavior

English-only models:

```text
tiny.en
base.en
small.en
medium.en
```

should be clearly labeled:

```text
English only
```

Multilingual models should support Whisper's multilingual transcription behavior.

Relay currently provides:

```swift
STTOptions.localeIdentifier
```

The spike should test two behaviors:

1. let multilingual Whisper auto-detect language;
2. pass a language hint derived from Relay's locale when supported by the runtime.

Do not add translation UI in this feature.

This is dictation, not speech translation.

---

# 27. Live Transcription

Out of scope.

Relay's production live interim transcription is already a separate concern and is disabled by default.

Initial Whisper scope:

```text
record
   ↓
stop
   ↓
final Whisper transcription
   ↓
insert
```

Do not combine this spike with:

```text
streaming Whisper
partial Whisper decoding
hands-free wake mode
VAD changes
```

Those can be evaluated later.

---

# 28. Cancellation / Reliability Tests

A backend intended to become part of Relay must survive:

### Cancel during model load

Expected:

```text
no stuck state
no second context
later retry works
```

### Cancel during transcription

Expected:

```text
bounded cancellation
router/coordinator returns to known state
later transcription works
```

### Model file missing after selection

Expected:

```text
availability = modelNotDownloaded/unavailable
no crash
fallback remains possible
```

### Corrupt model file

Expected:

```text
verification rejects
not marked ready
```

### Model switch after repeated transcriptions

Expected:

```text
old context unloads
new model loads
no stale transcript crosses sessions
```

### 100 sequential transcriptions

Expected:

```text
no crash
no monotonic memory leak
no runtime corruption
```

---

# 29. Privacy / Diagnostics

Whisper diagnostics may contain:

```text
model id
load duration
transcription duration
audio duration
sample count
runtime error category
download progress
model checksum result
memory measurement
```

They must not contain:

```text
raw microphone audio
transcript content
room audio files
```

Benchmark fixtures used for the spike should be explicit test assets, not silently captured user dictation.

---

# 30. Expected Production UI Direction

If the spike passes, Whisper remains one STT backend row.

Conceptually:

```text
OpenAI Whisper                     Enabled

Selected model
┌────────────────────────────┐
│ small.en                ▾  │
└────────────────────────────┘

Models

tiny.en       English       Download
tiny          Multilingual  Download
base.en       English       ✓ Downloaded
base          Multilingual  Download
small.en      English       ● Active
small         Multilingual  Download
medium.en     English       Download
medium        Multilingual  Download
large-v1      Multilingual  Download
large-v2      Multilingual  Download
large-v3      Multilingual  Download
turbo         Multilingual  ✓ Downloaded
```

Optional action for inactive downloaded models:

```text
Remove
```

Do not expose runtime-specific names like:

```text
ggml-small.en.bin
openai_whisper-small.en_XXXMB
```

as the user-facing model identity.

---

# 31. Existing Relay Settings Implication

Current `AppSettings` knows only:

```text
STT backend order
```

A production multi-model feature needs persistent **model selection**, but that should also be generalized rather than adding a Whisper-only settings field.

A likely shape is:

```swift
var selectedSpeechModelByBackend: [String: String]
```

Example:

```text
parakeet → parakeet-v2
whisper  → small.en
```

This keeps backend model selection generic while leaving model-specific metadata in each backend's model manager.

Downloaded model presence should come from disk, not settings.

Do not persist:

```text
downloaded = true
loaded = true
```

because:

```text
disk is the source of truth for installation
runtime is the source of truth for loaded state
settings only persist selection
```

The exact schema shape belongs in the later production design, but the spike should prove this generalized direction is sufficient.

---

# 32. Existing Backend Catalog Implication

Relay's generic STT catalog should continue to answer:

```text
Is this backend usable right now?
```

For Whisper:

```text
selected model exists + validates
    → .available

selected model absent
    → .modelNotDownloaded
```

The nested list of models should not be forced into `BackendCatalog`.

Instead, `AppModel`/Settings can receive generic per-backend model managers:

```swift
let speechModelManagers: [String: any SpeechModelManaging]
```

replacing today's narrower:

```swift
let speechModelDownloaders: [String: any SpeechModelDownloading]
```

This keeps backend status and model status as separate concerns while making model management reusable.

---

# 33. Fallback Behavior

Existing router semantics should remain authoritative.

Example configuration:

```text
1. OpenAI Whisper — small.en
2. Parakeet
3. Apple Speech
```

If Whisper is unavailable:

```text
Whisper
   ✕
   ↓
Parakeet
```

No Whisper-specific fallback logic should be embedded in `DictationCoordinator`.

---

# 34. Recommended Default

Do not choose the production default during design.

Benchmark first.

Likely candidates worth special attention:

```text
small.en
turbo
```

But the decision should come from measured:

```text
quality
warm latency
cold load time
memory
coding vocabulary
stability
```

on the actual target Mac.

---

# 35. GO Criteria

Proceed to a production Whisper design if all are true:

1. a native runtime integrates without Python/PyTorch;
2. all canonical official OpenAI Whisper model IDs have a trustworthy runtime artifact path;
3. at least one model provides good enough dictation latency/quality to be useful;
4. Relay can explicitly download and verify models through a generalized `SpeechModelManaging` capability;
5. the same abstraction cleanly represents Parakeet as a one-model backend and Whisper as a multi-model backend;
6. downloaded-state detection requires no inference load;
7. the selected model can be loaded on demand;
8. switching models destroys the previous inference context first;
9. repeated switching does not accumulate model memory;
10. 100 sequential transcriptions are stable;
11. Whisper consumes existing `AudioInput`;
12. Apple Speech and Parakeet remain unaffected;
13. failure can cleanly fall through via the existing router.

---

# 36. CONDITIONAL GO

Proceed with a reduced catalog if:

```text
runtime is solid
+
small/medium models work well
+
one or more very large models are impractical on the target Mac
```

In that case the results must say exactly which official models are supported and why others are omitted.

Do not silently label partial coverage as "all Whisper models."

---

# 37. NO-GO Criteria

Do not integrate the candidate runtime if:

- it requires Python/PyTorch in the shipping app;
- it cannot release model inference memory predictably;
- repeated model switches leak/accumulate memory;
- it requires separate microphone ownership;
- model provenance cannot be established;
- failure can destabilize core dictation;
- Apple/Parakeet regress because of the dependency;
- no tested Whisper model reaches useful dictation latency on the target Mac.

If `whisper.cpp` fails for integration-specific reasons, evaluate WhisperKit before abandoning Whisper entirely.

---

# 38. Proposed Spike Sequence

```text
Experiment 1
Native whisper.cpp + base.en
        │
        ▼
Experiment 2
official model catalog/provenance
        │
        ▼
Experiment 3
download / verify / remove
        │
        ▼
Experiment 4
single-model residency + switching
        │
        ▼
Experiment 5
all-model smoke test
        │
        ▼
Experiment 6
dictation benchmark vs Parakeet + Apple
        │
        ▼
Experiment 7
100-run stability + cancellation/failure
        │
        ▼
DECIDE
```

---

# 39. Suggested Spike Output

Create:

```text
docs/superpowers/spikes/
2026-09-18-openai-whisper-models-feasibility-results.md
```

The result should include:

```text
runtime tested
runtime version/commit

model catalog result

per-model:
    disk size
    load time
    peak memory
    short-fixture transcript
    transcription latency
    unload result

memory-switch graph/table

benchmark results:
    Whisper variants
    Parakeet
    Apple Speech

download/interruption result

100-run stability result

GO / CONDITIONAL GO / NO-GO
```

---

# 40. Recommendation Before Running the Spike

Start with:

```text
whisper.cpp
```

rather than WhisperKit.

Reason:

```text
OpenAI official model family
        ↓
whisper.cpp has direct broad model parity
        ↓
native Apple Silicon runtime
        ↓
explicit model/context lifetime
        ↓
good fit for Relay's one-model-resident requirement
```

Do **not** begin by wiring model-selection UI into Relay.

First prove:

```text
native inference
model provenance
download lifecycle
one-model memory lifecycle
dictation quality
```

in disposable spike code.

If those pass, write a production design that adds:

```text
SpeechModelManaging          ← generalized Relay abstraction

ParakeetModelManager         ← one-model implementation
WhisperBackend
WhisperModelManager          ← multi-model implementation
WhisperModelCatalog
WhisperModelStore
WhisperRuntime
generic model-management UI
generic selected-model settings
```

while preserving the existing STT router and microphone pipeline.

---

# 41. Upstream Sources Checked

## OpenAI Whisper

Repository:

```text
https://github.com/openai/whisper
```

Relevant files:

```text
README.md
whisper/__init__.py
LICENSE
```

Facts used:

- official checkpoint names
- model family/parameter counts
- English-only vs multilingual variants
- `large` alias → `large-v3`
- `turbo` / `large-v3-turbo` aliasing
- MIT license for code/model weights

## whisper.cpp

Repository:

```text
https://github.com/ggml-org/whisper.cpp
```

Facts used:

- macOS Intel/Arm support
- Apple Silicon/Metal support
- optional Core ML acceleration
- C API
- official Whisper model coverage
- approximate runtime disk/memory examples
- quantization capability

## Relay

Repository:

```text
https://github.com/cupsadarius/relay
```

Baseline:

```text
d17988ceba55c9c7604cce60fc47ae3dbe032fb3
```

Relevant files:

```text
Relay/SpeechIn/SpeechToTextBackend.swift
Relay/Domain/SpeechModels.swift
Relay/App/RelayRuntime.swift
Relay/App/BackendCatalog.swift
Relay/App/SpeechBackendCatalog.swift
Relay/Domain/AppSettings.swift
```

---

# 42. Final Position

The desired product is:

```text
Relay
  │
  ├── Apple Speech
  ├── Parakeet
  └── OpenAI Whisper
         │
         ├── tiny.en
         ├── tiny
         ├── base.en
         ├── base
         ├── small.en
         ├── small
         ├── medium.en
         ├── medium
         ├── large-v1
         ├── large-v2
         ├── large-v3
         └── turbo
```

with:

```text
many may be downloaded
exactly one may be loaded
downloads are explicit
dictation is local
no API key
no cloud STT
no Python runtime
```

That is the architecture this spike should prove.
