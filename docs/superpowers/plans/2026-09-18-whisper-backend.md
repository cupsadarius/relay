# OpenAI Whisper STT Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use @superpowers:test-driven-development for every task: red → green → refactor. Commit after each task.

**Goal:** Add OpenAI Whisper as a single local on-device STT backend in Relay, exposing 11 official checkpoints as explicitly-downloaded, individually-selectable models with exactly one model resident in inference memory at a time.

**Architecture:** WhisperKit (pure Swift/Core ML) behind Relay's existing backend-seam pattern. A new generalized `SpeechModelManaging` abstraction replaces the single-model `SpeechModelDownloading`; Parakeet becomes its one-model case, Whisper its 11-model case. Relay owns download/verify/remove; a `WhisperRuntime` actor enforces one loaded context.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, WhisperKit `1.1.0` (`argmaxinc/argmax-oss-swift`), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-18-whisper-backend-design.md`

---

## Ground rules for the implementer

- **Verify every WhisperKit API against the real package** before using it. Resolve the package, then read the headers under the resolved checkout (`WhisperKit.init`, `WhisperKitConfig`, `unloadModels()`, `transcribe`, the model-folder layout). Do NOT trust signatures quoted here — treat them as intent, confirm the exact spelling. Use context7 (`argmaxinc/WhisperKit`) for docs.
- **Follow the existing seam pattern.** Read `Relay/Backends/FluidAudioParakeetEngine.swift` and `Relay/Backends/ParakeetBackend.swift` first — the Whisper types mirror their structure (narrow `Sendable` protocol, live impl, actor wrapper for non-Sendable state, test fake).
- **Privacy:** backends log only static strings via `Logger(subsystem: "dev.relaymac.Relay", ...)`. Never log audio, transcript text, or raw error descriptions except with `privacy: .private`.
- **Build/test commands** (run from the worktree root):
  - Regenerate project: `xcodegen generate`
  - Full test: `set -o pipefail && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -80`
  - Single test class: append `-only-testing:RelayTests/<ClassName>` to the `xcodebuild test` invocation.
- **Commits:** conventional-commit messages. NEVER add `Co-Authored-By: Claude`, `Claude-Session:`, or "Generated with Claude Code" lines — the repo owner forbids them.
- Tooling note: the Edit/Write tools in this environment sometimes misfire on worktree paths; if so, write files via a shell heredoc or `python3 -c` and verify with `cat`.

---

## File structure

**Create (production):**
- `Relay/Domain/SpeechModelManaging.swift` — the generalized protocol + `SpeechModelDescriptor`/`SpeechModelInstallState`/`SpeechModelStatus`.
- `Relay/Backends/Whisper/WhisperModelCatalog.swift` — `WhisperModelID` + `WhisperModelDescriptor` + the static 11-entry catalog.
- `Relay/Backends/Whisper/WhisperModelStore.swift` — disk presence/download/verify/remove + a `WhisperDownloader` seam.
- `Relay/Backends/Whisper/WhisperRuntime.swift` — the one-context actor + `WhisperEngine` seam + live WhisperKit engine.
- `Relay/Backends/Whisper/WhisperBackend.swift` — `SpeechToTextBackend` impl.
- `Relay/Backends/Whisper/WhisperModelManager.swift` — `SpeechModelManaging` impl for the 11-model case.
- `Relay/Backends/ParakeetModelManager.swift` — `SpeechModelManaging` one-model impl for Parakeet.

**Modify (production):**
- `project.yml` — add the WhisperKit package + target dependency.
- `Relay/Domain/AppSettings.swift` — add `selectedSpeechModelByBackend`, resilient decode.
- `Relay/App/SpeechBackendCatalog.swift` — per-model download/select/remove; `speechModelDownloaders` → `speechModelManagers`.
- `Relay/App/RelayRuntime.swift` (composition root) — register `WhisperBackend` + its manager.
- `Relay/App/AppModel.swift` (or wherever `speechModelDownloaders` is declared) — rename to `speechModelManagers`.
- `Relay/App/Settings/DictationSettingsView.swift` — nested model list for multi-model backends.
- Delete `SpeechModelDownloading` from `Relay/App/BackendCatalog.swift` once Parakeet no longer conforms.

