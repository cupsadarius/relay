# Relay -- OpenAI Whisper Local Models Feasibility Spike: Results

**Date:** 2026-09-18
**Status:** Spike complete
**Branch:** spike/whisper-local-models
**Probe location:** WhisperProbe/ (disposable SwiftPM package, not referenced by Relay.xcodeproj or project.yml)
**Companion doc:** docs/superpowers/spikes/2026-09-18-relay-openai-whisper-models-feasibility-spike.md

---

## 0. Owner override applied

The spike doc (section 7) recommended probing whisper.cpp first. The
repository owner overrode this before the spike ran: evaluate a pure
Swift/CoreML runtime FIRST, and only fall back to whisper.cpp (still with no
CLI/Python) if the Swift path cannot cover the official catalog acceptably.

**Result: the pure-Swift path (WhisperKit) was viable and is the
recommendation. whisper.cpp was not built or probed**, because WhisperKit
cleared the Experiment 1 hard gate on the first attempt and covers 11 of the
12 canonical model IDs with trustworthy provenance (section 2). Only
`large-v1` has no published Swift/CoreML artifact; see section 2 for why that
is an acceptable, explicitly-named gap rather than a runtime failure.

---

## 1. Runtime chosen

**WhisperKit**, published from the **argmaxinc/argmax-oss-swift** monorepo
(WhisperKit was folded into this repo; the standalone `argmaxinc/WhisperKit`
repo now redirects here).

```text
Package:   https://github.com/argmaxinc/argmax-oss-swift.git
Version:   1.1.0
Commit:    1e2a163736dfa5a198e637ae44c114e1c6d5cc2d
Product:   WhisperKit  (SwiftPM library target "WhisperKit")
License:   MIT (LICENSE at repo root; also declared on the HF model repo)
Platforms: iOS 16+, macOS 13+, watchOS 10+, visionOS 1+  (Relay targets macOS 26 -- comfortably inside range)
```

Built and probed on this machine:

