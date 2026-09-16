# Relay Reliability — Wave 3: Simplification, Persistence & CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Reduce structural complexity without changing behavior — introduce a composition root, merge the duplicated backend catalogs, give the latest agent response one owner, delete dormant state, narrow hotkey side effects, make settings decode per-field resilient — then add CI and fault-injection tests so reliability is enforced automatically.

**Why:** The audit (`relay-reliability-simplification-review.md`, §8, §9, §10) found the remaining complexity/persistence/CI gaps, all verified against commit `cfcdf27`:
1. `AppModel` (~970 lines) is the sole composition root and owns ~18 subsystems; no `RelayRuntime` exists.
2. `SpeechBackendCatalog` and `TTSBackendCatalog` are near-identical (the TTS file header says it "Mirrors STTBackendStatus exactly").
3. The latest agent response is written to two global owners; the availability gate and the spoken content read from different ones and can diverge.
4. `RecentInteractionTracker` is dormant — nothing in production consumes it (the file says so).
5. An unrelated settings change (voice/rate/backend) rebuilds the hotkey matcher, discarding in-flight chord/double-tap state. (The event tap is NOT re-created — that part is fine.)
6. Settings decode is all-or-nothing for the six required fields: one bad/new required field resets every preference.
7. No CI status checks protect `main`; blocking external boundaries lack fault tests.

**Architecture:** This wave is refactor-heavy and **behavior-preserving** except where a task explicitly fixes a bug (Tasks 3, 5, 6). Every refactor task writes **characterization tests first** to lock current behavior, then refactors, then confirms the suite is still green.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, XCTest, XcodeGen, GitHub Actions.

**Templates to read first:** `Relay/App/AppModel.swift`, `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/TTSBackendCatalog.swift`, `Relay/Integrations/IntegrationManager.swift`, `Relay/Integrations/LatestAgentResponseStore.swift`, `Relay/Sessions/RecentInteractionTracker.swift`, `Relay/System/GlobalHotkeyManager.swift`, `Relay/System/SettingsStore.swift`, `Relay/Domain/AppSettings.swift`.

---

## Ground rules
- Work on `main`. No worktrees. **Run implementers one at a time.**
- **Depends on Waves 1 and 2 being merged first** — this wave consolidates state those waves touch (sessions, playback, latest-response).
- Generate the project only via `xcodegen generate`. Never hand-edit `Relay.xcodeproj`.
- **Characterization tests FIRST for every refactor.** No behavior change unless the task explicitly says so.
- TDD each task; zero warnings; suite ends `** TEST SUCCEEDED **`.
- **No commit trailers.** Plain messages.
- Privacy: no spoken text, transcript, audio, paths, or raw error strings in logs/Diagnostics.
- Test command template:
  ```bash
  xcodegen generate
  xcodebuild test -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/<Suite> 2>&1 | tail -30
  ```

---

## Task 1: Introduce a `RelayRuntime` composition root; slim `AppModel`

**The finding:** `Relay/App/AppModel.swift` is ~970 lines; its production `convenience init()` (line ~121) builds the entire dependency graph inline, and stored properties (lines ~16-115) cover settings, permissions, login items, hotkeys, STT/TTS registries, model downloaders, download state, dictation, speech, overlay, sockets, integrations, installers, sessions, focus, replay, diagnostics. No `RelayRuntime` exists.

**The fix:** a boring composition root `RelayRuntime` that constructs and owns service lifetimes; `AppModel` keeps UI-facing state/actions and receives the runtime. No DI framework — explicit initializers. **Behavior-preserving.**

**Files:**
- Create: `Relay/App/RelayRuntime.swift`
- Modify: `Relay/App/AppModel.swift` (accept `RelayRuntime`; stop building the full graph)
- Modify: `Relay/App/RelayApp.swift` (`RelayRuntime.makeProduction()` → `AppModel(runtime:)`)
- Test: `RelayTests/App/RelayRuntimeTests.swift`; keep `RelayTests/App/AppModelTests.swift` green throughout

- [ ] **Step 1: Characterization test first.** Assert `AppModel`'s current public UI state/actions exist and production wiring works end-to-end (a smoke test that constructing the production graph yields a functional model). Lock the observable surface so the refactor cannot change it.

- [ ] **Step 2: Run — verify it passes today** (characterization baseline is green before refactor).

- [ ] **Step 3: Introduce `RelayRuntime` incrementally.** Do this in small sub-steps, green between each — move ONE service group at a time out of `AppModel.init` into `RelayRuntime`:

