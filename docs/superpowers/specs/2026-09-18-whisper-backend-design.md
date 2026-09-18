# Relay — OpenAI Whisper STT Backend: Design Spec

**Date:** 2026-09-18
**Status:** Approved design, pre-implementation
**Repository baseline:** `main` at `14f152e`
**Feasibility inputs:** `docs/superpowers/spikes/2026-09-18-relay-openai-whisper-models-feasibility-spike.md` (proposal) and `2026-09-18-openai-whisper-models-feasibility-results.md` (spike results, verdict CONDITIONAL-GO on WhisperKit)

---

## 1. Goal

Add OpenAI Whisper as a **single** local, on-device STT backend in Relay, exposing the official
OpenAI Whisper checkpoint family as selectable, explicitly-downloaded models with exactly one
model resident in inference memory at a time. Whisper model variants are **not** separate Relay
backends — the router sees one backend, `whisper`, with an internally selected model.

This merge ships the full backend and UI with **all supported models live**, per the owner's
decision. The one official checkpoint WhisperKit cannot serve, `large-v1`, is excluded (spike §2);
the shipped catalog is the remaining **11** IDs.

Non-goals for this merge: live/interim Whisper transcription, streaming/partial decoding,
hands-free/VAD changes, speech translation, TTS migration to the new abstraction, choosing a
benchmarked production default.

---

## 2. Hard requirements (from the spike, restated as acceptance criteria)

1. Whisper runs locally; dictation audio is never uploaded.
2. Model downloads are explicit user actions; dictation never silently downloads a model.
3. Relay shows per-model state: not-downloaded / downloading / downloaded / active / failed.
4. Only the selected model is loaded for inference; switching unloads the previous context first.
5. No Python, PyTorch, or CLI subprocess in the shipping app.
6. Only official OpenAI checkpoints (a runtime CoreML conversion is allowed; third-party
   fine-tunes are not).
7. Apple Speech and Parakeet backends stay behaviourally unchanged.
8. Whisper consumes Relay's existing `AudioInput`; it never owns the microphone.
9. A Whisper failure stays isolated behind `STTRouter`; existing fallback is unchanged.

---

## 3. Runtime: WhisperKit

- Dependency: `argmaxinc/argmax-oss-swift`, product `WhisperKit`, pinned `exactVersion: 1.1.0`,
  added to `project.yml` `packages` and the `Relay` target dependencies. Pure Swift/Core ML, MIT.
- Relay calls the `WhisperKit` library directly. No `whisper-cli`, no child process, no Python.
- Model lifetime is explicit: `WhisperKit.unloadModels()` tears down the inference context;
  loading is via `WhisperKitConfig(modelFolder:load:download:)`.
- **Relay owns download/verify/remove.** WhisperKit is always handed a `modelFolder` that Relay
  has already populated and verified, with `download: false` and `load` controlled by the runtime.
  WhisperKit never reaches the network on Relay's behalf.

---

## 4. Model catalog

Shipped IDs (11 — `large-v1` excluded, no WhisperKit CoreML artifact):

| Relay id | OpenAI checkpoint | English-only | Approx size |
|---|---|---|---|
| `tiny.en` | tiny.en | yes | ~73 MB |
| `tiny` | tiny | no | ~73 MB |
| `base.en` | base.en | yes | ~140 MB |
| `base` | base | no | ~140 MB |
| `small.en` | small.en | yes | ~486 MB |
| `small` | small | no | ~486 MB |
| `medium.en` | medium.en | yes | ~1.5 GB |
| `medium` | medium | no | ~1.5 GB |
| `large-v2` | large-v2 | no | ~3.0 GB |
| `large-v3` | large-v3 | no | ~3.05 GB |
| `turbo` | large-v3-turbo | no | ~3.0 GB |

Aliases (`large`->`large-v3`, `large-v3-turbo`->`turbo`) are not separate rows. Exact sizes and
checksums come from the spike results doc / the runtime distribution source, never invented in
Relay.

**Unverified-at-merge note:** the large models (`medium`/`medium.en`/`large-v2`/`large-v3`/`turbo`)
are shipped live but their real-Mac load time, peak memory, and switch-stability are **not yet
measured** (spike Exp 5-7 deferred). They are documented as live-but-unverified; the Exp 5-7
harness stays in the results doc for the owner to run.

---

## 5. Components

