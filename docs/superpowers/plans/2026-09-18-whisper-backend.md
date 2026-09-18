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
- `Relay/Domain/AppSettings.swift` — add `selectedSpeechModelByBackend` (resilient decode) AND add `"whisper"` to `knownSTTBackendIDs` (line ~35 — otherwise `normalizedBackendOrder` strips it on every decode).
- `Relay/App/SpeechBackendCatalog.swift` — per-model download/select/remove; remove the `extension ParakeetBackend: SpeechModelDownloading {}` conformance.
- `Relay/App/RelayRuntime.swift` (composition root) — declares `speechModelDownloaders`/`ttsModelDownloaders`; rename the STT one to `speechModelManagers`; register `WhisperBackend` + its manager.
- `Relay/App/AppModel.swift` and `Relay/App/SpeechInputServices.swift` (wherever `speechModelDownloaders` is declared/read — AppModel reads `runtime.speechIn.speechModelDownloaders`) — rename to `speechModelManagers`.
- `Relay/App/Settings/DictationSettingsView.swift` — nested model list for multi-model backends; update the old single-arg `downloadSpeechModel(backend.id)` call site (~line 84).
- `RelayTests/App/ProjectSmokeTests.swift` — update old single-arg `canDownloadSpeechModel("parakeet")` call site (~line 34).