```swift
@MainActor
final class RelayRuntime {
    let settings: SettingsStoring
    let permissions: PermissionService
    let speechIn: SpeechInputServices     // dictation coordinator, STT registry/router, mic
    let speechOut: SpeechOutputServices   // speech coordinator, TTS registry/router, players
    let integrations: IntegrationServices // socket server, receiver, manager, installers
    let sessions: SessionServices         // registry, focus resolution
    let diagnostics: Diagnostics

    static func makeProduction() -> RelayRuntime { /* build the graph currently in AppModel.init */ }
    init(settings:permissions:speechIn:speechOut:integrations:sessions:diagnostics:) { ... }
}
```

  Suggested sub-step order (commit-sized, each green): diagnostics → settings/permissions → sessions/focus → speechOut → speechIn → integrations. After each move, `AppModel` reads that service from `runtime` instead of building it.

- [ ] **Step 4: `AppModel(runtime:)`.** Replace the production `convenience init()` with `init(runtime: RelayRuntime)`; `RelayApp` calls `AppModel(runtime: .makeProduction())`. Keep any test-only initializer that injects fakes (or route it through a test `RelayRuntime`).

- [ ] **Step 5: Run — full suite green** after every sub-step and at the end.

- [ ] **Step 6: Commit** (one commit per sub-step is fine)

```bash
git add Relay/App/RelayRuntime.swift Relay/App/AppModel.swift Relay/App/RelayApp.swift \
  RelayTests/App/RelayRuntimeTests.swift
git commit -m "refactor(app): extract RelayRuntime composition root; AppModel receives services"
```

**Acceptance:** `AppModel` no longer builds the full dependency graph; `RelayRuntime.makeProduction()` owns service construction; the public UI surface is unchanged (characterization tests green).

---

## Task 2: Merge STT/TTS backend catalog machinery

**The finding:** `Relay/App/SpeechBackendCatalog.swift` (~254 lines) and `Relay/App/TTSBackendCatalog.swift` (~237 lines) are near-identical; `TTSBackendCatalog.swift:5` says "Mirrors STTBackendStatus exactly" and line 26 "Mirrors refreshSpeechBackendStatuses()'s race-safety exactly". Both implement availability refresh, enabled order, generation counters, download progress, race protection, sorting, enable/disable, reorder.

**The fix:** a shared generic `BackendStatus` + catalog. STT and TTS supply backend-specific registries + labels only. **Behavior-preserving.**

**Files:**
- Create: `Relay/App/BackendCatalog.swift` (shared `BackendStatus` + generic catalog)
- Modify: `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/TTSBackendCatalog.swift` (become thin adapters)
- Test: characterization tests for both catalogs first, then the shared catalog tests

- [ ] **Step 1: Characterization tests first.** Lock current behavior of BOTH catalogs: availability refresh result, generation-counter race safety (a stale refresh does not overwrite a newer one), reorder/enable/disable outcomes, download-progress propagation. Run against the existing types.

- [ ] **Step 2: Run — verify green** (baseline).

- [ ] **Step 3: Extract the shared generic catalog.** Move the algorithm (refresh/order/generation/progress/race/sort/enable/reorder) into `BackendCatalog<Backend>`; STT/TTS pass their registry + labels. Delete the duplicated logic from both files; keep only backend-specific glue.

- [ ] **Step 4: Run — the SAME characterization tests still pass** (behavior identical).

- [ ] **Step 5: Commit**

```bash
git add Relay/App/BackendCatalog.swift Relay/App/SpeechBackendCatalog.swift Relay/App/TTSBackendCatalog.swift \
  RelayTests/App/SpeechBackendCatalogTests.swift RelayTests/App/TTSBackendCatalogTests.swift \
  RelayTests/App/BackendCatalogTests.swift
git commit -m "refactor(catalog): merge STT/TTS backend catalog machinery into one generic catalog"
```

**Acceptance:** one catalog algorithm; race-safety (generation counter) and reorder/enable/disable behavior identical to before.

---

## Task 3: One source of truth for the latest agent response

**The finding (a real divergence bug):** `Relay/Integrations/IntegrationManager.swift:105` writes `await store.set(event)` (the `LatestAgentResponseStore` actor) AND line 113 sets `latestResponse = event` (an `@Observable` MainActor property). The availability GATE reads `integrationManager.latestResponse != nil` (`AppModel.swift:727,855`) while spoken CONTENT reads `store.get()` (IntegrationManager line ~162). They can diverge — `AppModelTests.swift:396-432` documents the trap. A third per-session copy `AgentSession.latestResponse` (`Sessions/Domain/AgentSession.swift:14`) also exists.