**Create (tests):**
- `RelayTests/Backends/Whisper/WhisperModelCatalogTests.swift`
- `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`
- `RelayTests/Backends/Whisper/WhisperRuntimeTests.swift`
- `RelayTests/Backends/Whisper/WhisperBackendTests.swift`
- `RelayTests/Backends/WhisperModelManagerTests.swift`
- `RelayTests/Backends/ParakeetModelManagerTests.swift`
- `RelayTests/App/SpeechModelManagingCatalogTests.swift` (per-model AppModel/catalog behaviour)
- Extend `RelayTests/Domain/AppSettingsTests.swift` for the new field.

---

## Task 0: Add the WhisperKit dependency

**Files:** Modify `project.yml`.

- [ ] **Step 1: Add the package.** Under `packages:`, add:
```yaml
  WhisperKit:
    url: https://github.com/argmaxinc/argmax-oss-swift.git
    exactVersion: 1.1.0
```
Under the `Relay` target `dependencies:`, add `- package: WhisperKit` with `product: WhisperKit` (confirm the exact product name against the resolved `Package.swift`).
- [ ] **Step 2: Regenerate + resolve.** Run `xcodegen generate`, then a plain `xcodebuild -scheme Relay build CODE_SIGNING_ALLOWED=NO` to force package resolution. Expected: resolves `argmax-oss-swift` at `1.1.0`, builds (WhisperKit not yet imported anywhere).
- [ ] **Step 3: Read the resolved WhisperKit headers.** Locate the checkout under the derived-data SourcePackages and read `WhisperKit`'s public API: init/config, `unloadModels()`, transcription entry point, and the on-disk model-folder layout it expects. Record the exact signatures in a scratch note for Tasks 3–4.
- [ ] **Step 4: Commit.** `git add project.yml && git commit -m "build: add WhisperKit 1.1.0 dependency"`

---

## Task 1: Generalized `SpeechModelManaging` abstraction (pure, no backend)

**Files:** Create `Relay/Domain/SpeechModelManaging.swift`; Test `RelayTests/Domain/SpeechModelManagingTests.swift`.

- [ ] **Step 1: Write failing tests** for the value types (pure data — test equality, `id`, and that `SpeechModelStatus.id == descriptor.id`). Example:
```swift
func testStatusIdMirrorsDescriptorId() {
    let d = SpeechModelDescriptor(id: "small.en", displayName: "small.en", detail: "English only", approximateDownloadBytes: 486_000_000)
    let s = SpeechModelStatus(descriptor: d, installState: .downloaded, isSelected: true, isLoaded: false)
    XCTAssertEqual(s.id, "small.en")
}
func testInstallStateEquatable() {
    XCTAssertEqual(SpeechModelInstallState.downloading(progress: 0.5), .downloading(progress: 0.5))
    XCTAssertNotEqual(SpeechModelInstallState.downloading(progress: 0.5), .downloaded)
}
```
- [ ] **Step 2: Run — expect FAIL** (types undefined).
- [ ] **Step 3: Implement** the exact types from spec §6 (`SpeechModelDescriptor`, `SpeechModelInstallState`, `SpeechModelStatus`, `protocol SpeechModelManaging`). All `Sendable`/`Equatable` as in the spec.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(stt): add generalized SpeechModelManaging abstraction`

---

## Task 2: `WhisperModelCatalog` (pure metadata)

**Files:** Create `Relay/Backends/Whisper/WhisperModelCatalog.swift`; Test `RelayTests/Backends/Whisper/WhisperModelCatalogTests.swift`.

- [ ] **Step 1: Write failing tests:**
```swift
func testCatalogHasElevenModelsAndExcludesLargeV1() {
    XCTAssertEqual(WhisperModelID.allCases.count, 11)
    XCTAssertFalse(WhisperModelID.allCases.map(\.rawValue).contains("large-v1"))
}
func testEnglishOnlyFlagsAreCorrect() {
    XCTAssertTrue(WhisperModelCatalog.descriptor(for: .tinyEn).englishOnly)
    XCTAssertFalse(WhisperModelCatalog.descriptor(for: .turbo).englishOnly)
}
func testEveryModelHasNonEmptyArtifactAndChecksum() {
    for id in WhisperModelID.allCases {
        let d = WhisperModelCatalog.descriptor(for: id)
        XCTAssertFalse(d.runtimeArtifact.isEmpty)
        XCTAssertEqual(d.expectedSHA256.count, 64)  // hex sha256
    }
}
```
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperModelID` (11 cases, `rawValue` = spec §4 ids) and `WhisperModelCatalog.descriptor(for:)`. Fill `runtimeArtifact`, `expectedSHA256`, `approximateDiskBytes` from the spike **results** doc's catalog table (`docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md` §2). Do NOT invent checksums — copy them from the results doc; if any entry is missing there, STOP and flag it.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperModelCatalog`