**Do NOT delete `SpeechModelDownloading`.** TTS still uses it: `KokoroTTSBackend` and `PocketTTSBackend` both conform, and `RelayRuntime`/`AppModel` carry `ttsModelDownloaders: [String: any SpeechModelDownloading]`. This work removes only the *STT* (Parakeet) use of it; the protocol stays for TTS, untouched.

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
func testEveryModelHasNonEmptyArtifactAndPositiveSize() {
    for id in WhisperModelID.allCases {
        let d = WhisperModelCatalog.descriptor(for: id)
        XCTAssertFalse(d.runtimeArtifact.isEmpty)          // e.g. "openai_whisper-small.en"
        XCTAssertGreaterThan(d.approximateDiskBytes, 0)
    }
}
```
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperModelID` (11 cases, `rawValue` = spec §4 ids) and `WhisperModelCatalog.descriptor(for:)`. Fill `runtimeArtifact` (the `openai_whisper-*` HF subfolder) and `approximateDiskBytes` from the results doc catalog table (`docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md` §2, now present on this branch). **There is NO static per-model SHA256** — the catalog carries identity + size only; per-file checksum verification is done dynamically by `WhisperModelStore` (Task 3) against the HF tree `oid`s fetched at download time. If the artifact folder name or size for any id is missing from the results doc, STOP and flag it.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(whisper): add WhisperModelCatalog`

---

## Task 3: `WhisperModelStore` (disk lifecycle) with a downloader seam

**Files:** Create `Relay/Backends/Whisper/WhisperModelStore.swift`; Test `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`.

Mirror `FluidAudioKokoroModelLoader`/`FluidAudioParakeetEngine`'s presence-gate + atomic-promote thinking. Define a `WhisperDownloader` protocol seam so download logic is testable without the network; the live impl fetches `argmaxinc/whisperkit-coreml/<artifact>` via `URLSession` (or WhisperKit's HF helper — confirm against the resolved API).

**Per-file verification (results doc §2):** a `.mlmodelc` bundle is many files. The live downloader fetches the HF tree for the artifact folder to get each file's `oid`, downloads every file, and verifies each against its `oid` — LFS files against the recorded sha256, non-LFS sidecars against the git blob-sha1 (`sha1("blob " + size + "\0" + content)`) — before the atomic promote. The `WhisperDownloader` seam returns verified bytes/paths so `WhisperModelStore`'s promote/presence logic is what the tests exercise; the fake supplies files + oids directly (no network).

- [ ] **Step 1: Write failing tests** (against a temp dir + a fake `WhisperDownloader`):
  - `testPresenceFalseWhenDirEmpty` — network-free, returns not-downloaded.
  - `testPresenceTrueOnlyWhenAllFilesPresentAndVerifiedMarkerExists` — files present but no `.verified` marker → still not-downloaded.
  - `testDownloadAtomicallyPromotesOnlyAfterEveryFileVerifies` — fake writes good bytes + matching oids → becomes downloaded (marker written).
  - `testFileChecksumMismatchRejectsAndLeavesNotDownloaded` — one file's `oid` mismatches → reject, no promote, no marker.
  - `testInterruptedDownloadNeverBecomesSelectable` — fake throws mid-download; presence stays false; no partial file or marker in the promoted path.
  - `testRemoveDeletesAndRediscoversAsNotDownloaded`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `WhisperModelStore` + `WhisperDownloader` seam + the live downloader. Download to `<id>.incomplete/`, verify every file against its HF `oid`, then atomic rename to `<id>/` AND write a `.verified` marker (as the results doc §4 does). `presence(of:)` is network-free: it checks all bundle files exist **and** the `.verified` marker is present — it does NOT re-hash against `oid`s (those are only known at download time, and offline it has no expected values). The marker is the offline proof that the atomic, verified promote completed.
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
- [ ] **Step 3: Implement** `WhisperBackend` (actor). `capabilities` is a synchronous non-async getter, so it CANNOT await the selection source; advertise `[.fullyOffline, .multilingual]` **statically** (the Whisper backend as a whole can do multilingual — the catalog contains multilingual models). Do not vary capabilities per selected model. `prepare()` activates the selected model. Error mapping parity with `ParakeetBackend.mapLoadError`.
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
- [ ] **Step 3: Implement** `ParakeetModelManager` wrapping the existing Parakeet engine/download. Leave `downloadModels` on the engine (the manager calls it). **Do NOT remove the `extension ParakeetBackend: SpeechModelDownloading {}` conformance in this task** — `RelayRuntime.swift` (~line 256) still builds `speechModelDownloaders` from it, so removing it here breaks the build. The conformance removal + the RelayRuntime rewire happen together in Task 8a.
- [ ] **Step 4: Run — expect PASS** (the new manager exists alongside the untouched Parakeet download path; nothing removed yet). `SpeechModelDownloading` stays — TTS keeps using it permanently.
- [ ] **Step 5: Commit.** `feat(parakeet): add one-model ParakeetModelManager`

---

## Task 8a: Mechanical rename `speechModelDownloaders` → `speechModelManagers` (STT only)

**Files:** Modify `Relay/App/RelayRuntime.swift` (contains both the `SpeechInputServices` struct — field ~line 47 — and the `speechModelDownloaders` declaration ~line 256; there is NO separate `SpeechInputServices.swift`), `Relay/App/AppModel.swift` (declares `speechModelDownloaders` ~lines 73/163/196/230/281/310), `Relay/App/SpeechBackendCatalog.swift` (~lines 49/85; remove the `extension ParakeetBackend: SpeechModelDownloading {}` at line 7). Test files that MUST change in the same unit: `RelayTests/App/AppModelTests.swift` (see Step 2 — this is non-mechanical), plus the call sites `DictationSettingsView.swift:84` and `ProjectSmokeTests.swift:34`.

This is the atomic compile unit the reviewer flagged: the STT map's element type changes from `any SpeechModelDownloading` to `any SpeechModelManaging`, the Parakeet conformance goes, and RelayRuntime builds the map from `ParakeetModelManager` (Task 7) instead of the backend. `ttsModelDownloaders` and `SpeechModelDownloading` itself are **untouched** (TTS keeps them). Production behaviour is unchanged, but the STT test fake is a different protocol surface, so this task is NOT purely mechanical — the whole suite fails to *build* until the fake is migrated, so do all of Steps 1–3 before running.

- [ ] **Step 1:** Change the STT map type to `[String: any SpeechModelManaging]` everywhere it is declared/passed (`RelayRuntime`, its `SpeechInputServices` field, `AppModel`). Populate it from `[parakeetModelManager.backendID: parakeetModelManager]`. Remove `extension ParakeetBackend: SpeechModelDownloading {}`. Keep `canDownloadSpeechModel`/`downloadSpeechModel` compiling by adapting them to call the manager's `downloadModel` for the backend's single/selected model (parity for Parakeet's one model). Update `DictationSettingsView.swift:84` and `ProjectSmokeTests.swift:34`.
- [ ] **Step 2 (non-mechanical — the reviewer's blocker):** In `RelayTests/App/AppModelTests.swift`: rewrite `FakeSpeechModelDownloader: SpeechModelDownloading` (~line 1560) into a one-model `FakeSpeechModelManager: SpeechModelManaging` (implement `backendID`, `models()`, `downloadModel`, `removeModel`, `selectModel`; `downloadModel` preserves the existing progress/failure behaviour the tests rely on). Retype the `makeModel` helper param (~line 1362) and the `AppModel(...)` init call (~line 1385) to `[String: any SpeechModelManaging]`. Re-point the ~10 STT call sites (~lines 949, 982, 1006, 1032, 1058, 1084, 1120, 1141, 1168, 1303) at the new fake. Keep the existing Parakeet download/progress assertions green against the single-model parity path (Task 8b extends them to per-model). Do NOT touch `FakeTTSModelDownloader` / TTS tests.
- [ ] **Step 3: Run full suite — expect PASS** (production behaviour unchanged; Parakeet download still works via the manager; TTS untouched).
- [ ] **Step 4: Commit.** `refactor(stt): rename speechModelDownloaders to speechModelManagers`

---

## Task 8b: Per-model download/select/remove + observable per-model state

**Files:** Modify `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/AppModel.swift`; Test `RelayTests/App/SpeechModelManagingCatalogTests.swift`.

`BackendStatus`/`sttBackends` is strictly per-backend (one `state` per row) and `SpeechModelManaging.models()` is `async` returning immutable snapshots — neither can hold live per-model download progress, and `models()` can't be called from a SwiftUI `body`. So this task first defines the observable per-model container the view (Task 10) reads.

- [ ] **Step 1: Define the observable per-model state on `AppModel`** (the reviewer's missing piece): e.g. `private(set) var speechModels: [String: [SpeechModelStatus]]` (backendID → snapshot rows) plus `private(set) var downloadingModelKeys: Set<String>` keyed `"<backendID>/<modelID>"` and a `downloadingModelProgress: [String: Double]` map. A `refreshSpeechModels()` awaits each manager's `models()` off-actor and assigns on the main actor, reusing the existing generation-counter race-safety pattern from `refreshSpeechBackendStatuses`.
- [ ] **Step 2: Write failing tests** (fake `SpeechModelManaging`): `downloadSpeechModel(backendID:modelID:)` inserts the key into `downloadingModelKeys` and drives `.downloading(progress:)` for that row only; progress is monotonic; a failed download marks that model `.downloadFailed` and clears its key without touching sibling rows; `selectSpeechModel(backendID:modelID:)` updates the selected row's `isSelected` and refreshes backend availability; `removeSpeechModel` refuses/handles the loaded model per spec §17; the last-enabled-backend guard is unchanged.
- [ ] **Step 3: Run — expect FAIL.**
- [ ] **Step 4: Implement** the per-model download/select/remove methods + `refreshSpeechModels`, pairing the single-flight key with the visible row state in one synchronous step (same discipline as `beginDownload`/`endDownload`).
- [ ] **Step 5: Run — expect PASS.**
- [ ] **Step 6: Commit.** `feat(stt): per-model download/select/remove with observable state`

---

## Task 9: `AppSettings.selectedSpeechModelByBackend`

**Files:** Modify `Relay/Domain/AppSettings.swift`; Test extend `RelayTests/Domain/AppSettingsTests.swift`.

- [ ] **Step 1: Write failing tests:** (a) `selectedSpeechModelByBackend` default is empty; round-trips through Codable/persistence; a malformed/unknown value decodes without throwing (resilient per-field decode — read how existing fields do it first). (b) A `sttBackendOrder` containing `"whisper"` **survives** decode (round-trips), proving `whisper` was added to `knownSTTBackendIDs`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the `selectedSpeechModelByBackend` field + resilient decode, AND add `"whisper"` to `knownSTTBackendIDs` (~line 35) so `normalizedBackendOrder` no longer strips it. Wire `WhisperModelManager`/`WhisperBackend` selection to read/write the field (persist selection only). **Do NOT validate model ids in `AppSettings`** — it has no per-backend model set; an id no longer in a backend's catalog is dropped/ignored by the manager at read time, not by `AppSettings`. (Reconciles spec §7 wording.)
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit.** `feat(settings): persist selected speech model + register whisper backend id`

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

- [ ] **Step 1: Write/extend a test** at the composition-root level (mirror how Parakeet is asserted registered) that `whisper` appears in the STT registry and in `speechModelManagers` with a `WhisperModelManager`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** construction of `WhisperBackend` + `WhisperModelManager` (catalog + store + runtime + live `WhisperKitEngine`) and register both. **Match the Parakeet precedent: register Whisper but do NOT enable it by default** — leave `AppSettings.sttBackendOrder`'s default at `["apple-speech"]` (do NOT touch `AppSettingsTests.swift:148,158`). The user enables Whisper and selects a model from Settings. No pre-selected model.
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
- Apple Speech + Parakeet behaviour unchanged; Parakeet UX still a single Download row; Parakeet not enabled by default; Whisper registered but not enabled by default.
- STT no longer uses `SpeechModelDownloading` (Parakeet conformance removed); the protocol itself STAYS for TTS (`Kokoro`/`PocketTTS`), untouched.
- Whisper selectable with all 11 models; switching unloads the prior context; failure falls through the router.
- Manual/owner-Mac verification (Exp 5–7) explicitly deferred and documented — NOT claimed as done.