**The fix:** one authoritative global owner — the `LatestAgentResponseStore` actor. The gate and the content read the SAME source. Remove the duplicate `@Observable latestResponse` or make it a pure projection of the store. Keep the per-session copy only if a resolver needs it (document).

**Files:**
- Modify: `Relay/Integrations/IntegrationManager.swift` (single writer path; gate derives from the store)
- Modify: `Relay/App/AppModel.swift:727,855` (gate reads the store, not a separate observable)
- Test: `RelayTests/App/AppModelTests.swift` (extend the documented trap test)

- [ ] **Step 1: Characterization test first.** Lock the current observable behavior the UI depends on (that `latestResponse` becomes non-nil after an event, and content is available). Then add a FAILING test asserting the gate and the content cannot diverge: after `store.set(event)`, both the gate predicate and `store.get()` reflect the same event; if the store is cleared, the gate is false.

- [ ] **Step 2: Run — verify the divergence test fails** today.

- [ ] **Step 3: Implement.** Make the gate a projection of the store (e.g. `AppModel` observes a single published value that is set only from the store, or the gate calls into the store). Remove the second independent write so there is exactly one writer. Preserve `@Observable` UI updates (the projection must still drive SwiftUI). Document the fate of `AgentSession.latestResponse`.

- [ ] **Step 4: Run — verify pass.** Full suite green, including the existing trap test.

- [ ] **Step 5: Commit**

```bash
git add Relay/Integrations/IntegrationManager.swift Relay/App/AppModel.swift RelayTests/App/AppModelTests.swift
git commit -m "fix(integrations): single source of truth for latest agent response so gate and content cannot diverge"
```

**Acceptance:** the availability gate and spoken content read the same source; they cannot diverge; UI still updates.

---

## Task 4: Remove the dormant `RecentInteractionTracker`

**The finding:** `Relay/Sessions/RecentInteractionTracker.swift` — only writer is `Relay/SpeechIn/DictationCoordinator.swift:126` (`await recentInteractions.record(...)`); the only reader of `.latest()` is `RecentInteractionTrackerTests.swift`; no production consumer; the file itself says (line ~7) "no resolver consumes it as of this writing".

**The fix:** DELETE it (type + test + the write call + the property wherever it is held), unless the implementer identifies a *current, documented* decision that needs it (default: delete).

**Files:**
- Delete: `Relay/Sessions/RecentInteractionTracker.swift`, `RelayTests/Sessions/RecentInteractionTrackerTests.swift`
- Modify: `Relay/SpeechIn/DictationCoordinator.swift` — remove the stored property (~:56), the init parameter + default (~:98), the assignment (~:110), and the `record(...)` call (~:126)
- Modify: `Relay/App/AppModel.swift` — remove the tracker construction/wiring (~:176, ~:233) (and its slot in `RelayRuntime` if Task 1 moved it there)
- Note: the Step 1 grep + compiler errors surface every reference; the list above is so the init-parameter default is not missed

- [ ] **Step 1: Confirm no production reader.** `grep -rn "\.latest(" Relay/ RelayTests/` and `grep -rn "RecentInteraction" Relay/`. If the only reader is the test, proceed. If a resolver reads it, STOP and convert this task into "integrate it into that documented decision" instead.

- [ ] **Step 2: Delete** the type, its test, the write call, and the property. `xcodegen generate`.

- [ ] **Step 3: Run — full suite green** with the type gone; no dangling references; zero warnings.

- [ ] **Step 4: Commit**

```bash
git rm Relay/Sessions/RecentInteractionTracker.swift RelayTests/Sessions/RecentInteractionTrackerTests.swift
git add Relay/SpeechIn/DictationCoordinator.swift Relay/App/AppModel.swift
git commit -m "refactor(sessions): remove dormant RecentInteractionTracker (no production consumer)"
```

**Acceptance:** the type is gone; the build and suite pass; no references remain.

---

## Task 5: Narrow hotkey side effects (matcher reset only; event tap already fine)