Each follows Relay's existing backend-seam pattern (narrow protocol + live impl + test fake), the
same shape as `ParakeetEngine`/`KokoroEngine`.

### 5.1 `WhisperModelCatalog`
Pure static metadata. No network, no inference state.
```swift
enum WhisperModelID: String, CaseIterable, Codable, Sendable { /* the 11 ids */ }
struct WhisperModelDescriptor: Identifiable, Equatable, Sendable {
    let id: WhisperModelID
    let displayName: String
    let upstreamCheckpoint: String
    let runtimeArtifact: String      // HF repo path in argmaxinc/whisperkit-coreml
    let expectedSHA256: String       // weights; sidecar files verified per spike results
    let englishOnly: Bool
    let approximateDiskBytes: Int64
}
```

### 5.2 `WhisperModelStore`
Owns model files on disk under `~/Library/Application Support/Relay/Models/Whisper/<id>/`.
- `presence(of:)` — network-free disk+checksum check (like Parakeet's `isModelValid`).
- `download(_:progress:)` — download to a temp/incomplete path, verify checksum, **atomic promote**.
  An interrupted or corrupt download never appears as ready.
- `remove(_:)` — delete an inactive downloaded model; rediscovered as not-downloaded.

### 5.3 `WhisperRuntime` (actor)
Owns heavyweight inference state. **Invariant: at most one loaded context.**
```swift
actor WhisperRuntime {
    private var loaded: LoadedWhisperModel?
    func activate(_ id: WhisperModelID) async throws   // unload current, then load; failure leaves no context
    func transcribe(_ audio: AudioInput, options: STTOptions) async throws -> String
    func unload()
}
```
A failed switch must not leave two contexts resident; on load failure the runtime ends with **no**
loaded context and surfaces the error (Apple/Parakeet remain usable via the router).

### 5.4 `WhisperBackend` (actor, `SpeechToTextBackend`)
```swift
final actor WhisperBackend: SpeechToTextBackend {
    let id = "whisper"
    let displayName = "OpenAI Whisper"
    // capabilities: [.fullyOffline] plus .multilingual for multilingual models
}
```
- `availability()` -> `.available` when the **selected** model is downloaded+valid;
  `.modelNotDownloaded` when no model is selected or the selected one is absent.
- `prepare()` -> activates the selected model on the runtime (loads on demand).
- `transcribe(audio:options:)` -> delegates to the runtime; maps failures to `SpeechBackendError`
  exactly as Parakeet does, so the router classifies them identically.
- Delegates model I/O through a `WhisperEngine` seam (WhisperKit-backed in production, a fake in
  tests) so the backend's selection/single-flight/error-mapping logic is testable without CoreML.

---

## 6. Generalized model abstraction

Replace the single-model `SpeechModelDownloading` with a per-model `SpeechModelManaging` so any
backend can expose zero, one, or many downloadable models.

```swift
struct SpeechModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String; let displayName: String; let detail: String?; let approximateDownloadBytes: Int64?
}
enum SpeechModelInstallState: Equatable, Sendable {
    case notDownloaded, downloading(progress: Double), downloaded, downloadFailed
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
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func removeModel(_ id: String) async throws
    func selectModel(_ id: String) async throws
}
```
Key distinction enforced everywhere: **downloaded != selected != loaded.** Disk is the source of
truth for installed; runtime for loaded; settings persist only selection.

- `ParakeetModelManager` — the one-model implementation (`models().count == 1`). Existing Parakeet
  UX (a single Download row) is preserved; the generic API does not force a nested selector for a
  one-model backend.
- `WhisperModelManager` — the 11-model implementation, backed by `WhisperModelCatalog` +
  `WhisperModelStore` + `WhisperRuntime`.
- `AppModel.speechModelDownloaders: [String: any SpeechModelDownloading]` becomes
  `speechModelManagers: [String: any SpeechModelManaging]`. `SpeechBackendCatalog`'s download/state
  logic moves from per-backend to per-model, reusing the existing generation-counter race-safety
  and `downloadingBackendIDs`->`downloadingModelKeys` bookkeeping.
- `BackendCatalog`/`BackendStatus` stay as-is for backend-level readiness. `availability()` for a
  model-backed backend derives from the **selected** model only; the nested model list is not
  forced into `BackendCatalog`.

`SpeechModelDownloading` is removed once Parakeet no longer uses it. TTS backends are **not**
migrated in this merge (spike §10.3) — they keep their current download path; the abstraction is
built STT-wide-capable but only STT is wired now.

---

## 7. Settings

- `AppSettings` gains `selectedSpeechModelByBackend: [String: String]` (e.g. `parakeet->parakeet-v2`,
  `whisper->small.en`). Persisted. Decodes resiliently (per the repo's existing per-field decode
  pattern) — an unknown/removed model id is dropped, not fatal.
- Persist **selection only**. Do not persist `downloaded`/`loaded` — disk and runtime are their
  sources of truth.
- Whisper is registered in the STT backend registry and appended to `sttBackendOrder`. It is
  **not** forced to the top and **no** model is pre-selected; the user downloads and selects one.
  No benchmarked default is chosen in this merge (spike §34).

---

## 8. UI (`DictationSettingsView`)

- A backend with `models().count > 1` expands to a model list; each row: id, an
  English/Multilingual label, install/selection state (Download / Downloading% / Downloaded /
  Active / Failed), and a Remove action for inactive downloaded models. Selecting a
  not-downloaded model prompts to download rather than auto-downloading a multi-GB file.
- A one-model backend (Parakeet) keeps its current single Download row — no nested list.
- Runtime-specific filenames (`ggml-*.bin`, `openai_whisper-*`) are never shown as the model
  identity.

---

## 9. Router / fallback

- Existing `STTRouter` order and fallback semantics are authoritative and unchanged. No
  Whisper-specific fallback logic in `DictationCoordinator`.
- If the selected Whisper model is unavailable or a load/transcribe fails, the router falls through
  to the next enabled backend (Parakeet/Apple) exactly as today.

---

## 10. Language behaviour

- English-only models labelled "English only"; multilingual models advertise `.multilingual`.
- `STTOptions.localeIdentifier` is passed to multilingual Whisper as a language hint where the
  runtime supports it; otherwise the model auto-detects. No translation UI.

---

## 11. Privacy / diagnostics

Diagnostics may record: model id, load/transcribe/audio durations, sample count, download progress,
checksum result, memory measurement, runtime error category. They must never contain raw microphone
audio or transcript content. Test/benchmark fixtures are explicit assets, never silently-captured
user dictation. Backend error logging follows the existing `logger.debug("static string")` style —
no interpolated user content.

---

## 12. Testing

Unit tests against fakes (no CoreML, no network):
- `WhisperRuntime`: unload-before-load invariant; a failed activate leaves **no** loaded context;
  re-activating the already-loaded model is a no-op; switch destroys the prior context.
- `WhisperModelStore`: local-only presence check never hits the network; checksum mismatch is
  rejected; interrupted/partial download never becomes selectable; remove->notDownloaded.
- `WhisperBackend`: selection gating (`availability` reflects the selected model), single-flight
  load, `SpeechBackendError` mapping parity with Parakeet, `AudioInput` sample-rate guard.
- `SpeechModelManaging`: Parakeet one-model behaviour preserved; Whisper multi-model state
  transitions (downloaded/selected/loaded independence).
- `AppModel`/`SpeechBackendCatalog`: per-model download/select/remove state, progress monotonicity,
  and the generation-counter race-safety, extended from per-backend to per-model.

Not CI-verifiable (documented, deferred to the owner's Mac — spike Exp 5-7): real load time / peak
memory per model, memory plateau across >=10 switches on the large models, all-11 smoke, quality
benchmark vs Parakeet/Apple, 100-run stability + full cancellation matrix.

---

## 13. Cancellation / reliability (behavioural targets)

- Cancel during load: no stuck state, no second context, later retry works.
- Cancel during transcribe: bounded cancellation; coordinator returns to a known state.
- Selected model file missing at prepare: `.modelNotDownloaded`, no crash, fallback possible.
- Corrupt model file: verification rejects; never marked ready.
- Model switch after many transcriptions: old context unloads; no stale transcript crosses sessions.

---

## 14. Out of scope (this merge)

Live/interim Whisper, streaming/partial decoding, hands-free/VAD, translation UI, TTS abstraction
migration, `large-v1`, and choosing a benchmarked production default.

---

## 15. Open items carried to the owner

1. Run spike Exp 5-7 on the target Mac; decide whether any large model should be warned-about or
   excluded based on measured memory (spike §36 CONDITIONAL-GO path).
2. Choose the production default model + router priority after benchmarking (spike §34).