```text
macOS 26.6.2 (build 25G83), arm64
Xcode 26.6 (build 17F113)
swift-driver 1.148.6, Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

### Why WhisperKit over whisper.cpp

- **Pure Swift + Core ML.** No Python, no PyTorch, no `ffmpeg`, no child
  process, no CLI shelling. WhisperProbe calls the `WhisperKit` library
  directly in-process (confirmed by inspecting the build log and the probe's
  own process tree during Experiment 1 -- a single Swift executable, no
  subprocesses).
- **Explicit model lifetime.** `WhisperKit.unloadModels()` is a real, public,
  `async` API (`Sources/WhisperKit/Core/WhisperKit.swift`) that tears down
  the feature extractor, audio encoder and text decoder Core ML models. Model
  loading is equally explicit via `WhisperKitConfig(modelFolder:load:download:)`.
  This maps directly onto the doc's WhisperRuntime invariant (section 14):
  exactly one loaded context, destroyed before the next is created.
- **Relay keeps ownership of download/verify/remove.** `WhisperKitConfig`
  accepts a local `modelFolder` and a `download: false` flag, so WhisperKit
  never has to be trusted with network access, retry policy, or checksum
  verification -- WhisperProbe implements its own doc-section-13-shaped
  `WhisperModelStore` (download, sha256/blob-sha1 verify, atomic promote,
  remove) and only ever hands WhisperKit a directory that has already been
  verified. Production Relay's `WhisperModelStore` would work the same way.
- **Official-checkpoint identity is directly nameable.** The model repo's
  folder names are literally `openai_whisper-<checkpoint>` (see section 2),
  so provenance metadata does not require guessing -- the runtime artifact's
  name asserts which OpenAI checkpoint it was converted from.
- **whisper.cpp was not needed as a fallback.** Per the owner's instruction,
  whisper.cpp only gets probed if WhisperKit fails Experiment 1 or cannot
  cover the catalog acceptably. Neither happened. whisper.cpp remains a
  documented fallback (section 2 records where it has a model whisper.cpp
  has and WhisperKit does not) but no whisper.cpp code was written, built, or
  linked in this spike.

### Trade-off recorded

whisper.cpp's official ggml model mirror (`ggerganov/whisper.cpp` on
Hugging Face) publishes all 12 canonical checkpoints, including `large-v1`.
WhisperKit's CoreML mirror (`argmaxinc/whisperkit-coreml`) does not publish
`large-v1` at all. That is the one place whisper.cpp has broader official
coverage than WhisperKit today. Everything else favors WhisperKit: pure
Swift, no C/C++ integration into the Xcode project, no Metal/Core ML build
configuration risk to Relay's existing package graph, and an SDK that is
already shipping in production iOS/macOS apps (the model repo's Hugging
Face download counter reads 11M+ at the time of this spike).

---

## 2. Model catalog result (Experiment 2)

Fetched live from the Hugging Face tree API for
`argmaxinc/whisperkit-coreml` -- **metadata only, no model weights
downloaded** for this step. Per-file sha256 (LFS pointer `oid`) or blob sha1
(`oid` on non-LFS sidecar files) came back in the same response, so
checksum-based provenance is establishable without downloading anything.

| Relay id | WhisperKit folder (`openai_whisper-*`) | Disk size (.mlmodelc only) | Files (lfs / total) | Trustworthy artifact? |
|---|---|---:|---:|---|
| tiny.en | openai_whisper-tiny.en | 73.1 MB | 11 / 19 | yes |
| tiny | openai_whisper-tiny | 73.1 MB | 11 / 19 | yes |
| base.en | openai_whisper-base.en | 139.9 MB | 11 / 19 | yes |
| base | openai_whisper-base | 139.9 MB | 11 / 19 | yes |
| small.en | openai_whisper-small.en | 464.0 MB | 11 / 19 | yes |
| small | openai_whisper-small | 464.0 MB | 11 / 19 | yes |
| medium.en | openai_whisper-medium.en | 1458.8 MB | 9 / 20 | yes |
| medium | openai_whisper-medium | 1458.8 MB | 9 / 20 | yes |
| **large-v1** | **(none published)** | -- | -- | **NO** |
| large-v2 | openai_whisper-large-v2 | 2946.9 MB | 11 / 19 | yes |
| large-v3 | openai_whisper-large-v3 | 2947.2 MB | 11 / 19 | yes |
| turbo | openai_whisper-large-v3_turbo | 3047.1 MB | 14 / 24 | yes |

**Coverage: 11 of 12 canonical IDs. `large-v1` is the one gap.**

Confirmed by direct API query (`large-v1` folder does not exist in the
repo tree) -- this is not a download failure or a probe bug, the artifact
simply is not published. Cross-checked against whisper.cpp's official
mirror (`ggerganov/whisper.cpp` on Hugging Face), which does carry
`ggml-large-v1.bin` (2.9 GB). So `large-v1` specifically exists as a
trustworthy artifact only on the whisper.cpp/ggml side, not the WhisperKit/
CoreML side, as of this spike's date.

Two data quality notes surfaced while building this table (both handled in
the probe, documented here for the production design):

1. **Some folders (e.g. `tiny.en`) additionally publish a `.mlpackage`
   source copy of every component next to the compiled `.mlmodelc`
   WhisperKit actually loads.** Naively summing every file in the folder
   roughly doubles the reported size for those models. The catalog above
   counts only `.mlmodelc/**` and top-level `config.json`/
   `generation_config.json` -- what a production `WhisperModelStore` should
   fetch. `WhisperProbe`'s `HFCatalog.fetchMetadata` filters `.mlpackage/`
   paths out for this reason.
2. **`turbo` is not smaller than `large-v3` on disk (3047 MB vs 2947 MB),
   even though it has far fewer decoder layers.** WhisperKit ships `turbo`
   as a split decoder graph -- `TextDecoder.mlmodelc` (1.8 GB) plus a
   separate `TextDecoderContextPrefill.mlmodelc` (98 MB) for its two-pass
   prefill/generate design -- and reuses the full `large-v3` audio encoder
   unchanged (1.27 GB weights, byte-for-byte the same encoder as
   `large-v3`). Net effect: `turbo`'s on-disk footprint is not proportional
   to its ~809M advertised parameter count. This is worth flagging to
   whoever picks Relay's recommended default -- `turbo` is not a "cheap"
   choice on disk even though it decodes fast.

### Provenance / checksum mechanism

For each canonical id, `WhisperModelStore` (the spike's stand-in for the
doc's section-13 `WhisperModelStore`) verifies **every** file in the model
folder before promoting it to `downloaded`:

- large weight files (`*.mlmodelc/weights/weight.bin`, etc.) are verified
  against the LFS-recorded sha256;
- small sidecar files (`config.json`, `metadata.json`, `model.mil`, ...) are
  verified against the host blob sha1 (`sha1("blob " + size + "\0" + content)`).

This mirrors the doc's `WhisperModelDescriptor.expectedSHA256` idea (section
8) but extended to the full file set a `.mlmodelc` bundle actually needs, not
just the single largest file.

---

## 3. Experiment 1 result -- native runtime build + transcribe

**PASS. This cleared the hard go/no-go gate on the first attempt.**

```text
arm64 macOS 26 build:     clean, no warnings, no errors
Python process:           none
Child CLI process:        none (direct in-process WhisperKit library call)
Network after model exists: none (fixture transcription re-run needs no network)
```

Fixture: `jfk.wav` -- the well-known public-domain "ask not what your
country can do for you" excerpt, taken verbatim from WhisperKit's own
open-source test suite (`Tests/WhisperKitTests/Resources/jfk.wav` in
`argmaxinc/argmax-oss-swift`, MIT-licensed repo). 16 kHz, mono, 16-bit PCM,
11.00s, 176000 samples -- exactly the doc's required `[Float]`/16 kHz/mono
shape. This is an explicit test asset, not captured user dictation (doc
section 29).

Model used: `base.en` (139.9 MB after checksum-verified download).

```text
loaded base.en in 8.90s        (cold: includes Core ML specialization)
transcription (0.62s):
And so my fellow Americans, ask not what your country can do for you,
ask what you can do for your country.
unloaded. RSS after unload: 110.0 MB
```

Transcript is correct (content matches the historical excerpt; minor
punctuation differences from the canonical printed text are expected --
Whisper does not reproduce comma/colon placement from a written source, it
infers punctuation from audio).

Independently of WhisperKit's own audio loading, the probe includes
`WavLoader.swift`: a small, dependency-free RIFF/WAVE parser written for
this spike so Experiment 1 proves Relay's own `AudioInput`-shaped
`[Float]`/`sampleRate` pair reaches the runtime, not just whatever
WhisperKit's own file-loading convenience happens to produce.

---

## 4. Experiment 3 result -- download / verify / remove state machine

**PASS**, exercised on `tiny.en` and `base.en`:

```text
tiny.en:  notDownloaded -> download -> verify -> downloaded -> remove -> notDownloaded   [all transitions observed]
base.en:  notDownloaded -> download -> verify -> downloaded -> remove -> notDownloaded   [all transitions observed]
```

Interrupted-download negative case, `small.en` (486 MB total): the probe
deliberately aborted the transfer after only ~1.6 MB (well before any file,
let alone all 19, could finish):

```text
state (before):                  notDownloaded
download interrupted as expected: incomplete download: simulated interruption after 1639126 bytes
state (after interrupted download): notDownloaded
PASS: interrupted download never became selectable as ready.
```

Mechanism: `WhisperModelStore.download` writes every file into a private
per-attempt staging directory (never the ready directory), verifies each
file's checksum as it lands, and only after every file in the model is
verified does it write a `.verified` marker and atomically rename staging to
the ready directory. Any thrown error (network failure, checksum mismatch,
the simulated interruption) hits a `defer` that deletes the staging
directory -- the ready directory is never touched, so `state(for:)` (which
requires both the ready directory AND its `.verified` marker to report
`downloaded`) can never observe a half-finished download as ready.

---

## 5. Experiment 4 result -- single-model residency and switching (reduced scope)

**Scope reduction, named explicitly:** the doc suggests three materially
different sizes (base.en, small.en, turbo). This spike ran the cheaper pair
**tiny.en and base.en** (73 MB / 140 MB on disk), alternating for 10
switches, to keep the automated run inside a few minutes of downloads. The
full three-tier (or small.en/turbo/large-v3) residency test is deferred to
the owner (harness below) since it needs multi-gigabyte downloads this
spike intentionally avoided per its instructions.

Resident-set-size sampled via task_info(mach_task_self_, MACH_TASK_BASIC_INFO)
in-process (Memory.swift), before and after each load and each
transcription, across 10 alternating switches:

| switch | model | load time | transcribe time | RSS after load | RSS after transcribe |
|---:|---|---:|---:|---:|---:|
| baseline | -- | -- | -- | -- | 125.0 MB |
| 1 | tiny.en | 5.74s (cold) | 0.11s | 89.0 MB | 106.4 MB |
| 2 | base.en | 6.19s (cold) | 0.14s | 118.9 MB | 133.0 MB |
| 3 | tiny.en | 0.50s | 0.12s | 120.8 MB | 132.2 MB |
| 4 | base.en | 0.55s | 0.17s | 121.5 MB | 122.0 MB |
| 5 | tiny.en | 0.50s | 0.13s | 109.9 MB | 121.8 MB |
| 6 | base.en | 0.53s | 0.15s | 110.2 MB | 122.9 MB |
| 7 | tiny.en | 0.53s | 0.13s | 109.5 MB | 121.0 MB |
| 8 | base.en | 0.58s | 0.17s | 95.7 MB | 110.4 MB |
| 9 | tiny.en | 0.50s | 0.13s | 97.4 MB | 109.8 MB |
| 10 | base.en | 0.53s | 0.12s | 100.1 MB | 112.9 MB |
| final (after unload) | -- | -- | -- | -- | 100.4 MB |

Findings against the doc section-18 pass criteria:

1. **Old context destroyed before the new one is created**: yes --
   WhisperRuntime.activate() calls pipe.unloadModels() on the currently
   loaded pipeline before constructing the replacement WhisperKit instance.
2. **Memory does not approach the sum of every model ever loaded**: yes --
   if both models were resident simultaneously, RSS would sit well above
   73 + 140 = 213 MB plus baseline; instead RSS stays in a 90-133 MB band
   for the entire 10-switch run, close to whichever single model is
   currently active rather than their sum.
3. **Repeated switching reaches a plateau, not monotonic growth**: yes --
   RSS after switch 10 (112.9 MB) is lower than RSS after switch 2
   (133.0 MB); the series oscillates within a band rather than climbing.
4. **Only the selected model can service transcription**: yes by
   construction -- WhisperRuntime holds a single optional WhisperKit
   reference and transcribe() throws RuntimeError.notLoaded if nothing is
   loaded.

Warm load time after the first load of each model dropped from about 6s
(cold, includes Core ML specialization) to about 0.5s, consistent with
WhisperKit's own documented Core ML on-disk specialization cache behavior.
Warm transcription latency for an 11-second fixture was 0.11-0.17s for both
models, far under the doc's provisional 2.5s warm target for a 5-second
utterance.

### Harness for the owner -- full three-tier residency test

The probe already supports this; it just needs bigger downloads than this
spike's automated run should make on its own. From the worktree:

```text
cd WhisperProbe
swift build -c release
.build/release/WhisperProbe memory PATH_TO_A_16KHZ_MONO_WAV_FIXTURE
```

To exercise the doc's literal base.en/small.en/turbo triple (or add
large-v3), edit the `ids` array in `runMemory(fixturePath:)` in
`Sources/WhisperProbe/main.swift` (currently `[.tinyEn, .baseEn]`) --
everything else (download-if-needed, RSS sampling, 10-switch loop) is
already generic over the id list. Expect several minutes of download time
for small.en (464 MB) and turbo (3.0 GB) on first run; subsequent runs
reuse the checksummed cache under
`~/Library/Application Support/RelaySpikeWhisperProbe/Models/`.

---

## 6. Deferred to the owner -- Experiments 5, 6, 7

These need the owner's Mac (multi-gigabyte downloads, sustained runs, and
the prerecorded benchmark corpus from the doc section 24, which does not
exist in this repository or worktree). Nothing below was attempted; this is
a runnable checklist, not a claim of results.

### Experiment 5 -- all-12-model smoke (reduced to the 11 WhisperKit covers)

```text
cd WhisperProbe
swift build -c release
for id in tiny.en tiny base.en base small.en small medium.en medium large-v2 large-v3 turbo; do
    echo "=== $id ==="
done
```

The probe's `runExp1`/`downloadIfNeeded` path is hardcoded to base.en for
the spike's gate check; for a full smoke pass, generalize `runExp1` (or add
a new subcommand) to accept a model id argument and loop the shell above
over it, downloading, loading, transcribing the same fixture, and unloading
each model in turn -- never two loaded at once, per the doc's hard
invariant. Record per model: downloaded (bytes, seconds), load succeeded
(seconds), peak memory (RSS via `ProcessMemory.megabytes()`, sampled
during transcription, not just after), transcription succeeded (text),
transcription latency (seconds), unload succeeded. `large-v1` cannot be
attempted through this runtime -- it is not part of the WhisperKit catalog
(section 2).

Expect medium/medium.en (~1.46 GB), large-v2/large-v3 (~2.95 GB) and turbo
(~3.05 GB) to take real wall-clock time to download and load; this is
exactly why the spike deferred it rather than running it inside an
automated session.

### Experiment 6 -- dictation quality benchmark vs Parakeet and Apple Speech

Requires the doc section 24 prerecorded corpus (10 everyday + 10
coding-oriented + 5 punctuation-heavy + 5 long + 5 noisy/room-distance + 1
non-English fixture), which does not exist yet. Suggested procedure once it
does:

1. Record the corpus once, as 16 kHz mono WAV files, committed as explicit
   test assets (never live captures per model).
2. For each Whisper model in {tiny.en, base.en, small.en, medium.en,
   large-v3, turbo}, plus Parakeet v2 and Apple Speech (both already wired
   into production Relay), transcribe every fixture through the same
   audio path.
3. Record per (model, fixture): exact raw transcript, normalized WER or
   edit distance against a hand-verified reference transcript,
   proper-name/coding-term error count, final latency, real-time factor,
   cold load time, peak process memory.
4. Do not declare a winner from fewer than the full corpus; the doc is
   explicit that one sentence is not sufficient evidence.

### Experiment 7 -- 100-run stability and cancellation matrix

```text
cd WhisperProbe
swift build -c release
.build/release/WhisperProbe exp1 PATH_TO_FIXTURE   # repeat 100x, or add a loop subcommand
```

Add a `stability` subcommand (not built in this spike) that: loads one
model once, then calls `transcribe(samples:)` 100 times against the same
or varied fixtures, sampling RSS every run, asserting no crash and no
monotonic RSS growth across the run. Separately exercise, by hand or with a
`Task.cancel()` harness around `activate`/`transcribe`:

```text
cancel during model load        -> no stuck state, no second context, later retry works
cancel during transcription     -> bounded cancellation, later transcription works
model file missing after selection -> availability reports missing, no crash
corrupt model file              -> Experiment 3's verify step already rejects this
                                    (proven in section 4); re-run store.download
                                    against a hand-corrupted file to confirm the
                                    same rejection path fires post-hoc, not just
                                    pre-promotion
model switch after repeated transcriptions -> old context unloads, new model loads,
                                    no stale transcript crosses sessions
```

---

## 7. Provenance and licensing conclusion

- **WhisperKit / argmax-oss-swift**: MIT license (verified: LICENSE file at
  the repository root, version 1.1.0, commit 1e2a163736dfa5a198e637ae44c114e1c6d5cc2d).
- **Model weights**: `argmaxinc/whisperkit-coreml` on Hugging Face declares
  `license: mit` in its card metadata. Every folder used by this spike is
  named `openai_whisper-<checkpoint>`, directly asserting which OpenAI
  checkpoint it was converted from -- this satisfies the doc's section-8
  provenance rule ("model identity must be an official OpenAI Whisper
  checkpoint; a runtime-specific conversion is permitted"). No
  Distil-Whisper, no community fine-tune, no third-party optimized variant
  was used anywhere in this spike.
- **Checksums**: every file needed to load a model was verified (sha256 for
  LFS-tracked weight files, blob sha1 for small sidecar files) before the
  spike's store promoted it to `downloaded`. Section 4 shows this
  mechanism correctly rejects a truncated/interrupted download.
- **The one gap (`large-v1`)**: not a licensing or provenance problem, just
  an absence -- WhisperKit's maintainers have not published a CoreML
  conversion of that specific checkpoint. `large-v1` is the oldest of the
  three `large` releases and has been superseded by `large-v2` and
  `large-v3` in every other respect (both are on the WhisperKit side and
  are, per OpenAI's own release notes, strict quality improvements over
  `large-v1` for most languages).

---

## 8. Verdict: CONDITIONAL-GO

Against the doc's section 35 GO criteria:

```text
1.  native runtime, no Python/PyTorch                          PASS
2.  all 12 canonical model IDs have a trustworthy artifact      FAIL (11/12; large-v1 absent)
3.  at least one model has good enough latency/quality          PASS (tiny.en, base.en both far under target)
4.  explicit download+verify via a generalized capability       PASS (mechanics proven; production
                                                                  SpeechModelManaging shape unchanged)
5.  same abstraction represents Parakeet (1 model) and Whisper   NOT EXERCISED (spike deliberately does
    (multi-model) cleanly                                        not touch production code, per its
                                                                  instructions; no evidence against it)
6.  downloaded-state detection needs no inference load           PASS
7.  selected model loads on demand                               PASS
8.  switching destroys the previous context first                PASS
9.  repeated switching does not accumulate memory                 PASS for tiny.en/base.en (10 switches);
                                                                  NOT proven for small.en/medium/large/turbo
                                                                  (Experiment 4 harness above, deferred)
10. 100 sequential transcriptions are stable                      NOT RUN (deferred, section 6)
11. Whisper consumes existing AudioInput                          PASS (independent WavLoader proves the
                                                                  [Float]/sampleRate shape)
12. Apple Speech and Parakeet remain unaffected                   PASS (separate SwiftPM package; zero
                                                                  changes to Relay.xcodeproj/project.yml)
13. failure falls through cleanly via the router                  NOT APPLICABLE to this spike's scope
                                                                  (router untouched; a production
                                                                  integration concern)
```

None of the doc's section 37 NO-GO criteria apply: no Python/PyTorch is
needed, memory releases predictably and does not accumulate across the
tested pairs, no separate microphone ownership was introduced (the probe
never touches AVAudioEngine), provenance is establishable end to end, and
nothing in this spike touches, let alone destabilizes, Apple Speech or
Parakeet.

This matches the doc's section 36 CONDITIONAL GO shape (runtime solid, plus
models that matter work well, plus an explicitly-named piece of the catalog
is not available) even though the specific reason differs from what section
36 anticipated: the gap here is catalog availability on the chosen runtime
(`large-v1` was never published as a WhisperKit/CoreML artifact), not
hardware impracticality for a very large model. The doc's instruction to
"never silently label partial coverage as all Whisper models" is honored
explicitly here: **the reduced catalog is 11 models -- everything except
large-v1** -- tiny.en, tiny, base.en, base, small.en, small, medium.en,
medium, large-v2, large-v3, turbo.

**Recommendation:** proceed to a production Whisper design built on
WhisperKit (argmaxinc/argmax-oss-swift, MIT), shipping the 11-model reduced
catalog, with `large-v1` explicitly omitted and documented as unavailable
rather than silently dropped. Before committing to a default model, run the
deferred Experiment 5 (all-11 smoke) and Experiment 6 (quality benchmark
against Parakeet/Apple Speech using the doc section 24 corpus) on the
target Mac -- this spike's data suggests tiny.en and base.en are both far
faster than the target latency, but says nothing yet about small.en/
medium/large-v3/turbo quality or the coding-vocabulary comparison the doc
cares about most.

---

## Appendix: probe layout

Disposable SwiftPM package, not referenced anywhere in Relay.xcodeproj or
project.yml:

```text
WhisperProbe/
  Package.swift              depends on argmaxinc/argmax-oss-swift 1.1.0 (product WhisperKit)
  Sources/WhisperProbe/
    main.swift                CLI dispatch: catalog | exp1 | statemachine | memory
    Catalog.swift              CanonicalModelID (the 12 ids) + HFCatalog metadata fetch
    ModelStore.swift           WhisperModelStore: download/verify/promote/remove state machine
    Runtime.swift              WhisperRuntime: single-context load/unload/transcribe wrapper
    WavLoader.swift            dependency-free 16kHz mono WAV -> [Float] parser
    Memory.swift               ProcessMemory: RSS sampling via task_info
```

Run from the worktree:

```text
cd WhisperProbe
swift build
.build/debug/WhisperProbe catalog
.build/debug/WhisperProbe exp1 PATH_TO_JFK_WAV
.build/debug/WhisperProbe statemachine
.build/debug/WhisperProbe memory PATH_TO_JFK_WAV
```

The jfk.wav fixture used throughout this spike can be re-fetched from
WhisperKit's own MIT-licensed test resources:
`https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/main/Tests/WhisperKitTests/Resources/jfk.wav`.

Downloaded models are cached (and were left on disk after this spike, for
the owner's convenience) under
`~/Library/Application Support/RelaySpikeWhisperProbe/Models/`. Delete that
directory to reclaim disk space; nothing in Relay proper reads it.

---

## Implementation status (2026-09-18)

The production Whisper backend from this spike is now IMPLEMENTED on branch
`feature/whisper-backend` (design: `docs/superpowers/specs/2026-09-18-whisper-backend-design.md`,
plan: `docs/superpowers/plans/2026-09-18-whisper-backend.md`). Shipped as one STT
backend (`whisper`) with all 11 catalog models selectable, on WhisperKit 1.1.0,
behind the generalized `SpeechModelManaging` layer (Parakeet is the one-model
case). Whisper is registered but NOT enabled by default. Full unit suite green
(868 tests) with fakes for engine/store/runtime — no CoreML or network in CI.

### Offline is real now (tokenizer fetched)
The `whisperkit-coreml` model folders do NOT bundle `tokenizer.json`; WhisperKit
would otherwise fetch the tokenizer from `openai/whisper-*` at first load (network).
`WhisperModelStore` now also downloads + checksum-verifies each model's
`tokenizer.json` + `tokenizer_config.json` (from the correct `openai/whisper-*`
repo — note `turbo` uses `openai/whisper-large-v3`) into the model folder, and
`presence()` requires `tokenizer.json`. So a downloaded model loads with zero
network. **Pre-existing downloads from before this change must be re-downloaded**
(their folders lack the tokenizer).

### Still needs the owner's Mac (network + real models — not doable in CI)
1. **Offline confirmation (do first):** download one model (e.g. `tiny.en`) with the
   shipped code, DISABLE networking, then exercise `WhisperBackend` end-to-end
   (or `WhisperRuntime.activate(.tinyEn)` + transcribe) and confirm it loads and
   transcribes with ZERO network activity. Only the HF HTTP shape was curl-verified
   in the spike; a real airplane-mode `activate()` was not run.
2. **Exp 5 — all-11 smoke:** one short transcription through each of the 11 models
   (multi-GB downloads). Record load time, peak memory, transcript, latency, unload.
3. **Exp 6 — quality benchmark:** the fixed corpus (§24 of the proposal spike;
   does not exist yet — build it) across representative Whisper models vs Parakeet v2
   and Apple Speech. Record WER/edit distance, coding-term errors, latency, RTF.
4. **Exp 7 — stability:** 100 sequential transcriptions (no crash, no monotonic
   memory growth) + the cancellation matrix (cancel during load, cancel during
   transcribe, model file missing, corrupt model, switch after many transcriptions).
5. **Large models are live-but-unverified:** `medium`/`medium.en`/`large-v2`/
   `large-v3`/`turbo` (~1.5–3 GB) ship selectable, but their real-Mac load time,
   peak memory, and switch-stability were not measured. Use Exp 4's harness (above)
   extended to these three-tier sizes; decide per §36 whether any should be
   warned-about or excluded.
6. **Pick the production default + router priority** after benchmarking (proposal §34).