**The finding (PARTLY):** `Relay/App/AppModel.swift:512` `updateSettings` unconditionally calls `registerHotkeys()` (line 515); voice/rate/backend setters route through it; `registerHotkeys` → `hotkeyManager.register` → `matcher = HotkeyMatcher(definitions:)` (`Relay/System/GlobalHotkeyManager.swift:211`) ALWAYS rebuilds the matcher, discarding in-flight chord/double-tap state. NOTE: the CG event tap is NOT re-created — guarded by `if eventTap != nil { return .registered }` (line 214). **So fix the matcher reset only; there is no event-tap churn to fix.**

**The fix:** a normal settings change (voice/rate/backend) saves only; only a change to hotkey *definitions* rebuilds the matcher; a permission/event-tap change re-registers the tap. **Behavior-preserving except that voice/rate/backend changes no longer reset gesture state (the intended fix).**

**Files:**
- Modify: `Relay/App/AppModel.swift:512-515` (split the change handler)
- Modify: `Relay/System/GlobalHotkeyManager.swift` (add a matcher-only update distinct from full register, if not already separable)
- Test: `RelayTests/App/AppModelHotkeySideEffectTests.swift` (create)

- [ ] **Step 1: Failing/characterization tests.**
  - `testChangingVoiceDoesNotRebuildMatcher`: change `ttsVoiceIdentifier`; assert the matcher instance/generation is unchanged (spy on `HotkeyMatcher` construction).
  - `testChangingHotkeyDefinitionRebuildsMatcher`: change a hotkey; assert the matcher IS rebuilt.
  - `testEventTapNotReRegisteredOnAnyChange` (lock current correct behavior).

- [ ] **Step 2: Run — verify fail** (voice change rebuilds matcher today).

- [ ] **Step 3: Implement.** In `updateSettings`, compare old vs new `hotkeys`; only call the matcher rebuild when the hotkey definitions changed. Keep event-tap registration exactly as is (already guarded). Add a `GlobalHotkeyManager.updateMatcher(definitions:)` if needed so a definitions change can rebuild the matcher without touching the tap.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/App/AppModel.swift Relay/System/GlobalHotkeyManager.swift \
  RelayTests/App/AppModelHotkeySideEffectTests.swift
git commit -m "fix(hotkeys): rebuild the matcher only when hotkey definitions change"
```

**Acceptance:** changing voice/rate/backend does not reset active gesture state; changing a hotkey definition does rebuild the matcher; the event tap is never re-created.

---

## Task 6: Resilient per-field settings decode + migration

**The finding:** `Relay/System/SettingsStore.swift:18-25` — `load()` does `try? JSONDecoder().decode(AppSettings.self, ...)` and returns `.defaults` on ANY failure. `Relay/Domain/AppSettings.swift:27-45` `init(from:)` decodes six required fields with `decode` (`dictationMode, hotkeys, sttBackendOrder, ttsBackendOrder, ttsRate, autoReadEnabled`) — any one failing throws and resets EVERYTHING. Optional/newer fields already use `decodeIfPresent` with fallbacks. Key `relay.settings.v1` is versioned in name only; no migration logic.

**The fix:** make EACH field independently defaultable (per-field decode with fallback + normalization) so one bad/new field cannot reset unrelated keybinds/speech prefs. On complete corruption: preserve the corrupt blob for diagnostics/recovery, load defaults, record a privacy-safe structural diagnostic. Add explicit schema versioning/migration.

**Files:**
- Modify: `Relay/Domain/AppSettings.swift:27-45` (`init(from:)` — every field `decodeIfPresent ?? defaults.<field>`, with normalization)
- Modify: `Relay/System/SettingsStore.swift:18-29` (on total corruption: preserve blob, log structural diagnostic, return defaults; add version handling)
- Test: `RelayTests/Domain/AppSettingsDecodeTests.swift`, `RelayTests/System/SettingsStoreTests.swift`

- [ ] **Step 1: Failing tests.**
  - `testMissingOneRequiredFieldKeepsOthers`: encode a settings blob missing `ttsRate` (or with `ttsRate` invalid); decode; assert `hotkeys` and `sttBackendOrder` are the saved values, only `ttsRate` fell back to default.
  - `testInvalidOneFieldDoesNotResetUnrelated`.
  - `testUnknownBackendIDsAreNormalized` (drop unknown ids, keep known order).
  - `testOldSchemaVersionMigrates` (a v0/legacy blob loads via migration, not a reset).
  - `testFullyCorruptJSONPreservesBlobAndRecordsDiagnostic`: garbage bytes → defaults returned, corrupt blob preserved under a recovery key, a structural (content-free) diagnostic recorded.

- [ ] **Step 2: Run — verify fail** (today one bad required field resets all).

- [ ] **Step 3: Implement.**
  - `init(from:)`: decode every field with `decodeIfPresent(...) ?? AppSettings.defaults.<field>`, then normalize (e.g. clamp `ttsRate`, drop unknown backend ids). No field's failure resets another.
  - `SettingsStore.load()`: attempt decode; on total failure, copy the raw `data` to a recovery key (e.g. `relay.settings.corrupt.<timestamp>`), record a privacy-safe structural diagnostic (no contents), return `.defaults`. Add a `schemaVersion` field and a migration switch for future versions.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Domain/AppSettings.swift Relay/System/SettingsStore.swift \
  RelayTests/Domain/AppSettingsDecodeTests.swift RelayTests/System/SettingsStoreTests.swift
git commit -m "fix(settings): per-field resilient decode with recovery blob and schema migration"
```