---

## Task 3: `WhisperModelStore` (disk lifecycle) with a downloader seam

**Files:** Create `Relay/Backends/Whisper/WhisperModelStore.swift`; Test `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`.

Mirror `FluidAudioKokoroModelLoader`/`FluidAudioParakeetEngine`'s presence-gate + atomic-promote thinking. Define a `WhisperDownloader` protocol seam so download logic is testable without the network; the live impl uses WhisperKit's HF download or `URLSession` (confirm which against the resolved API) to fetch `argmaxinc/whisperkit-coreml/<artifact>`.

- [ ] **Step 1: Write failing tests** (against a temp dir + a fake `WhisperDownloader`):
  - `testPresenceFalseWhenDirEmpty` — network-free, returns not-downloaded.
  - `testPresenceTrueOnlyWhenAllFilesPresentAndChecksumMatches`.
  - `testDownloadAtomicallyPromotesOnlyAfterChecksumVerifies` — fake writes good bytes → becomes downloaded.
  - `testChecksumMismatchRejectsAndLeavesNotDownloaded`.
  - `testInterruptedDownloadNeverBecomesSelectable` — fake throws mid-download; presence stays false; no partial file in the promoted path.
  - `testRemoveDeletesAndRediscoversAsNotDownloaded`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperModelStore` + `WhisperDownloader` seam + the live downloader. Download to `<id>.incomplete/`, verify checksum, then atomic rename to `<id>/`. `presence(of:)` opens/hashes without network.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperModelStore with atomic download + verify`

---

## Task 4: `WhisperRuntime` (one-context actor) with a `WhisperEngine` seam

**Files:** Create `Relay/Backends/Whisper/WhisperRuntime.swift`; Test `RelayTests/Backends/Whisper/WhisperRuntimeTests.swift`.

`WhisperEngine` = narrow seam: `func load(modelFolder: URL) async throws -> any LoadedWhisperContext` and the context exposes `transcribe(_:options:) -> String` and `unload()`. Live impl wraps `WhisperKit`. Runtime holds at most one context.

- [ ] **Step 1: Write failing tests** (fake engine records load/unload calls):
  - `testActivateLoadsSelectedModel`.
  - `testSwitchUnloadsPreviousBeforeLoadingNext` — assert the fake saw `unload(A)` strictly before `load(B)`.
  - `testReactivatingSameModelIsNoOp` — no second load, no unload.
  - `testFailedActivateLeavesNoLoadedContext` — fake `load` throws → runtime has no context, next `transcribe` throws not-loaded, a later successful activate works.
  - `testTranscribeDelegatesToLoadedContext`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperRuntime` actor honouring the one-context invariant (unload current, null it out, then load; on load throw leave `loaded = nil`). Implement the live `WhisperKitEngine` (verify the real load/unload/transcribe API first).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperRuntime with single-context invariant`

---

## Task 5: `WhisperBackend` (`SpeechToTextBackend`)