**Acceptance:** one invalid field does not reset unrelated settings; schema migrations are explicit; full corruption preserves the blob and is visible as a structural diagnostic.

---

## Task 7: CI status checks + fault-injection test coverage

**The finding:** the reviewed commit has no GitHub status checks on `main` (audit §10); blocking external boundaries lack fault tests.

**The fix:** a CI workflow that generates the project and runs the suite on every push/PR, plus a checklist of fault-test categories (many delivered by Waves 1–2; the rest added here).

**Files:**
- Create: `.github/workflows/ci.yml`
- Create/extend: fault tests listed below (any not already delivered by Waves 1–2)

- [ ] **Step 1: Add CI.** `.github/workflows/ci.yml` on `push` and `pull_request`:

```yaml
name: CI
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: macos-15   # match the project's minimum-OS toolchain
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        run: xcodegen generate
      - name: Test
        run: xcodebuild test -scheme Relay -destination 'platform=macOS' | tail -60
```

  **Reconcile the runner with what Wave 2 shipped before relying on CI as a merge gate:** if Wave 2 Task 7 Option A raised the deployment target to macOS 26, a `macos-15` runner image may lack the matching SDK and fail to build. Pin the runner to an image whose Xcode/SDK supports the shipped minimum OS (or keep macOS 14 support via Wave 2 Option B). Do not merge-gate on a workflow that cannot build the current target.

- [ ] **Step 2: Verify CI locally** — run the exact `xcodegen generate` + `xcodebuild test` the workflow runs; expect `** TEST SUCCEEDED **`.

- [ ] **Step 3: Fault-test checklist.** Confirm each category has a test (mark which wave delivered it); add the missing ones:
  - **Subprocesses** (Wave 1 Task 1): hang, huge stdout, huge stderr, nonzero exit, missing executable.
  - **Unix sockets**: stale socket (W1 T3), active second instance (W1 T3), peer accepts but never reads (W1 T2), disconnect mid-write, oversized line, connection flood (existing `UnixSocketServer` has `maxConcurrentConnections` — add a flood test).
  - **TTS lifecycle** (Wave 2 T1/T3): for every backend — scheduled → started → exactly one terminal; natural finish, cancel, playback-start failure, synthesis failure, decode failure.
  - **Dictation** (Wave 2 T5): start/finish race, cancel during start, zero microphone frames, interim STT still running on release, final not blocked by interim.
  - **Sessions/focus** (Wave 1 T4): dead-process prune, TTL expiry, two sessions same terminal, tmux exact pane, Herdr exact pane, focus change during generation, unknown focus → silence.
  - **Settings** (Wave 3 T6): missing field, invalid one field, unknown backend ids, old schema version, corrupt JSON.

- [ ] **Step 4: Add the missing fault tests** (disconnect mid-write, oversized line, connection flood, and any focus/dictation cases not yet covered). Run full suite green.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml RelayTests/
git commit -m "test(ci): add GitHub Actions build/test workflow and fill fault-injection coverage"
```

**Acceptance:** every push/PR is built and tested by CI; each fault-test category has at least one test; the suite is green.

---

## Execution

Recommended: **superpowers:subagent-driven-development** — fresh implementer per task, review between tasks. **This wave depends on Waves 1 and 2 being merged.** Every refactor task (1, 2, 4, 5) writes characterization tests before touching code and must leave behavior unchanged; Tasks 3, 5, 6 additionally fix a named bug. Run the full suite (`** TEST SUCCEEDED **`, zero warnings) before every commit. Guiding rule: prefer deleting a state or code path over adding another compensating guard.