**Files:** Create `Relay/Backends/Whisper/WhisperBackend.swift`; Test `RelayTests/Backends/Whisper/WhisperBackendTests.swift`.

Reads its selected model id from an injected selection source (a closure or a small `WhisperSelection` seam so tests can set it without `AppSettings`). Delegates presence to the store, load/transcribe to the runtime. Maps errors to `SpeechBackendError` exactly like `ParakeetBackend`.

- [ ] **Step 1: Write failing tests:**
  - `testAvailabilityModelNotDownloadedWhenNothingSelected`.
  - `testAvailabilityModelNotDownloadedWhenSelectedModelAbsent`.
  - `testAvailabilityAvailableWhenSelectedModelPresent`.
  - `testTranscribeRejectsWrongSampleRate` (mirror ParakeetBackend's 16 kHz guard).
  - `testTranscribeRejectsEmptyAudio`.
  - `testLoadFailureMapsToInitializationFailedAndRouterCanFallThrough`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperBackend` (actor). `capabilities` = `[.fullyOffline]` plus `.multilingual` when the selected model is multilingual. `prepare()` activates the selected model. Error mapping parity with `ParakeetBackend.mapLoadError`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperBackend`

---

## Task 6: `WhisperModelManager` (`SpeechModelManaging`, 11-model case)

**Files:** Create `Relay/Backends/Whisper/WhisperModelManager.swift`; Test `RelayTests/Backends/Whisper/WhisperModelManagerTests.swift`.

Composes catalog + store + runtime + the selection store. `models()` maps each catalog entry to a `SpeechModelStatus` (installed from store, selected from selection, loaded from runtime).

- [ ] **Step 1: Write failing tests:**
  - `testModelsReportsAllElevenWithCorrectInstalledFlags` (fake store: some present).
  - `testSelectPersistsSelectionAndDoesNotDownload` — selecting a not-downloaded id changes selection but triggers no download.
  - `testDownloadModelDelegatesToStoreWithProgress`.
  - `testRemoveModelDelegatesToStore` and refuses/So-documents removing the currently-loaded model (unload/switch first per spec §17 — assert it either unloads first or throws a clear error; pick one and test it).
  - `testDownloadedSelectedLoadedAreIndependent` — a model can be downloaded+selected but not loaded.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperModelManager`

---

## Task 7: `ParakeetModelManager` + retire `SpeechModelDownloading`

**Files:** Create `Relay/Backends/ParakeetModelManager.swift`; Test `RelayTests/Backends/ParakeetModelManagerTests.swift`; Modify `ParakeetBackend.swift` / `BackendCatalog.swift`.

- [ ] **Step 1: Write failing tests:** one-model manager — `models().count == 1`, id `parakeet-v2`; `downloadModel` delegates to the existing Parakeet download; `selectModel` is a no-op-success (only one model); `installState` reflects presence.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `ParakeetModelManager` wrapping the existing Parakeet engine/download. Remove the `extension ParakeetBackend: SpeechModelDownloading {}` conformance. Leave `downloadModels` on the engine (the manager calls it).
- [ ] **Step 4: Run — expect PASS.** (Do NOT delete the `SpeechModelDownloading` protocol yet — Task 8 removes its last consumers.)
- [ ] **Step 5: Commit.** `feat(parakeet): add one-model ParakeetModelManager`

---

## Task 8: Wire `AppModel`/`SpeechBackendCatalog` to per-model managers

**Files:** Modify `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/AppModel.swift` (declaration of `speechModelDownloaders`), `Relay/App/BackendCatalog.swift` (delete `SpeechModelDownloading`); Test `RelayTests/App/SpeechModelManagingCatalogTests.swift`.

This is the largest single task — split commits if it helps. Preserve the existing generation-counter race-safety; extend the download single-flight from per-backend (`downloadingBackendIDs`) to per-model (a `Set<String>` keyed `"<backendID>/<modelID>"`).

- [ ] **Step 1: Write failing tests** for the new per-model surface: `downloadSpeechModel(backendID:modelID:)` begins/ends download and writes `.downloading(progress:)` on the right model row; select updates `isSelected` and refreshes availability; progress monotonicity; a failed download marks that model `.downloadFailed` without touching others; the last-enabled-backend guard still holds.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement.** Rename `speechModelDownloaders` → `speechModelManagers: [String: any SpeechModelManaging]`. Rework `canDownloadSpeechModel`/`downloadSpeechModel`/progress bookkeeping to be per-model. Delete `SpeechModelDownloading` and its `ParakeetBackend` conformance references. Update any TTS-side callers only as far as needed to compile (TTS keeps its own current download path — do NOT migrate TTS; if TTS shared `SpeechModelDownloading`, give TTS its own minimal protocol or leave its existing type in place).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `refactor(stt): drive model download/select/remove per model`

---

## Task 9: `AppSettings.selectedSpeechModelByBackend`

**Files:** Modify `Relay/Domain/AppSettings.swift`; Test extend `RelayTests/Domain/AppSettingsTests.swift`.

- [ ] **Step 1: Write failing tests:** default is empty; round-trips through the app's Codable/persistence; an unknown key/value decodes without throwing (resilient per-field decode, matching the repo's existing schema-migration pattern — read how other fields do it first).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the field + resilient decode. Wire `WhisperModelManager`/`WhisperBackend` selection to read/write it (persist selection only).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(settings): persist selected speech model per backend`

---

## Task 10: `DictationSettingsView` nested model UI

**Files:** Modify `Relay/App/Settings/DictationSettingsView.swift`. (View logic; test what is unit-testable — a small view-model/formatter if one exists; otherwise verify by build + manual.)

- [ ] **Step 1:** Read the current Parakeet row rendering. Add a nested model list, shown only when a backend's manager reports `models().count > 1`. Each row: id, English/Multilingual label, state (Download / Downloading% / Downloaded / ● Active / Failed), Remove for inactive downloaded models. Selecting a not-downloaded model prompts to download (no auto multi-GB download). One-model backends keep the current single Download row.
- [ ] **Step 2:** If any presentation logic is extractable (row-state → label/icon mapping), put it in a testable pure function and add tests. Never surface runtime filenames as identity.
- [ ] **Step 3: Build + full test.** `xcodegen generate && xcodebuild test ...` — expect PASS.
- [ ] **Step 4: Commit.** `feat(ui): nested model selector for multi-model STT backends`

---

## Task 11: Register Whisper in the composition root + live engine end-to-end

**Files:** Modify `Relay/App/RelayRuntime.swift`.

- [ ] **Step 1: Write/extend a test** at the composition-root level (mirror how Parakeet is asserted registered, if such a test exists) that `whisper` appears in the STT registry with a `WhisperModelManager`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** construction of `WhisperBackend` + `WhisperModelManager` (catalog + store + runtime + live `WhisperKitEngine`) and register both. Append `whisper` to the default `sttBackendOrder`; do NOT place it first; do NOT pre-select a model.
- [ ] **Step 4: Run — expect PASS,** then full suite green.
- [ ] **Step 5: Commit.** `feat(whisper): register OpenAI Whisper backend in RelayRuntime`

---

## Task 12: Update the spike results doc + owner checklist

**Files:** Modify `docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md`.

- [ ] **Step 1:** Add a short "Implemented" note linking the merge, and confirm the Exp 5–7 harness (real-Mac memory / all-11 smoke / quality benchmark / 100-run stability) is present and current for the owner to run against the shipped backend. Note the large models are live-but-unverified.
- [ ] **Step 2: Commit.** `docs(spike): note Whisper backend implementation + carry Exp 5-7 to owner`

---

## Definition of done

- Full suite green: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- No Python/CLI/subprocess introduced; WhisperKit called as a library.
- Apple Speech + Parakeet behaviour unchanged; Parakeet UX still a single Download row.
- `SpeechModelDownloading` removed from STT; TTS untouched.
- Whisper selectable with all 11 models; switching unloads the prior context; failure falls through the router.
- Manual/owner-Mac verification (Exp 5–7) explicitly deferred and documented — NOT claimed as done.
