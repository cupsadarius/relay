# Relay Cleanup 2: Dead Code Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete production-dead and test-only code across Relay (App, Domain, System, Integrations, Sessions, SpeechOut, Backends, RelayHook, project scaffolding) without changing any user-visible behavior.

**Architecture:** Pure deletion/retargeting. Each task covers one area. Before every deletion a guard `rg` proves the symbol has no production reader. Tests that only exercise deleted code are deleted in the same task, and tests that used a deleted alias are retargeted to the surviving API. Every task ends with the full build + test suite green and one conventional commit.

**Tech Stack:** Swift 6, SwiftUI, XCTest, XcodeGen, FluidAudio 0.15.7, WhisperKit 1.1.0, ripgrep, perl (for mechanical multi-file argument removal)

## Preconditions and ordering

- Run this in a git worktree at `/Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code` on branch `cleanup/2-dead-code`, cut from `main` **after plan 1 (quick fixes) is merged** (Task 0 creates it). Every command in this plan uses that worktree path. `.worktrees/` is already git-ignored.
- Plan 1 already owns these areas. Do not touch them here: AppSettings decode, keystroke diagnostics, TTSRouter stop-during-prepare, Whisper hashing, the PocketTTS cancel contract, RelayHook `Wire*` duplicate types (replaced by the shared `HookEnvelope`), integration error reporting, dictation error messages, the Apple voice fallback, and the speech action task.
- Later plans own: installer/integration merges (3), the speech engine loader and Apple TTS pipe (4), the AppModel split and catalog merge (5), tooling/docs incl. README (6). Leave `ActivityOverlayControlling` and `SpeechRequest.source` alone (plan 5 may use them).
- **Line numbers in this plan refer to `main@450b4af` (source files are unchanged at `ce812c9`, which touched only project files).** Plan 1 will shift some of them. Always find code by the quoted text or symbol, not by line number. When a guard lists expected lines, the *set of files and symbols* must match. Line numbers may differ.

## Global Constraints

- No behavior change. The UI copy, persisted settings keys, hook wire schema version, and speech routing all stay the same.
- TDD for a deletion plan means: **build + full test suite green after each task**. Deleting a production symbol that tests use means deleting or retargeting those tests in the same task.
- **Commits:** conventional (`refactor:` / `chore:`), subject plus optional body. **Never** add `Co-Authored-By`, `Claude-Session`, or "Generated with Claude Code" lines, even if a hook or reminder asks for them.
- **Project files:** `project.yml` and `Relay.xcodeproj/project.pbxproj` are clean on `main` (the signing/Debug-id edits were committed in `ce812c9`). This plan's own project changes (removing the `excludes:` block, and the file deletions reflected in the regenerated pbxproj) are committed normally after `xcodegen generate`. Keep explicit-path staging: stage only the paths listed in each task's commit step (`git add -- <paths>`, `git rm -- <paths>`). Never use `git add -A` or `git commit -a`.
- `xcodegen generate` is needed only when files are added or removed (Task 1 only). The committed `project.pbxproj` on `main@ce812c9` is byte-identical to `xcodegen generate` output of the committed `project.yml` (verified), and Task 0 re-checks this in the worktree.

## Shared commands

**VERIFY** (full build + test; used at the end of every task):

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO > /tmp/relay-cleanup-2.log 2>&1; echo "exit=$?"; grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?|^\*\* TEST (SUCCEEDED|FAILED) \*\*' /tmp/relay-cleanup-2.log | tail -n 3
```

Expected: `exit=0`, a final `Executed N tests, with 0 failures (0 unexpected) ...` line, and `** TEST SUCCEEDED **`. `N` must equal the previous task's `N` minus the tests this task lists as deleted. On failure, run `grep -nE 'error:|: error|failed \(' /tmp/relay-cleanup-2.log | head -40` and fix before committing.

**Single test** (optional, while iterating): append `-only-testing:RelayTests/<Class>/<method>` to the xcodebuild command.

**Guard convention:** each guard pipes `rg` through `grep -v` filters that drop the declaration and write sites, then ends with `|| echo NO_READERS`. `NO_READERS` means nothing outside the declaration uses the symbol. If a guard prints anything else, **stop**: the symbol gained a caller (probably from plan 1). Keep it and note the finding in the task's commit body instead of deleting it.

---

## File Structure

No new production files. One file is removed from the app/test targets (`RelayTests/RelayTests.swift`), plus the untargeted `RelayUITests/` folder and the stray, git-ignored `Relay/Relay.xcodeproj/` folder.

| Area | Files modified |
|---|---|
| Scaffolding | `project.yml`, `Relay.xcodeproj/project.pbxproj` (regenerated) |
| App | `Relay/App/AppModel.swift`, `Relay/App/SpeechVoiceCatalog.swift`, `Relay/App/SpeechModelController.swift`, `Relay/App/BackendCatalog.swift`, `Relay/App/ActivityOverlayModel.swift`, `Relay/App/Settings/{SpeechVoiceRow,SpeechModelRow,DictationSettingsView,IntegrationsSettingsView}.swift` |
| Domain | `Relay/Domain/{SpeechModels,SpeechModelManaging,BackendAvailability}.swift` |
| System | `Relay/System/{PermissionService,Diagnostics}.swift` |
| Integrations | `Relay/Integrations/Domain/AgentResponseEvent.swift`, `Relay/Integrations/{ClaudeCode/ClaudeCodeHookPayload,ClaudeCode/ClaudeCodeIntegration,Codex/CodexHookPayload,Codex/CodexIntegration,Codex/CodexInstaller,LatestAgentResponseStore}.swift` |
| Sessions | `Relay/Sessions/AgentSessionRegistry.swift`, `Relay/Sessions/Domain/TerminalContext.swift` |
| RelayHook | `RelayHook/main.swift` (env allowlist only) |
| SpeechIn | `Relay/SpeechIn/{SpeechToTextBackend,STTRouter,MicrophoneCapture,DictationCoordinator}.swift` |
| SpeechOut | `Relay/SpeechOut/{TextToSpeechBackend,TTSRouter,StreamingAudioPlayer,SpeechCoordinator,AppleTTSBackend,AppleTTSAudioSource}.swift` |
| Backends | `Relay/Backends/{AppleSpeechBackend,ParakeetBackend,KokoroTTSBackend,PocketTTSBackend,AppleSpeechModelManager,ParakeetModelManager,KokoroModelManager,PocketTTSModelManager,FluidAudioKokoroEngine,FluidAudioPocketTTSEngine,StreamingTranscriber}.swift`, `Relay/Backends/Whisper/{WhisperBackend,WhisperRuntime,WhisperModelManager,WhisperModelCatalog}.swift` |
| Tests | matching files under `RelayTests/` (listed per task) |

---

### Task 0: Preflight (worktree, baseline)

**Files:** none modified.

- [ ] **Step 1: Confirm plan 1 is merged and the main checkout is clean**

```bash
cd /Users/darius/Personal/relay && git switch main && git pull --ff-only && git status --short && git log --oneline -25
```

Expected: `git status --short` prints no tracked-file changes, and the log contains `ce812c9` plus plan 1's merge (branch `cleanup/1-*`). If plan 1 is not merged, **stop**. This plan must run after plan 1.

- [ ] **Step 2: Create the worktree**

```bash
cd /Users/darius/Personal/relay && git worktree add .worktrees/cleanup-2-dead-code -b cleanup/2-dead-code main && cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git status --short && git branch --show-current
```

Expected: no status output, then `cleanup/2-dead-code`.

- [ ] **Step 3: Confirm xcodegen is a no-op on the committed state**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && xcodegen generate -q && git status --short
```

Expected: no output. If the pbxproj changes, **stop and report**, because later tasks rely on regenerated project files matching the committed ones.

- [ ] **Step 4: Baseline**

Run **VERIFY** (from the worktree). Expected: `** TEST SUCCEEDED **`. Record `N0` = the executed test count.

---

### Task 1: Scaffolding (template tests, untargeted UI tests, stray project)

**Files:**
- Delete: `RelayTests/RelayTests.swift` (empty Swift Testing template)
- Delete: `RelayUITests/RelayUITests.swift`, `RelayUITests/RelayUITestsLaunchTests.swift` (tracked, in no target)
- Delete (untracked, git-ignored, exists only in the main checkout, not in the worktree): `/Users/darius/Personal/relay/Relay/Relay.xcodeproj/` (contains only `project.xcworkspace/xcuserdata`)
- Modify: `project.yml:19-21` (drop the `excludes:` block that existed only for the stray project)
- Regenerate: `Relay.xcodeproj/project.pbxproj`

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -n 'RelayUITests' project.yml Relay.xcodeproj || echo NOT_IN_PROJECT
rg -l 'import Testing' RelayTests
git ls-files Relay/Relay.xcodeproj | wc -l
ls -d /Users/darius/Personal/relay/Relay/Relay.xcodeproj
find Relay -name '*.xcworkspace' -not -path 'Relay/Relay.xcodeproj/*'
```

Expected: `NOT_IN_PROJECT`, then `RelayTests/RelayTests.swift` (the only Swift Testing file), then `0`, then the stray directory's path (or a "No such file" error if it was already removed), then nothing.

- [ ] **Step 2: Delete the files**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git rm -q -- RelayTests/RelayTests.swift RelayUITests/RelayUITests.swift RelayUITests/RelayUITestsLaunchTests.swift && rm -rf /Users/darius/Personal/relay/Relay/Relay.xcodeproj
```

- [ ] **Step 3: Remove the stale excludes from `project.yml`**

Replace:

```yaml
    sources:
      - path: Relay
        excludes:
          - Relay.xcodeproj
          - "**/*.xcworkspace"
      - path: RelayHook/HookTransportClient.swift
```

with:

```yaml
    sources:
      - path: Relay
      - path: RelayHook/HookTransportClient.swift
```

- [ ] **Step 4: Regenerate and inspect**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && xcodegen generate -q && git diff --stat
```

Expected: `project.yml | 3 ---`, `Relay.xcodeproj/project.pbxproj | 4 ----` (only the `RelayTests.swift` references), plus the three deletions.

- [ ] **Step 5: VERIFY**

Expected: green. `N1 = N0 - 1` (the Swift Testing `example` test). If the log reports Swift Testing counts separately, the XCTest count is unchanged.

- [ ] **Step 6: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- project.yml Relay.xcodeproj/project.pbxproj && git commit -m "chore: remove template tests, untargeted UI tests and stray project excludes"
```

---

### Task 2: App layer dead helpers and test-only aliases

**Files:**
- Modify: `Relay/App/AppModel.swift` (`import AVFoundation` at :3, `recordDiagnostic` at :518-522, `testVoice()` at :779-795 and the doc at :775-776)
- Modify: `Relay/App/SpeechVoiceCatalog.swift:12-21`
- Modify: `Relay/App/Settings/SpeechVoiceRow.swift:8,28`
- Modify: `Relay/App/Settings/SpeechModelRow.swift:16-17`
- Modify: `Relay/App/Settings/DictationSettingsView.swift:35-39`
- Modify: `Relay/Domain/SpeechModels.swift:33-35` (`SpeechSource.manualReplay`, `.futureIntegration`, `.testVoice`)
- Test: `RelayTests/App/AppModelTests.swift:509-532`, `RelayTests/App/SettingsViewsSmokeTests.swift`

Deleted tests: `AppModelTests.testTestVoiceSpeaksAFixedSampleSentenceThroughTheCurrentSelection`, `AppModelTests.testTestVoiceFailureIsLoggedAsTTSFailure`, and the 3 tests of `SpeechBackendModelDisplayModeTests` (5 total).

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift 'recordDiagnostic' Relay RelayHook | grep -v 'func recordDiagnostic' || echo NO_READERS
rg -n '\bAV[A-Z]\w*' Relay/App/AppModel.swift | grep -v 'import AVFoundation' || echo NO_READERS
rg -Hn --type swift 'SpeechVoiceCataloging' Relay RelayHook | grep -v 'protocol SpeechVoiceCataloging' | grep -v 'struct SpeechVoiceCatalog: SpeechVoiceCataloging' || echo NO_READERS
rg -Hn --type swift 'canTest' Relay RelayHook | grep -v 'let canTest = true' | grep -v 'disabled(!presentation.canTest)' || echo NO_READERS
rg -Hn --type swift 'SpeechBackendModelDisplayMode' Relay RelayHook | grep -v 'enum SpeechBackendModelDisplayMode' || echo NO_READERS
rg -Hn --type swift '\.(detailLabel|showsRemove)\b' Relay RelayHook || echo NO_READERS
rg -Hn --type swift 'testVoice\b' Relay RelayHook | grep -v 'testVoiceSampleText' | grep -v 'func testVoice()' | grep -v 'source: .testVoice' | grep -v 'case testVoice' || echo NO_READERS
rg -Hn --type swift '\.(manualReplay|futureIntegration)\b' Relay RelayHook || echo NO_READERS
```

Expected: eight `NO_READERS` lines.

- [ ] **Step 2: `AppModel.swift`**

1. Delete line 3, `import AVFoundation`.
2. Delete:

```swift
    /// Lets `SpeechBackendCatalog.swift` record diagnostics without widening `diagnostics` past
    /// this file.
    func recordDiagnostic(_ event: DiagnosticsEvent) {
        diagnostics.record(event)
    }

```

3. Replace the `testVoiceSampleText` doc and delete `testVoice()`. Replace:

```swift
    /// Fixed sample sentence spoken by the TTS tab's "Test Voice" button. Never user-authored
    /// content, so routing it through the normal speak path carries no privacy risk.
    private static let testVoiceSampleText = "This is a preview of the selected voice and speaking rate."

    /// Speaks a fixed sample sentence through the current TTS backend order and options (voice,
    /// rate). Used by the TTS settings tab's Test Voice button.
    func testVoice() async {
        let request = SpeechRequest(
            text: Self.testVoiceSampleText,
            source: .testVoice,
            mode: .userRequested,
            sessionID: nil
        )
        do {
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

```

with:

```swift
    /// Fixed sample sentence spoken by each voice row's "Test" button (`previewVoice`). Never
    /// user-authored content, so it carries no privacy risk.
    private static let testVoiceSampleText = "This is a preview of the selected voice and speaking rate."

```

- [ ] **Step 3: `SpeechModels.swift`**: replace the `SpeechSource` enum with:

```swift
enum SpeechSource: String, Codable, Equatable, Sendable {
    case selection
    case claudeCode
    case codex
}
```

- [ ] **Step 4: `SpeechVoiceCatalog.swift`**: delete the protocol:

```swift
@MainActor
protocol SpeechVoiceCataloging {
    func voices(for backendID: String) -> [SpeechVoiceOption]
    func activeVoiceID(for backendID: String, settings: AppSettings) -> String?
    func storedValue(for voiceID: String, backendID: String) -> String??
    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions?
}

```

and change `struct SpeechVoiceCatalog: SpeechVoiceCataloging {` to `struct SpeechVoiceCatalog {`.

- [ ] **Step 5: `SpeechVoiceRow.swift`**: delete `    let canTest = true`. Change `Button(presentation.testTitle, action: test).disabled(!presentation.canTest)` to `Button(presentation.testTitle, action: test)`. `SpeechVoiceRowPresentation` keeps `isActive`, the titles, and `canSelect`, so it is not empty and stays.

- [ ] **Step 6: `SpeechModelRow.swift`**: delete these lines and the blank line after them:

```swift
    var detailLabel: String { detail }
    var showsRemove: Bool { canRemove }
```

- [ ] **Step 7: `DictationSettingsView.swift`**: delete the trailing enum and the blank line before it:

```swift
enum SpeechBackendModelDisplayMode: Equatable {
    case none
    case nestedList
    static func make(modelCount: Int) -> Self { modelCount > 0 ? .nestedList : .none }
}
```

- [ ] **Step 8: Tests**

1. `RelayTests/App/AppModelTests.swift`: delete the whole methods `testTestVoiceSpeaksAFixedSampleSentenceThroughTheCurrentSelection` and `testTestVoiceFailureIsLoggedAsTTSFailure`.
2. `RelayTests/App/SettingsViewsSmokeTests.swift`: retarget the aliases, then delete the `canTest` asserts:

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -pi -e 's/\.showsRemove\b/.canRemove/g; s/\.detailLabel\b/.detail/g; $_ = "" if /XCTAssertTrue\((?:in)?active\.canTest\)/' RelayTests/App/SettingsViewsSmokeTests.swift
```

3. In the same file, delete the whole `final class SpeechBackendModelDisplayModeTests: XCTestCase { ... }` (its doc comments and three tests) and the blank line after it.

- [ ] **Step 9: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'recordDiagnostic' -e 'SpeechVoiceCataloging' -e 'canTest' -e 'SpeechBackendModelDisplayMode' -e '\bdetailLabel\b' -e '\bshowsRemove\b' -e 'manualReplay' -e 'futureIntegration' -e '\.testVoice\b' -e 'func testVoice\(' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`.

- [ ] **Step 10: VERIFY**: green, `N2 = N1 - 5`.

- [ ] **Step 11: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/App/AppModel.swift Relay/App/SpeechVoiceCatalog.swift Relay/App/Settings/SpeechVoiceRow.swift Relay/App/Settings/SpeechModelRow.swift Relay/App/Settings/DictationSettingsView.swift Relay/Domain/SpeechModels.swift RelayTests/App/AppModelTests.swift RelayTests/App/SettingsViewsSmokeTests.swift && git commit -m "refactor(app): remove dead App helpers, unused speech sources and test-only aliases"
```

---

### Task 3: Speech model metadata (`isLoaded`, download sizes, Whisper descriptor fields, Parakeet `downloadModels`)

**Files:**
- Modify: `Relay/Domain/SpeechModelManaging.swift:7,30`
- Modify: `Relay/App/SpeechModelController.swift:164-168`
- Modify: `Relay/Backends/{AppleSpeechModelManager,ParakeetModelManager,KokoroModelManager,PocketTTSModelManager}.swift`
- Modify: `Relay/Backends/Whisper/WhisperModelManager.swift`, `Relay/Backends/Whisper/WhisperRuntime.swift:47-51`, `Relay/Backends/Whisper/WhisperModelCatalog.swift`
- Modify: `Relay/Backends/ParakeetBackend.swift:65-80`
- Test: `RelayTests/Domain/SpeechModelManagingTests.swift`, `RelayTests/App/{AppModelTests,SpeechModelControllerTests,TTSBackendCatalogTests,SettingsViewsSmokeTests}.swift`, `RelayTests/Backends/{AppleSpeechModelManagerTests,ParakeetBackendTests}.swift`, `RelayTests/Backends/Whisper/{WhisperModelManagerTests,WhisperModelCatalogTests}.swift`

Removing `SpeechModelDescriptor.approximateDownloadBytes` makes `WhisperModelDescriptor.approximateDiskBytes` test-only, because its only production read fed that field. It is deleted here too, together with `upstreamCheckpoint`.

Deleted tests: `ParakeetBackendTests.testDownloadModelsAllowsDownload`, `...ForwardsProgressToCaller`, `...MapsFailureToInitializationFailed`, `...PreservesCancellation` (4 total).

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift '\.isLoaded\b' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.approximateDownloadBytes\b' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.upstreamCheckpoint\b' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.approximateDiskBytes\b' Relay RelayHook | grep -v 'approximateDownloadBytes: whisperDescriptor.approximateDiskBytes' || echo NO_READERS
rg -Hn --type swift 'downloadModels\(' Relay RelayHook | grep -v 'func downloadModels' | grep -v '///' || echo NO_READERS
```

Expected: five `NO_READERS` lines.

- [ ] **Step 2: Remove the fields from the domain types**

In `Relay/Domain/SpeechModelManaging.swift`, delete `    let approximateDownloadBytes: Int64?` from `SpeechModelDescriptor` and `    var isLoaded: Bool` from `SpeechModelStatus`.

- [ ] **Step 3: Drop the trailing `isLoaded:` / `approximateDownloadBytes:` arguments at every construction site**

Both are always the last argument, so a trailing-argument regex is exact. This was dry-run on `450b4af`.

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 's/,\s*isLoaded: [^,\n)]+(\s*\))/$1/g; s/,\s*approximateDownloadBytes: [^,\n)]+(\s*\))/$1/g' \
  Relay/App/SpeechModelController.swift Relay/Backends/AppleSpeechModelManager.swift Relay/Backends/ParakeetModelManager.swift \
  Relay/Backends/KokoroModelManager.swift Relay/Backends/PocketTTSModelManager.swift Relay/Backends/Whisper/WhisperModelManager.swift \
  RelayTests/Domain/SpeechModelManagingTests.swift RelayTests/App/AppModelTests.swift RelayTests/App/SpeechModelControllerTests.swift \
  RelayTests/App/TTSBackendCatalogTests.swift RelayTests/App/SettingsViewsSmokeTests.swift
```

This also turns the `makeModelStatus(... isSelected: Bool = false, isLoaded: Bool = false)` helper in `AppModelTests.swift` into `isSelected: Bool = false` only.

- [ ] **Step 4: Fix the comments and the now-unused `loadedID`**

1. `WhisperModelManager.swift`, `models()`: delete `        let loadedID = await runtime.currentModelID`. Replace its doc comment with:

```swift
    /// All 11 models, in catalog order, each with `installState` from the store and `isSelected`
    /// from the selection seam. The two are independent: a model can be downloaded without being
    /// selected, or selected without being downloaded (see `WhisperModelManagerTests
    /// .testDownloadedAndSelectedAreIndependent`).
```

2. `WhisperModelManager.swift`, the `init` parameter doc: change `///     `isLoaded`/unload-before-remove, never for download or presence.` to `///     unload-before-remove only, never for download or presence.`
3. `WhisperRuntime.swift`, the `currentModelID` doc: change `` `WhisperModelManager`) report per-model `isLoaded` status and decide whether a model `` to `` `WhisperModelManager`) decide whether a model ``. The following lines stay (`switch or removal needs to unload first, ...`).
4. `ParakeetModelManager.swift`: replace the `models()` doc with:

```swift
    /// Always exactly one status. `isSelected` is always true: a one-model backend's only model
    /// is always "the selection".
```

Also change the `downloadModel` doc, `/// Validates `id`, then delegates to the engine's own download-and-load, the same path` + `/// `ParakeetBackend.downloadModels(progress:)` uses.`, to the single line `/// Validates `id`, then delegates to the engine's own download-and-load.`

5. `AppleSpeechModelManager.swift`: replace the `models()` doc with:

```swift
    /// Always exactly one status: always `.downloaded` (it ships with macOS -- there is nothing
    /// to fetch) and always selected (the one model IS the selection, mirroring
    /// `ParakeetModelManager`).
```

- [ ] **Step 5: `WhisperModelCatalog.swift`**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 's/\n[ \t]*upstreamCheckpoint: "[^"\n]*",(?=\n)//g; s/\n[ \t]*approximateDiskBytes: [0-9_]+,(?=\n)//g' Relay/Backends/Whisper/WhisperModelCatalog.swift
```

Then edit `WhisperModelDescriptor` by hand:
- Delete `    /// The OpenAI checkpoint this artifact was converted from (e.g. "large-v3-turbo").` and `    let upstreamCheckpoint: String`.
- Delete the four-line `/// Approximate on-disk size ...` doc and `    let approximateDiskBytes: Int64`.
- In the struct doc, change `/// There is deliberately **no** per-model checksum here: identity and approximate size only.` to `/// There is deliberately **no** per-model checksum here: identity metadata only.`
- In the `tokenizerRepo` doc, change `/// guessed from `runtimeArtifact`/`upstreamCheckpoint` -- see` to `/// guessed from `runtimeArtifact` -- see`.
- In the `WhisperModelCatalog` doc, change `/// `WhisperModelStore` need to identify and size each model.` to `/// `WhisperModelStore` need to identify each model.`

- [ ] **Step 6: `ParakeetBackend.swift`**: delete `downloadModels(progress:)` and its whole doc comment (from `    /// Downloads the model if needed, then loads it. Used by the Settings "Download" action.` through the method's closing brace and the blank line after it). `mapLoadError` stays, because `ensureLoaded()` still uses it.

- [ ] **Step 7: Tests**

1. `WhisperModelManagerTests.swift`:
   - Rename `testModelsDescriptorMapsEnglishOnlyAndSize` to `testModelsDescriptorMapsDisplayNameAndEnglishOnly` and delete its `XCTAssertEqual(tinyEn.descriptor.approximateDownloadBytes, 76_650_906)` line.
   - Delete both `XCTAssertFalse(status.isLoaded)` lines (in `testSelectPersistsSelectionAndDoesNotDownloadOrLoad` and `testDownloadModelDelegatesToStoreWithProgress`).
   - Replace the whole `testDownloadedSelectedLoadedAreIndependent` with:

```swift
    func testDownloadedAndSelectedAreIndependent() async throws {
        // .baseEn: downloaded + selected.
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        try await manager.selectModel(WhisperModelID.baseEn.rawValue)

        let models = await manager.models()
        let baseEn = models.first { $0.id == WhisperModelID.baseEn.rawValue }!
        XCTAssertEqual(baseEn.installState, .downloaded)
        XCTAssertTrue(baseEn.isSelected)

        // .smallEn: neither downloaded nor selected.
        let smallEn = models.first { $0.id == WhisperModelID.smallEn.rawValue }!
        XCTAssertEqual(smallEn.installState, .notDownloaded)
        XCTAssertFalse(smallEn.isSelected)
    }
```

2. `AppleSpeechModelManagerTests.swift`: delete `        XCTAssertFalse(models[0].isLoaded)`.
3. `WhisperModelCatalogTests.swift`: rename `testEveryModelHasNonEmptyArtifactAndPositiveSize` to `testEveryModelHasNonEmptyArtifact` and delete `            XCTAssertGreaterThan(d.approximateDiskBytes, 0)`.
4. `ParakeetBackendTests.swift`: delete the four `testDownloadModels*` methods and the `ProgressReportBox` class with its doc comment. In `FakeParakeetEngine`, delete `    var progressToReport: [Double] = []` and this loop in `load(...)`:

```swift
        for fraction in progressToReport {
            progress(fraction)
        }
```

- [ ] **Step 8: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'isLoaded:' -e '\.isLoaded\b' -e '`isLoaded`' -e 'approximateDownloadBytes' -e 'upstreamCheckpoint' -e 'approximateDiskBytes' -e 'downloadModels\(' -e 'ProgressReportBox' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`. The unrelated `private var isLoaded` fields inside engine fakes do not match these patterns.

- [ ] **Step 9: VERIFY**: green, `N3 = N2 - 4`.

- [ ] **Step 10: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/Domain/SpeechModelManaging.swift Relay/App/SpeechModelController.swift Relay/Backends/AppleSpeechModelManager.swift Relay/Backends/ParakeetModelManager.swift Relay/Backends/KokoroModelManager.swift Relay/Backends/PocketTTSModelManager.swift Relay/Backends/ParakeetBackend.swift Relay/Backends/Whisper/WhisperModelManager.swift Relay/Backends/Whisper/WhisperRuntime.swift Relay/Backends/Whisper/WhisperModelCatalog.swift RelayTests/Domain/SpeechModelManagingTests.swift RelayTests/App/AppModelTests.swift RelayTests/App/SpeechModelControllerTests.swift RelayTests/App/TTSBackendCatalogTests.swift RelayTests/App/SettingsViewsSmokeTests.swift RelayTests/Backends/AppleSpeechModelManagerTests.swift RelayTests/Backends/ParakeetBackendTests.swift RelayTests/Backends/Whisper/WhisperModelManagerTests.swift RelayTests/Backends/Whisper/WhisperModelCatalogTests.swift && git commit -m "refactor(models): drop unwired isLoaded, size and checkpoint metadata and Parakeet downloadModels"
```

---

### Task 4: Speech backend contracts (capabilities, `STT prepare()`, `.initializing`)

**Files:**
- Modify: `Relay/Domain/SpeechModels.swift:50-86` (delete `STTCapability`, `STTCapabilities`, `TTSCapability`, `TTSCapabilities`. **Not** `SpeechModelCapabilities`, which lives in `SpeechModelManaging.swift` and is used.)
- Modify: `Relay/SpeechIn/SpeechToTextBackend.swift`, `Relay/SpeechOut/TextToSpeechBackend.swift:29`
- Modify: `Relay/Backends/{AppleSpeechBackend,ParakeetBackend,KokoroTTSBackend,PocketTTSBackend}.swift`, `Relay/SpeechOut/AppleTTSBackend.swift`, `Relay/Backends/Whisper/{WhisperBackend,WhisperRuntime,WhisperModelManager}.swift`
- Modify: `Relay/Domain/BackendAvailability.swift:10`, `Relay/SpeechIn/STTRouter.swift:95-96`, `Relay/App/BackendCatalog.swift:124`
- Test: `RelayTests/Domain/SpeechBackendContractsTests.swift`, `RelayTests/SpeechIn/{STTRouterTests,DictationCoordinatorTests}.swift`, `RelayTests/App/{AppModelTests,TTSBackendCatalogTests}.swift`, `RelayTests/SpeechOut/{TTSRouterTests,AppleTTSBackendTests}.swift`, `RelayTests/Backends/{ParakeetBackendTests,AppleSpeechBackendTests,KokoroTTSBackendTests,PocketTTSBackendTests}.swift`, `RelayTests/Backends/Whisper/WhisperBackendTests.swift`

Deleted tests (14): `SpeechBackendContractsTests.testSTTCapabilityMembership`, `.testTTSCapabilityMembership`, `.testEveryTTSBackendExposesTheSameSynthesisCapabilities`, `.testBackendsExposeCapabilitiesThroughProviderNeutralContracts`; `ParakeetBackendTests.testCapabilitiesIncludeFullyOffline`, `.testCapabilitiesDoNotAdvertiseMultilingual`, `.testPrepareTriggersEngineLoadWithoutAllowingDownload`, `.testPrepareMapsLoadFailedToInitializationFailed`, `.testPreparePreservesCancellationFromLoad`; `AppleSpeechBackendTests.testPrepareMapsAssetPreparationFailureToInitializationFailure`; `KokoroTTSBackendTests.testCapabilities`; `PocketTTSBackendTests.testCapabilities`; `AppleTTSBackendTests.testAppleBackendReportsSupportedCapabilities`; `WhisperBackendTests.testCapabilitiesAdvertiseOfflineAndMultilingual`. Every deleted `prepare` test has a `transcribe` twin that stays: `testTranscribeLazilyLoadsWhenNotYetPrepared`, `testTranscribeMapsLoadFailedToInitializationFailed`, `testTranscribePreservesCancellationFromLoad`, `testTranscribeMapsAssetPreparationFailureToInitializationFailure`.

The router's `STTRouterTests.testMapsFallbackWorthyAvailabilityStatesToSpeechBackendErrors` and both availability-mapping tests lose one table row each. The test count does not change for them.

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift '\b(STT|TTS)Capabilit' Relay RelayHook | grep -v -E 'Relay/Domain/SpeechModels.swift|var capabilities: (STT|TTS)Capabilities|let capabilities = (STT|TTS)Capabilities' || echo NO_READERS
rg -Hn --type swift '(backend|stt|tts|\$0)\.capabilities' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.prepare\(\)' Relay RelayHook | grep -v '///' || echo NO_READERS
rg -Hn --type swift 'initializing' Relay RelayHook | grep -v 'case initializing' | grep -v 'case .initializing:' | grep -v 'Backend is initializing' | grep -v '.unavailable, .initializing, .failed' || echo NO_READERS
```

Expected: four `NO_READERS` lines. `SpeechModelRow`'s `status.capabilities` is `SpeechModelCapabilities` and is not matched.

- [ ] **Step 2: Domain and protocols**

1. `SpeechModels.swift`: delete everything from `enum STTCapability: Sendable {` through the closing brace of `struct TTSCapabilities` (lines 50-86 at `450b4af`), plus the blank line before it.
2. `SpeechToTextBackend.swift` becomes:

```swift
protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }

    func availability() async -> BackendAvailability
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript
}
```

3. `TextToSpeechBackend.swift`: delete `    var capabilities: TTSCapabilities { get }`.
4. `BackendAvailability.swift`: delete `    case initializing`.
5. `STTRouter.swift`, `classify(_:)`: delete these lines:

```swift
        case .initializing:
            .skip(.unavailable("Backend is initializing"))
```

6. `BackendCatalog.swift`: `case .permissionDenied, .unavailable, .initializing, .failed:` becomes `case .permissionDenied, .unavailable, .failed:`.

- [ ] **Step 3: Remove `capabilities` and `prepare()` from backends and fakes (mechanical)**

The first regex handles a line with a blank line on both sides. The second handles every other occurrence. Dry-run on `450b4af` left no double blank lines.

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 'for my $L (q{(?:nonisolated )?let capabilities = (?:STT|TTS)Capabilities\(\[[^\]]*\]\)}, q{func prepare\(\) async throws \{\}}) { s/(?<=\n)\n[ \t]*$L\n(?=\n)//g; s/\n[ \t]*$L(?=\n)//g; }' \
  Relay/Backends/PocketTTSBackend.swift Relay/SpeechOut/AppleTTSBackend.swift Relay/Backends/AppleSpeechBackend.swift \
  Relay/Backends/ParakeetBackend.swift Relay/Backends/KokoroTTSBackend.swift \
  RelayTests/SpeechIn/STTRouterTests.swift RelayTests/SpeechIn/DictationCoordinatorTests.swift RelayTests/App/AppModelTests.swift \
  RelayTests/App/TTSBackendCatalogTests.swift RelayTests/SpeechOut/TTSRouterTests.swift
```

- [ ] **Step 4: Hand edits the regex does not cover**

1. `AppleSpeechBackend.swift`: delete the whole `func prepare() async throws { ... }` method, from `    func prepare() async throws {` through its closing brace (22 lines), plus the blank line after it. `prepareAssets` is still used by `transcribe`.
2. `ParakeetBackend.swift`: delete these lines and the blank line after them:

```swift
    func prepare() async throws {
        try await ensureLoaded()
    }
```

3. `WhisperBackend.swift`:
   - Delete the same three-line `prepare()` method.
   - Delete the three-line `/// Advertised statically regardless of which model is currently selected: ...` doc and `    nonisolated let capabilities = STTCapabilities([.fullyOffline, .multilingual])`, plus the blank line after it.
   - Replace the `WhisperModelSelection` doc with:

```swift
/// Reads which Whisper model is currently selected, synchronously. `availability()` needs the
/// selected id without awaiting `AppSettings`, so selection is exposed through this narrow
/// closure-based seam rather than an async read of app settings.
```

4. `WhisperRuntime.swift`, the `WhisperKitContext` doc: change `/// one real activation with the network genuinely disabled before relying on `.fullyOffline` in` + `/// `WhisperBackend.capabilities` in production.` to `/// one real activation with the network genuinely disabled before relying on Whisper being fully` + `/// offline in production.`
5. `WhisperModelManager.swift`, the `selectModel` doc: change `` `WhisperBackend.prepare()`'s on-demand activation `` to `` `WhisperBackend.transcribe`'s on-demand activation ``.

- [ ] **Step 5: Tests**

1. `SpeechBackendContractsTests.swift`: keep only `testBackendErrorFallbackClassification`. Delete the four capability tests (lines 18-76) and both private fakes `ContractSTTBackend` and `ContractTTSBackend` (lines 79-103). The file ends after the class's closing brace.
2. `ParakeetBackendTests.swift`: delete `testCapabilitiesIncludeFullyOffline`, `testCapabilitiesDoNotAdvertiseMultilingual`, `testPrepareTriggersEngineLoadWithoutAllowingDownload`, `testPrepareMapsLoadFailedToInitializationFailed`, `testPreparePreservesCancellationFromLoad`.
3. `AppleSpeechBackendTests.swift`: delete `testPrepareMapsAssetPreparationFailureToInitializationFailure`.
4. `KokoroTTSBackendTests.swift` and `PocketTTSBackendTests.swift`: delete `testCapabilities`. `AppleTTSBackendTests.swift`: delete `testAppleBackendReportsSupportedCapabilities`. `WhisperBackendTests.swift`: delete `testCapabilitiesAdvertiseOfflineAndMultilingual`.
5. Delete the `.initializing` rows:

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -ni -e 'print unless /^\s*\(\.initializing, /' RelayTests/SpeechIn/STTRouterTests.swift RelayTests/App/AppModelTests.swift RelayTests/App/TTSBackendCatalogTests.swift
```

- [ ] **Step 6: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e '(STT|TTS)Capabilit' -e 'func prepare\(\) async throws' -e '\binitializing\b' -e 'WhisperBackend\.(capabilities|prepare)' -e 'SpeechToTextBackend\.prepare' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`.

- [ ] **Step 7: VERIFY**: green, `N4 = N3 - 14`.

- [ ] **Step 8: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/Domain/SpeechModels.swift Relay/Domain/BackendAvailability.swift Relay/SpeechIn/SpeechToTextBackend.swift Relay/SpeechIn/STTRouter.swift Relay/SpeechOut/TextToSpeechBackend.swift Relay/SpeechOut/AppleTTSBackend.swift Relay/App/BackendCatalog.swift Relay/Backends/AppleSpeechBackend.swift Relay/Backends/ParakeetBackend.swift Relay/Backends/KokoroTTSBackend.swift Relay/Backends/PocketTTSBackend.swift Relay/Backends/Whisper/WhisperBackend.swift Relay/Backends/Whisper/WhisperRuntime.swift Relay/Backends/Whisper/WhisperModelManager.swift RelayTests/Domain/SpeechBackendContractsTests.swift RelayTests/SpeechIn/STTRouterTests.swift RelayTests/SpeechIn/DictationCoordinatorTests.swift RelayTests/App/AppModelTests.swift RelayTests/App/TTSBackendCatalogTests.swift RelayTests/SpeechOut/TTSRouterTests.swift RelayTests/SpeechOut/AppleTTSBackendTests.swift RelayTests/Backends/ParakeetBackendTests.swift RelayTests/Backends/AppleSpeechBackendTests.swift RelayTests/Backends/KokoroTTSBackendTests.swift RelayTests/Backends/PocketTTSBackendTests.swift RelayTests/Backends/Whisper/WhisperBackendTests.swift && git commit -m "refactor(speech): drop unused backend capabilities, STT prepare() and .initializing availability"
```

---

### Task 5: System (permission seam, diagnostics formatter)

**Files:**
- Modify: `Relay/System/PermissionService.swift:23-36,65-72,86-93`
- Modify: `Relay/System/Diagnostics.swift:128`
- Test: `RelayTests/System/DiagnosticsTests.swift`, `RelayTests/App/AppModelTests.swift` (`testOpenPrivacySettingsDelegatesToInjectedOpener`)

Deleted tests: none (3 are renamed).

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift '\.(canPostEvents|requestListenForEvents|requestPostEvents)\(' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.inputMonitoring\b' Relay RelayHook | grep -v 'case .inputMonitoring: "Privacy_ListenEvent"' || echo NO_READERS
rg -Hn --type swift 'DiagnosticTimestampFormatter\.fixed' Relay RelayHook || echo NO_READERS
```

Expected: three `NO_READERS` lines. `TextInsertionService`'s own injected `canPostEvents` closure is unrelated: it is called as `canPostEvents()` without a receiver and is not matched.

- [ ] **Step 2: `PermissionService.swift`**

1. The `PrivacySettingsPane` enum becomes:

```swift
enum PrivacySettingsPane: Equatable {
    case microphone
    case accessibility

    var url: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
```

2. `NativePermissionChecking` becomes:

```swift
protocol NativePermissionChecking: AnyObject {
    func canListenForEvents() -> Bool
    func isAccessibilityTrusted() -> Bool
    func requestAccessibilityTrust()
}
```

3. In `SystemNativePermissions`, delete the `canPostEvents()`, `requestListenForEvents()` and `requestPostEvents()` lines.

- [ ] **Step 3: Move `DiagnosticTimestampFormatter.fixed` into the test target**

In `Diagnostics.swift`, delete the line `    static let fixed: DateFormatter = { ... }()`. In `RelayTests/System/DiagnosticsTests.swift`, add at the end of the file:

```swift
/// Deterministic UTC/POSIX variant of `DiagnosticTimestampFormatter.local`, for tests only.
extension DiagnosticTimestampFormatter {
    static let fixed: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
```

- [ ] **Step 4: Retarget `DiagnosticsTests.swift`**

1. Replace `FakeNativePermissions` with:

```swift
private final class FakeNativePermissions: NativePermissionChecking {
    var inputMonitoring: Bool
    var accessibilityTrusted: Bool
    private(set) var requestAccessibilityCount = 0

    init(inputMonitoring: Bool, isAccessibilityTrusted: Bool) {
        self.inputMonitoring = inputMonitoring
        accessibilityTrusted = isAccessibilityTrusted
    }

    func canListenForEvents() -> Bool { inputMonitoring }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func requestAccessibilityTrust() { requestAccessibilityCount += 1 }
}
```

2. Remove the `canPostEvents:` argument and the request-count asserts, then rename the three tests:

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 's/\n[ \t]*canPostEvents: (?:true|false),(?=\n)//g; s/\n[ \t]*XCTAssertEqual\(native\.request(?:Listen|Post)Count, 0\)(?=\n)//g; s/testAccessibilityTrustGrantsEffectiveGlobalHotkeysWhenPostingIsUnavailable/testAccessibilityTrustGrantsEffectiveGlobalHotkeysWithoutInputMonitoring/; s/testPermissionServiceRequestsAccessibilityWhenTrustIsMissingEvenIfPostingIsAllowed/testPermissionServiceRequestsAccessibilityWhenTrustIsMissing/; s/testPermissionServiceDoesNotRequestAccessibilityWhenTrustedButPostingIsUnavailable/testPermissionServiceDoesNotRequestAccessibilityWhenTrusted/' RelayTests/System/DiagnosticsTests.swift
```

3. `RelayTests/App/AppModelTests.swift`, `testOpenPrivacySettingsDelegatesToInjectedOpener`: delete `        model.openPrivacySettings(.inputMonitoring)` and change the assert to `XCTAssertEqual(opener.opened, [.microphone, .accessibility])`.

- [ ] **Step 5: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'func canPostEvents' -e 'requestListenForEvents' -e 'requestPostEvents' -e 'request(Listen|Post)Count' -e 'PrivacySettingsPane\.inputMonitoring|\(\.inputMonitoring\)|case \.inputMonitoring' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`. `inputMonitoringGranted` is a different, still-used field and is not matched.

- [ ] **Step 6: VERIFY**: green, `N5 = N4`.

- [ ] **Step 7: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/System/PermissionService.swift Relay/System/Diagnostics.swift RelayTests/System/DiagnosticsTests.swift RelayTests/App/AppModelTests.swift && git commit -m "refactor(system): trim unused permission seam members and move fixed test formatter to tests"
```

---

### Task 6: Integrations, Sessions and the RelayHook env allowlist

**Files:**
- Modify: `Relay/Integrations/Codex/CodexInstaller.swift:39-41`, `Relay/App/Settings/IntegrationsSettingsView.swift:127-128`
- Modify: `Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift`, `Relay/Integrations/Codex/CodexHookPayload.swift`, `Relay/Integrations/Domain/AgentResponseEvent.swift:7,10`, `Relay/Integrations/ClaudeCode/ClaudeCodeIntegration.swift:55,58`, `Relay/Integrations/Codex/CodexIntegration.swift:55,58`
- Modify: `Relay/Integrations/LatestAgentResponseStore.swift`
- Modify: `Relay/Sessions/Domain/TerminalContext.swift:4,11`, `Relay/Sessions/AgentSessionRegistry.swift:26,32,34`
- Modify: `RelayHook/main.swift` (`environmentAllowlist`)
- Test: `RelayTests/Integrations/{CodexIntegrationTests,ClaudeCodeIntegrationTests,IntegrationManagerTests}.swift`, `RelayTests/App/{AppModelTests,AppModelIntegrationsTests}.swift`, `RelayTests/Sessions/{AgentSessionRegistryTests,AgentSessionRegistryPruneTests,TmuxFocusResolverTests,FocusResolutionServiceTests,HerdrFocusResolverTests,AgentAutoReadCoordinatorTests,GenericTerminalFocusResolverTests}.swift`

**Codex `turn_id` decision (verified):** `CodexHookPayload.turnID` is non-optional, so decoding fails without `turn_id`, and `CodexIntegrationTests.testMissingTurnIDIsRejectedAsMalformed` pins that guard. So `CodexHookPayload` **keeps decoding `turnID`** as a shape guard. Only `AgentResponseEvent.turnID` is dropped. The payloads' `transcriptPath` and `stopHookActive` are dropped completely. Extra JSON keys are ignored by `Decodable`, so the fixtures stay as they are.

Deleted tests: `AgentSessionRegistryPruneTests.testRemoveById`, `AppModelTests.testReplayLastFallsBackToTierThreeWhenGlobalLatestGateIsTrueButStoreHasNothingToSpeak` (2 total). The second one only simulated an out-of-band `store.clear()`, which production can no longer do.

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift 'trustRequiredMessage' Relay RelayHook | grep -v 'static let trustRequiredMessage' || echo NO_READERS
rg -Hn --type swift '\.(turnID|transcriptPath|stopHookActive|termProgram)\b' Relay RelayHook | grep -v -E 'turnID: payload\.turnID|transcriptPath: payload\.transcriptPath' || echo NO_READERS
rg -Hn --type swift 'environment\["(TERM|TERM_PROGRAM|HERDR_ACTIVE_WORKSPACE_ID|HERDR_ACTIVE_TAB_ID|GHOSTTY_RESOURCES_DIR)"\]' Relay RelayHook | grep -v 'termProgram = event.environment\["TERM_PROGRAM"\]' || echo NO_READERS
rg -Hn --type swift 'environment\[' Relay/Sessions Relay/App Relay/Integrations | grep -v -E 'TerminalContext.swift|CODEX_HOME|CLAUDE_CONFIG_DIR' || echo NO_READERS
rg -Hn --type swift '\.(session|remove)\(id:' Relay RelayHook | grep -v -E 'func (session|remove)\(id:' || echo NO_READERS
rg -Hn --type swift '[Rr]egistry\??\.removeAll\(' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.clear\(\)' Relay RelayHook | grep -v -E 'diagnostics\.clear|integrationDiagnosticsLog\.clear|buffer\.clear|entries|func clear' || echo NO_READERS
```

Expected: seven `NO_READERS` lines. This confirms `TerminalContext` reads only `TMUX`, `TMUX_PANE`, `HERDR_SOCKET_PATH`, `HERDR_PANE_ID` and `HERDR_ACTIVE_PANE_ID` once `termProgram` is gone.

- [ ] **Step 2: Single source for the Codex trust copy**

`CodexInstaller.swift`: replace the constant with the copy the UI actually shows:

```swift
    /// Settings copy shown once install succeeds but Codex has not yet
    /// granted trust to the Relay hook command.
    static let trustRequiredMessage = "Run /hooks in Codex and trust the Relay hook."
```

In `IntegrationsSettingsView.swift`, `statusDetail(_:)`, replace

```swift
        case .installedTrustRequired:
            "Run /hooks in Codex and trust the Relay hook."
```

with

```swift
        case .installedTrustRequired:
            CodexInstaller.trustRequiredMessage
```

- [ ] **Step 3: Payloads and event**

1. `ClaudeCodeHookPayload.swift`: the struct becomes:

```swift
struct ClaudeCodeHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case lastAssistantMessage = "last_assistant_message"
    }
}
```

2. `CodexHookPayload.swift`: replace the doc's last sentences (``/// `AgentResponseEvent`. `turnID` is required: ...`` through `/// distinguish turns within a session.`) with:

```swift
/// `AgentResponseEvent`. `turnID` is decoded only as a shape guard: Codex always
/// includes `turn_id` on `Stop` events, so a payload without it is rejected as
/// malformed (see `CodexIntegrationError.malformedPayload`). Relay does not
/// otherwise use the value.
```

The struct becomes:

```swift
struct CodexHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let turnID: String
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case lastAssistantMessage = "last_assistant_message"
    }
}
```

3. `AgentResponseEvent.swift`: delete `    let turnID: String?` and `    let transcriptPath: String?`.
4. `ClaudeCodeIntegration.swift` and `CodexIntegration.swift`: in the `AgentResponseEvent(...)` call, delete the `turnID: ...,` line and the `transcriptPath: payload.transcriptPath,` line.

- [ ] **Step 4: Retarget the `AgentResponseEvent` constructions in tests (mechanical, dry-run verified)**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 's/(?:\n[ \t]*| )turnID: (?:nil|"[^"\n]*"),//g; s/(?:\n[ \t]*| )transcriptPath: nil,//g' \
  RelayTests/App/AppModelTests.swift RelayTests/App/AppModelIntegrationsTests.swift RelayTests/Integrations/IntegrationManagerTests.swift \
  RelayTests/Sessions/TmuxFocusResolverTests.swift RelayTests/Sessions/AgentSessionRegistryTests.swift RelayTests/Sessions/FocusResolutionServiceTests.swift \
  RelayTests/Sessions/HerdrFocusResolverTests.swift RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift RelayTests/Sessions/AgentSessionRegistryPruneTests.swift \
  RelayTests/Sessions/GenericTerminalFocusResolverTests.swift
perl -0pi -e 's/\n[ \t]*XCTAssert\w*\(event\.(?:turnID|transcriptPath)\b[^\n]*//g; s/testDecodesStopEventPreservingTurnSessionCwdTranscriptAndText/testDecodesStopEventPreservingSessionCwdAndText/; s/testDecodesStopEventPreservingSessionCwdTranscriptAndText/testDecodesStopEventPreservingSessionCwdAndText/' \
  RelayTests/Integrations/CodexIntegrationTests.swift RelayTests/Integrations/ClaudeCodeIntegrationTests.swift
```

The JSON fixtures keep `"transcript_path"`, `"turn_id"` and `"stop_hook_active"`. They now prove that ignored keys still decode.

- [ ] **Step 5: `LatestAgentResponseStore.clear()`**

1. Delete:

```swift
    /// Discards the stored event, if any, then runs the subscriber exactly as `set(_:)` does.
    func clear() async {
        latest = nil
        await subscriber?(latest)
    }

```

2. Change the `get()` doc to `/// Returns the most recently stored event, or `nil` if none has arrived yet.` (drop `(or it has been` / `cleared)`).
3. In the `subscribe(_:)` doc, change ``/// Registers `callback` to run on the `MainActor`, as part of every subsequent `set`/`clear` `` to ``/// Registers `callback` to run on the `MainActor`, as part of every subsequent `set` ``.
4. `IntegrationManagerTests.swift`, `testGateCannotDivergeFromStoreAcrossDirectMutation`: delete everything from `        await store.clear()` through `        XCTAssertNil(clearedContent)`, so the test ends after `XCTAssertEqual(stored, latest)`. Replace its doc comment with:

```swift
    /// Hardens the actual bug: the gate (`latestResponse`) and the spoken content (`store.get()`)
    /// must trace back to the SAME state, so anything that mutates `store` — not only the
    /// manager's own consume loop — has to be reflected in the gate too. Before the fix,
    /// `latestResponse` was written only from inside `recordActive()`, so a direct `store.set`
    /// left the gate stale and `waitUntil` below would time out. After the fix, `latestResponse`
    /// is a projection of `store` itself.
```

5. `AppModelTests.swift`: delete `testReplayLastFallsBackToTierThreeWhenGlobalLatestGateIsTrueButStoreHasNothingToSpeak` with its doc comment (from `    /// Hardens against a latent trap:` through the method's closing brace). `StubIntegration` stays, because another test still uses it.

- [ ] **Step 6: Sessions**

1. `TerminalContext.swift`: delete `    let termProgram: String?` and `        termProgram = event.environment["TERM_PROGRAM"]`.
2. `AgentSessionRegistryTests.swift`: delete `        XCTAssertEqual(context.termProgram, "ghostty")`.
3. `AgentSessionRegistry.swift`: delete `    func session(id: AgentSessionID) -> AgentSession? { values[id] }`, `    func removeAll() { values.removeAll() }` and `    func remove(id: AgentSessionID) { values[id] = nil }`, plus their separating blank lines.
4. `AgentSessionRegistryPruneTests.swift`: delete `testRemoveById`. In `testPruneRemovesSessionsPastTTL`, replace

```swift
        let inserted = await registry.session(id: session.id)
        XCTAssertNotNil(inserted)
```

with

```swift
        let inserted = await registry.sessions()
        XCTAssertEqual(inserted.map(\.id), [session.id])
```

- [ ] **Step 7: RelayHook allowlist**

Find it with `rg -n 'environmentAllowlist' RelayHook Relay`. Plan 1 may have moved it; edit it wherever it now lives. Replace the array and add the doc:

```swift
/// Exactly the variables `TerminalContext` (Relay/Sessions/Domain/TerminalContext.swift) reads.
/// Keep the two in sync: forwarding anything else widens what leaves the agent's environment
/// with no consumer.
private let environmentAllowlist = [
    "TMUX", "TMUX_PANE",
    "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_ACTIVE_PANE_ID",
]
```

Keep whatever access modifier plan 1 left on the declaration.

- [ ] **Step 8: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'stopHookActive' -e 'transcriptPath' -e '\.turnID\b' -e 'turnID: (nil|")' -e 'termProgram' -e 'removeAll\(\) \{ values' -e 'func session\(id:' -e 'func remove\(id:' -e 'store\.clear\(\)' -e 'GHOSTTY_RESOURCES_DIR' -e 'HERDR_ACTIVE_TAB_ID' -e 'HERDR_ACTIVE_WORKSPACE_ID' -e '"TERM"' Relay RelayHook RelayTests || echo CLEAN
```

Expected: `CLEAN`. `"TERM_PROGRAM"` may still appear as an inert test-fixture environment key. That is fine.

- [ ] **Step 9: VERIFY**: green, `N6 = N5 - 2`.

- [ ] **Step 10: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/Integrations/Codex/CodexInstaller.swift Relay/App/Settings/IntegrationsSettingsView.swift Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift Relay/Integrations/Codex/CodexHookPayload.swift Relay/Integrations/Domain/AgentResponseEvent.swift Relay/Integrations/ClaudeCode/ClaudeCodeIntegration.swift Relay/Integrations/Codex/CodexIntegration.swift Relay/Integrations/LatestAgentResponseStore.swift Relay/Sessions/Domain/TerminalContext.swift Relay/Sessions/AgentSessionRegistry.swift RelayHook RelayTests/Integrations RelayTests/Sessions RelayTests/App/AppModelTests.swift RelayTests/App/AppModelIntegrationsTests.swift && git commit -m "refactor(integrations): drop unread hook fields, store clear, registry helpers and env keys"
```

(`git add -- RelayHook RelayTests/Integrations RelayTests/Sessions` stages only the files this task edited, because the tree has no other changes. Check with `git diff --cached --stat` before committing.)

---

### Task 7: SpeechOut playback seam (Apple synth members, pause/resume, `committed`, `.scheduled`, preview default)

**Files:**
- Modify: `Relay/SpeechOut/AppleTTSBackend.swift:7-16,22`, `Relay/SpeechOut/AppleTTSAudioSource.swift:216`, `Relay/Backends/KokoroTTSBackend.swift:8`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift:7,21-22,34,56,160,184-190`
- Modify: `Relay/SpeechOut/TTSRouter.swift`, `Relay/SpeechOut/TextToSpeechBackend.swift:3-22`, `Relay/SpeechOut/SpeechCoordinator.swift:12-18,77-84,263-272,346-347`, `RelayTests/SpeechOut/SpeechCoordinatorWatchdogTests.swift:113-114` (comment only)
- Test: `RelayTests/SpeechOut/{AppleTTSAudioSourceTests,AppleTTSBackendTests,StreamingAudioPlayerTests,TTSRouterTests}.swift`, `RelayTests/SpeechOut/SpeechCoordinatorWatchdogTests.swift` (comment), and the 5 `SpeechCoordinating` fakes in `RelayTests/Integrations/IntegrationManagerTests.swift`, `RelayTests/App/{AppModelHotkeySideEffectTests,ActivityOverlayActionDispatcherTests,TTSBackendCatalogTests,AppModelIntegrationsTests}.swift`

**`.scheduled` decision (verified):** the player's `.scheduled` is discarded by `TTSRouter.forward`, and the router's own `.scheduled` reaches only `SpeechCoordinator.handle`, whose arm is `case .scheduled: break`. No consumer exists, so the whole enum case is deleted.

Deleted tests: `TTSRouterTests.testPauseAndResumeDelegateToPlayer`, `TTSRouterTests.testScheduledEmittedExactlyOnceAcrossFallbackAttempts`, `StreamingAudioPlayerTests.testPausedPlayerStillBackpressuresTheSource` (3 total). Backpressure without pause is still covered by the test just above it.

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift '\.(delegate|pauseSpeaking|continueSpeaking)\b|synthesizer\.speak\(' Relay/SpeechOut || echo NO_READERS
rg -Hn --type swift '\b(router|ttsRouter)\??\.(pause|resume)\(' Relay RelayHook || echo NO_READERS
rg -Hn --type swift '\.committed\b' Relay RelayHook | grep -v 'candidate.committed = true' || echo NO_READERS
rg -Hn --type swift 'candidate\??\.source' Relay || echo NO_READERS
rg -Hn --type swift '\.scheduled\b' Relay RelayHook | grep -v -E 'onEvent\?\(\.scheduled|eventHandler\?\(\.scheduled|case \.scheduled:|case let \.scheduled|^[^:]+:[0-9]+:\s*//' || echo NO_READERS
rg -Hn --type swift 'SpeechPreviewError' Relay RelayHook | grep -v 'enum SpeechPreviewError' | grep -v 'throw SpeechPreviewError.unsupported' || echo NO_READERS
```

Expected: six `NO_READERS` lines. If the `candidate?.source` guard prints a line (plan 1's stop-during-prepare may now read it), **keep** `CandidatePlayback.source` and remove only `committed`.

- [ ] **Step 2: `AppleSpeechSynthesizing`**

`AppleTTSBackend.swift`: the protocol becomes:

```swift
@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}
```

In both fakes (`FakeWriteSynthesizer` in `AppleTTSAudioSourceTests.swift` and `FakeAppleSynthesizer` in `AppleTTSBackendTests.swift`), delete the `delegate` property and the `speak(_:)`, `pauseSpeaking(at:)` and `continueSpeaking()` methods.

- [ ] **Step 3: The pause/resume chain**

1. `StreamingAudioPlayer.swift`: delete `    func pause()` and `    func resume()` from `StreamingAudioPlaying`, `    func pause()` from `AudioOutputNode`, and `    func pause() { playerNode.pause() }` from `AVEngineOutputNode`. Also delete these lines and the blank lines between them:

```swift
    func pause() {
        outputNode?.pause()
    }

    func resume() {
        outputNode?.play()
    }
```

`AudioOutputNode.play()` stays, because the pump uses it.
2. `TTSRouter.swift`: delete `func pause() { player.pause() }` and `func resume() { player.resume() }` (both three-line methods).
3. Fix the docs: in `AppleTTSBackend.swift`, change `The backend owns no speakers, pause/resume, or playback events.` to `The backend owns no speakers or playback events.` Apply the same wording to the `pause/resume` phrases in `KokoroTTSBackend.swift` (the type doc) and `AppleTTSAudioSource.swift` (``owns speakers, pause/resume, and metering`` becomes ``owns speakers and metering``).
4. Tests: in `TTSRouterTests.swift`, delete `testPauseAndResumeDelegateToPlayer`, `FakePlayer`'s `pauseCount`/`resumeCount` and `pause()`/`resume()`, and `FakeTTSBackend`'s `pauseCount`/`resumeCount` proxies. In `StreamingAudioPlayerTests.swift`, delete `testPausedPlayerStillBackpressuresTheSource` and `FakeOutputNode`'s `pauseCount` and `pause()`.

- [ ] **Step 4: Remove `TTSPlaybackEvent.scheduled` entirely**

1. `TextToSpeechBackend.swift`: delete `    case scheduled(sessionID: UUID)` and remove `let .scheduled(sessionID),` from the `sessionID` switch, so the first pattern becomes `case let .started(sessionID),`.
2. `StreamingAudioPlayer.swift`: delete `        onEvent?(.scheduled(sessionID: sessionID))` and its following blank line. In the type doc, change ``(`scheduled -> started -> level* -> finished|cancelled|failed`)`` to ``(`started -> level* -> finished|cancelled|failed`)``.
3. `TTSRouter.swift`:
   - Type doc: delete the sentence ``/// response in another voice. `.scheduled` is emitted exactly once per Relay speech session, not`` + `/// once per backend attempt.`, and end the previous sentence at `response in another voice.`
   - `setPlaybackEventHandler` doc: replace the last two sentences with ``/// Router-emitted `.failed` carries a `nil` backend (it is emitted before, or independently of, a`` + `/// committed backend); player-sourced events carry the committed backend.`
   - In `speak(...)`, delete these lines and the blank line after them:

```swift
        // Emitted exactly once per Relay speech session, before any backend attempt, so fallback
        // attempts never duplicate it.
        eventHandler?(.scheduled(sessionID: sessionID), nil)
```

   - Delete the `case .scheduled:` arm (its two comment lines and `return`) in `forward(_:)`.
4. `SpeechCoordinator.swift`, `handle(_:backend:)`: delete `        case .scheduled:` / `            break`.
5. Tests:

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -0pi -e 's/\n[ \t]*\.scheduled\(sessionID: sessionID\),(?=\n)//g; s/XCTAssertEqual\(recorded, \[\.scheduled\(sessionID: sessionID\)\]\)/XCTAssertTrue(recorded.isEmpty)/g; s{only \.scheduled/\.started have been observed}{only .started has been observed}g; s/XCTAssertEqual\(events\.values\.filter \{ !\$0\.isLevel \}, \[\.scheduled\(sessionID: sessionID\)\]\)/XCTAssertTrue(events.values.filter { !\$0.isLevel }.isEmpty)/g; s/testShortSourceEmitsScheduledStartedThenFinishedAfterPlayback/testShortSourceEmitsStartedThenFinishedAfterPlayback/g; s/testStartPlaybackEmitsScheduledThenStartedAndReturnsBeforeFinishedArrivesLater/testStartPlaybackEmitsStartedAndReturnsBeforeFinishedArrivesLater/g' RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
rg -n '\.scheduled\b|EmitsScheduled' RelayTests/SpeechOut/StreamingAudioPlayerTests.swift || echo NO_SCHEDULED
```

   Expected: `NO_SCHEDULED`. The second substitution covers the `XCTAssertEqual(events.values.filter { !$0.isLevel }, [.scheduled(sessionID: sessionID)])` form that plan 1 (Task 5, `testPreStartSourceCancellationThrowsCancellationErrorWithoutTerminalEvent`) adds; the first covers plan 1's multi-line `.scheduled(sessionID: sessionID),` rows. If any other `.scheduled` form remains, rewrite it by hand the same way (drop the element, or assert emptiness).

   Then, in `TTSRouterTests.swift`, delete `testScheduledEmittedExactlyOnceAcrossFallbackAttempts` and its `// MARK: One-session `.scheduled`` header.

- [ ] **Step 5: `CandidatePlayback.committed` (and `source`, only if its guard was `NO_READERS`)**

In `TTSRouter.swift`, `CandidatePlayback` becomes:

```swift
    private struct CandidatePlayback {
        let backend: any TextToSpeechBackend
        let sessionID: UUID
    }
```

(Keep `let source: any TTSAudioSource` if the Step 1 guard found a reader.) Adjust the construction to `candidate = CandidatePlayback(backend: backend, sessionID: sessionID)`, adding `source: source,` only if it was kept. In `forward(_:)`, change `guard var candidate, ...` to `guard let candidate, ...`, and change the `.started` arm to:

```swift
        case .started:
            eventHandler?(event, candidate.backend)
```

Update the struct doc's first sentence to `/// The backend for the session the player is currently driving.` Keep the rest, which explains why it is assigned before `startPlayback`.

- [ ] **Step 6: Drop the `previewVoice` default and `SpeechPreviewError`**

1. `SpeechCoordinator.swift`: delete these lines and the blank lines around them:

```swift
enum SpeechPreviewError: Error { case unsupported }

extension SpeechCoordinating {
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {
        throw SpeechPreviewError.unsupported
    }
}
```

2. Add `    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {}` after `func speak(...)` in each fake that lacks it: `FakeSpeechCoordinator` (`RelayTests/Integrations/IntegrationManagerTests.swift`), `FakeSpeechCoordinator` (`RelayTests/App/AppModelHotkeySideEffectTests.swift`), `FakeDispatchedSpeechCoordinator` (`RelayTests/App/ActivityOverlayActionDispatcherTests.swift`), `NoOpSpeechCoordinator` (`RelayTests/App/TTSBackendCatalogTests.swift`), `FakeSpeechCoordinator` (`RelayTests/App/AppModelIntegrationsTests.swift`). `AppModelTests`'s fake already implements it.

- [ ] **Step 7: Stale Apple-delegate comments in `SpeechCoordinator.swift`**

Replace the `watchdogRetiringSessionID` doc (from `/// Set to a session ID only for the duration of` through `/// case.)`) with:

```swift
    /// Set to a session ID only for the duration of `handleWatchdogExpiry(sessionID:)`'s call to
    /// `router.stop()`, and `nil` otherwise. The shared `StreamingAudioPlayer` emits its terminal
    /// `.cancelled` SYNCHRONOUSLY and reentrantly from inside `stop()`, before it returns;
    /// `handle(_:backend:)` ignores any event for this session while it's set, so that reentrant
    /// terminal can't race the watchdog's own `.failed` overlay update or double-drain the queue.
```

In the `handleWatchdogExpiry` doc, replace the second paragraph (from `/// Retires this session's own tracking BEFORE calling` through ``/// `stop()` reports synchronously or asynchronously.``) with:

```swift
    /// Retires this session's own tracking BEFORE calling `router.stop()`, rather than going
    /// through `finishInFlightSession(_:)` afterwards: the shared `StreamingAudioPlayer` emits
    /// `.cancelled` reentrantly from inside `stop()`, and `watchdogRetiringSessionID` makes
    /// `handle(_:backend:)` ignore it for that call's duration. Without both of these, that
    /// reentrant `.cancelled` would race ahead of this method's own `.failed` report — clearing
    /// the overlay's `activeSessionID` (so the subsequent `overlay.fail(...)` below silently
    /// no-ops) and dequeuing the next request itself (so the drain at the end here would double
    /// it). Retiring first and suppressing the reentrant event makes both of those impossible.
```

In `RelayTests/SpeechOut/SpeechCoordinatorWatchdogTests.swift` (doc comment at :113-115), replace

```swift
    /// Regression test: on some backends (`StreamingAudioPlayer`/`PocketTTS`), `stop()` emits its
    /// terminal event SYNCHRONOUSLY and reentrantly, from inside `stop()` itself, before it
    /// returns - unlike AppleTTS, whose delegate callback arrives later, asynchronously. If the
```

with

```swift
    /// Regression test: the shared `StreamingAudioPlayer`'s `stop()` emits its terminal event
    /// SYNCHRONOUSLY and reentrantly, from inside `stop()` itself, before it returns. If the
```

- [ ] **Step 8: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'pauseSpeaking' -e 'continueSpeaking' -e 'router\.(pause|resume)\(' -e 'player\.(pause|resume)\(\)' -e 'outputNode\?\.pause' -e 'pauseCount' -e 'resumeCount' -e 'candidate\.committed' -e 'committed: false' -e '\.scheduled\b' -e 'SpeechPreviewError' -e 'AppleTTS.s delegate' -e 'PocketTTS`\)' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`.

- [ ] **Step 9: VERIFY**: green, `N7 = N6 - 3`.

- [ ] **Step 10: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/SpeechOut Relay/Backends/KokoroTTSBackend.swift RelayTests/SpeechOut RelayTests/Integrations/IntegrationManagerTests.swift RelayTests/App/AppModelHotkeySideEffectTests.swift RelayTests/App/ActivityOverlayActionDispatcherTests.swift RelayTests/App/TTSBackendCatalogTests.swift RelayTests/App/AppModelIntegrationsTests.swift && git diff --cached --stat && git commit -m "refactor(speech-out): remove unused pause/resume, scheduled event, synth members and preview default"
```

---

### Task 8: Old whole-WAV TTS path, compatibility defaults, and stale speech comments

**Files:**
- Modify: `Relay/Backends/FluidAudioKokoroEngine.swift` (:14-18, :38-40, :54-60, :80-84, :91-120, :136-139, :228-242, :452-454)
- Modify: `Relay/Backends/FluidAudioPocketTTSEngine.swift` (:8-15, :35-37, :53-57, :68-74, :77-86, :186-204, :352-361)
- Modify: `Relay/Backends/StreamingTranscriber.swift` (:4, :34, :49, :80), `Relay/SpeechIn/MicrophoneCapture.swift`, `Relay/SpeechIn/DictationCoordinator.swift`, `Relay/App/ActivityOverlayModel.swift` (the `SPIKE` labels)
- Test: `RelayTests/Backends/{FluidAudioKokoroEngineTests,FluidAudioPocketTTSEngineTests,KokoroModelManagerTests,PocketTTSModelManagerTests,KokoroTTSBackendTests,PocketTTSBackendTests}.swift`, `RelayTests/SpeechOut/KokoroTTSAudioSourceTests.swift`

**`textTooLong` decision (verified):** it is still thrown by the live `synthesize(phonemes:voice:speed:)` path (`KokoroAneError.phonemeSequenceTooLong`) and mapped by `KokoroTTSBackend.mapEngineError`. So it **stays**. Only its stale "no built-in chunker" doc is fixed.

Deleted tests: `FluidAudioPocketTTSEngineTests.testSynthesizeBeforeLoadThrowsSynthesisFailed` (1 total; it duplicates `testSynthesizeStreamBeforeLoadThrowsSynthesisFailed`). Every other whole-WAV engine test is retargeted to the live API.

- [ ] **Step 1: Guards**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code
rg -Hn --type swift '\.synthesize\(text:' Relay RelayHook | grep -v 'manager.synthesize(text:' | grep -v 'session.synthesize(text:' | grep -v '///' || echo NO_READERS
rg -Hn --type swift 'textTooLong' Relay
```

Expected: `NO_READERS`. Then `textTooLong` lines in `KokoroTTSBackend.swift` (the mapping) and `FluidAudioKokoroEngine.swift` (the case, and the throws in both `synthesize` overloads). This confirms the live phoneme path still throws it.

- [ ] **Step 2: Kokoro engine**

1. `KokoroModelSession`: delete `    func synthesize(text: String, voice: String, speed: Float) async throws -> Data`.
2. Delete the `extension KokoroModelLoading { func removeModels() ... }` block (3 lines plus a blank line).
3. Replace the `textTooLong` doc with:

```swift
    /// A phoneme segment exceeded KokoroAne's ~510-phoneme per-call limit. `KokoroTTSBackend`
    /// splits long-form text with `KokoroPhonemeChunker` (hard maximum
    /// `KokoroAneConstants.maxPhonemeLength`) before synthesis, so this indicates an unexpected
    /// segment rather than long input; it maps to `SpeechBackendError.inferenceFailed`, which the
    /// router treats as fallback-worthy.
```

4. `KokoroEngine`: delete the `/// Synthesizes `text` to a complete WAV ...` doc (4 lines) and `    func synthesize(text: String, voice: String, speed: Float) async throws -> Data`.
5. Replace the `extension KokoroEngine { ... }` and `extension KokoroModelSession { ... }` blocks with only:

```swift
extension KokoroEngine {
    /// Convenience overload for callers that don't need download progress.
    func load(allowDownload: Bool) async throws {
        try await load(allowDownload: allowDownload, progress: { _ in })
    }
}
```

6. In the `FluidAudioKokoroEngine` type doc, replace the last paragraph with:

```swift
/// Relay performs long-form chunking above this engine: the full text is resolved through
/// `phonemes(for:)`, safe phoneme segments are synthesized through
/// `synthesize(phonemes:voice:speed:)`, and a bounded audio source feeds the shared player.
```

7. Replace the `KokoroAneManagerSession` doc (the four lines starting `/// Thin wrapper around FluidAudio's `KokoroAneManager`...`, which mention the old `KokoroTtsManager`) with:

```swift
/// Thin wrapper around FluidAudio's `KokoroAneManager` so it can conform to `KokoroModelSession`.
/// `KokoroAneManager` is a `public actor` - already `Sendable` and self-serializing - so this
/// needs no acquire/release wrapping to keep concurrent calls from interleaving inside it.
```

8. Delete the engine's `func synthesize(text: String, voice: String, speed: Float) async throws -> Data { ... }` (15 lines) and `KokoroAneManagerSession`'s whole-WAV `synthesize(text:voice:speed:)` (3 lines), each with its trailing blank line.

- [ ] **Step 3: PocketTTS engine**

1. `PocketTTSModelSession` becomes:

```swift
protocol PocketTTSModelSession: Sendable {
    /// Streams synthesized audio as raw Float32 frames, so playback can start before synthesis
    /// finishes. Each frame is 1920 samples (80ms) at `PocketTtsConstants.audioSampleRate`
    /// (24kHz), matching FluidAudio's `PocketTtsSynthesizer.AudioFrame`.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
}
```

2. Delete the `extension PocketTTSModelLoading { func removeModels() ... }` block.
3. `PocketTTSEngine`: replace the last sentences of the protocol doc (from `/// touches FluidAudio types directly. Unlike `KokoroEngine`, ...` through `... no `voiceSpeed` equivalent.`) with:

```swift
/// touches FluidAudio types directly. Unlike `KokoroEngine`, PocketTTS has no speed parameter,
/// matching FluidAudio's `PocketTtsManager.synthesizeStreaming(text:voice:)`.
```

   Delete `/// Synthesizes `text` to a complete WAV ...` and `func synthesize(text: String, voice: String) async throws -> Data`. Replace the `synthesizeStream` doc with:

```swift
    /// Streams synthesized audio as raw Float32 frames (24 kHz mono), so a player can begin
    /// scheduling audio before synthesis finishes. The engine must already be loaded - callers
    /// are expected to call `load(allowDownload:)` themselves first; this never triggers a load or
    /// download.
```

4. In `extension PocketTTSEngine`, delete the `removeModels()` default and keep only `load(allowDownload:)`.
5. In `FluidAudioPocketTTSEngine`, delete `func synthesize(text: String, voice: String) async throws -> Data { ... }` and replace the `synthesizeStream` doc with:

```swift
    /// Does not remap errors that occur while draining the returned stream: a stream, once
    /// returned, is consumed outside of any `do`/`catch` this method could wrap around it, so a
    /// source failure propagates to the caller as-is. The only error this method itself throws is
    /// the "not loaded" guard (`PocketTTSEngineError.synthesisFailed`), before any session call.
```

6. Replace the `PocketTtsManagerSession` doc with `/// Wraps FluidAudio's `PocketTtsManager`, an `actor`, so concurrent calls into it are serialized` + `/// by Swift itself.` Delete its whole-WAV `synthesize(text:voice:)`.

- [ ] **Step 4: Fakes must now implement every requirement (no defaults)**

1. Delete the whole-WAV `synthesize(text:...)` method (and any doc comment on it) from: `FakeManagerKokoroEngine` (`KokoroModelManagerTests.swift`), `FakeKokoroEngine` (`KokoroTTSBackendTests.swift`, including its `/// Legacy whole-utterance path ...` doc), `FakeLongFormKokoroEngine` (`KokoroTTSAudioSourceTests.swift`), `FakeManagerPocketEngine` (`PocketTTSModelManagerTests.swift`), `FakePocketTTSEngine` (`PocketTTSBackendTests.swift`, including its `/// Unused by `PocketTTSBackend` ...` doc), `FakePocketTTSSession` (`FluidAudioPocketTTSEngineTests.swift`).
2. Add `    func removeModels() async throws {}` to `FakeKokoroEngine` (`KokoroTTSBackendTests.swift`), `FakeLongFormKokoroEngine` (`KokoroTTSAudioSourceTests.swift`) and `FakePocketTTSEngine` (`PocketTTSBackendTests.swift`).
3. Add to `FakeManagerKokoroEngine`:

```swift
    func phonemes(for text: String) async throws -> String { text }
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        KokoroPCM(samples: [], sampleRate: 24_000)
    }
```

- [ ] **Step 5: Retarget `FluidAudioKokoroEngineTests.swift` to the phoneme API**

1. Replace `FakeKokoroSession` with:

```swift
private actor FakeKokoroSession: KokoroModelSession {
    let text: String
    private(set) var received: (String, String, Float)?
    private var synthesizeError: Error?

    init(text: String) {
        self.text = text
    }

    func setSynthesizeError(_ error: Error?) {
        synthesizeError = error
    }

    func phonemes(for text: String) async throws -> String { text }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        received = (phonemes, voice, speed)
        if let synthesizeError {
            throw synthesizeError
        }
        return KokoroPCM(samples: Array(repeating: 0, count: phonemes.count), sampleRate: 24_000)
    }
}
```

2. Retarget the call sites:
   - `testEngineRemovalReleasesSessionAndInvalidatesPresenceCache`: `_ = try await engine.synthesize(phonemes: "hello", voice: "af_heart", speed: 1)`.
   - `testLoadWithPresentModelsLoadsLocallyAndSynthesizeUsesTheLoadedSession`: `let pcm = try await engine.synthesize(phonemes: "hello", voice: "af_heart", speed: 1.0)` and `XCTAssertEqual(pcm.samples.count, 5)` (replacing the `data` lines).
   - Rename `testSynthesizeForwardsTextVoiceAndSpeedToTheLoadedSession` to `testSynthesizeForwardsPhonemesVoiceAndSpeedToTheLoadedSession`. Its call becomes `_ = try await engine.synthesize(phonemes: "hello world", voice: "am_adam", speed: 1.5)`. The asserts are unchanged.
   - `testSynthesizeBeforeLoadThrowsSynthesisFailed`: `_ = try await engine.synthesize(phonemes: "hi", voice: "af_heart", speed: 1.0)`.
   - `testSynthesizeMapsPhonemeSequenceTooLongToTextTooLong`: `_ = try await engine.synthesize(phonemes: String(repeating: "a", count: 600), voice: "af_heart", speed: 1.0)`.
   - `testFailedLocalLoadDoesNotCacheAFalsePresentSoARetryReconsultsTheLoader`: `let pcm = try await engine.synthesize(phonemes: "hi", voice: "af_heart", speed: 1.0)` and `XCTAssertEqual(pcm.samples.count, 2)`.

- [ ] **Step 6: Retarget `FluidAudioPocketTTSEngineTests.swift` to the stream API**

1. Delete `testSynthesizeBeforeLoadThrowsSynthesisFailed`, which duplicates the stream variant.
2. `testEngineRemovalReleasesSessionAndInvalidatesPresenceCache`: `_ = try await engine.synthesizeStream(text: "hello", voice: "alba")`.
3. `testLoadWithPresentModelsLoadsLocallyAndSynthesizeUsesTheLoadedSession`: replace the `let data = ...` / `XCTAssertEqual(data, ...)` lines with:

```swift
        let stream = try await engine.synthesizeStream(text: "hello", voice: "alba")
        var frames: [[Float]] = []
        for try await frame in stream { frames.append(frame) }
        let expected = await loader.lastSessionStreamFrames()
        XCTAssertEqual(frames, expected)
```

4. `testSynthesizeForwardsTextAndVoiceToTheLoadedSession`: `_ = try await engine.synthesizeStream(text: "hello world", voice: "alba")`. `FakePocketTTSSession.synthesizeStream` records `received`.
5. `testFailedLocalLoadDoesNotCacheAFalsePresentSoARetryReconsultsTheLoader`: replace `let data = ...` / `XCTAssertEqual(data, Data("hi".utf8))` with `_ = try await engine.synthesizeStream(text: "hi", voice: "alba")`.
6. `testSynthesizeStreamPropagatesASourceError`: replace BOTH comment lines (`// The engine forwards the source's stream error as-is rather than remapping it, so` and `// the router-facing `synthesize(text:voice:)` remains the only error-mapping seam.`) with the single line `// The engine forwards the source's stream error as-is rather than remapping it.`

- [ ] **Step 7: Stale speech-in comments**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && perl -pi -e 's{(//+) SPIKE \(`?([^)`]*)`?\): }{$1 $2: }; s{(//+) SPIKE: (\S)}{$1 \u$2}' Relay/SpeechIn/MicrophoneCapture.swift Relay/SpeechIn/DictationCoordinator.swift Relay/App/ActivityOverlayModel.swift Relay/Backends/StreamingTranscriber.swift
```

Dry-run result: e.g. `/// SPIKE: creates a fresh ...` becomes `/// Creates a fresh ...`, and `// SPIKE (MicrophoneSampleStreaming conformance): see ...` becomes `// MicrophoneSampleStreaming conformance: see ...`.

Then, in `StreamingTranscriber.swift`:
- `// How often the tick loop re-transcribes. Injectable (default about 1s) so tests can drive a` becomes `// How often the tick loop re-transcribes. Injectable (default 450ms) so tests can drive a`.
- `// Starts a fresh interim session: clears any leftover state and begins the about-1s tick` becomes `// Starts a fresh interim session: clears any leftover state and begins the 450ms tick`.
- In the header, `// degrades gracefully to "slightly stale" rather than "wrong in a new way" each second. The` becomes `// degrades gracefully to "slightly stale" rather than "wrong in a new way" each tick. The`.

- [ ] **Step 8: Confirm nothing is left**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'synthesize\(text:' -e 'SPIKE' -e 'about 1s' -e 'about-1s' -e 'no built-in chunker' -e 'KokoroTtsManager' -e 'old fakes' -e 'Compatibility defaults' -e 'stays temporarily' Relay RelayTests || echo CLEAN
```

Expected: `CLEAN`.

- [ ] **Step 9: VERIFY**: green, `N8 = N7 - 1`.

- [ ] **Step 10: Commit**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git add -- Relay/Backends/FluidAudioKokoroEngine.swift Relay/Backends/FluidAudioPocketTTSEngine.swift Relay/Backends/StreamingTranscriber.swift Relay/SpeechIn/MicrophoneCapture.swift Relay/SpeechIn/DictationCoordinator.swift Relay/App/ActivityOverlayModel.swift RelayTests/Backends/FluidAudioKokoroEngineTests.swift RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift RelayTests/Backends/KokoroModelManagerTests.swift RelayTests/Backends/PocketTTSModelManagerTests.swift RelayTests/Backends/KokoroTTSBackendTests.swift RelayTests/Backends/PocketTTSBackendTests.swift RelayTests/SpeechOut/KokoroTTSAudioSourceTests.swift && git commit -m "refactor(tts): remove whole-WAV engine path and compat defaults, refresh stale speech comments"
```

---

### Task 9: Final verification and sweep

**Files:** none modified.

- [ ] **Step 1: Full suite from clean**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && xcodebuild clean -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO > /dev/null 2>&1; echo cleaned
```

Then run **VERIFY**. Expected: `** TEST SUCCEEDED **`, with `N = N0 - 30` (1 + 5 + 4 + 14 + 0 + 2 + 3 + 1). If the Swift Testing template counted separately in Task 1, use `N0 - 29` for the XCTest line. Also run `grep -c 'warning:' /tmp/relay-cleanup-2.log` and compare it with a baseline run on `main`. It must not increase. In particular there must be no "never used" warnings in edited files.

- [ ] **Step 2: Final dead-symbol sweep**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && rg -Hn --type swift -e 'recordDiagnostic' -e 'SpeechVoiceCataloging' -e 'canTest' -e 'SpeechBackendModelDisplayMode' -e '\bdetailLabel\b' -e '\bshowsRemove\b' -e 'manualReplay' -e 'futureIntegration' -e '\.testVoice\b' -e 'func testVoice\(' -e '(STT|TTS)Capabilit' -e 'func prepare\(\) async throws' -e '\binitializing\b' -e 'isLoaded:' -e '\.isLoaded\b' -e 'approximateDownloadBytes' -e 'upstreamCheckpoint' -e 'approximateDiskBytes' -e 'downloadModels\(' -e 'func canPostEvents' -e 'requestListenForEvents' -e 'requestPostEvents' -e 'PrivacySettingsPane\.inputMonitoring|\(\.inputMonitoring\)|case \.inputMonitoring' -e 'DiagnosticTimestampFormatter\.fixed' -e 'stopHookActive' -e 'transcriptPath' -e '\.turnID\b' -e 'turnID: (nil|")' -e 'termProgram' -e 'removeAll\(\) \{ values' -e 'func session\(id:' -e 'func remove\(id:' -e 'store\.clear\(\)' -e 'pauseSpeaking' -e 'continueSpeaking' -e 'router\.(pause|resume)\(' -e 'player\.(pause|resume)\(\)' -e 'outputNode\?\.pause' -e 'candidate\.committed' -e 'committed: false' -e '\.scheduled\b' -e 'SpeechPreviewError' -e 'synthesize\(text:' -e 'SPIKE' -e 'GHOSTTY_RESOURCES_DIR' -e 'HERDR_ACTIVE_TAB_ID' -e 'HERDR_ACTIVE_WORKSPACE_ID' Relay RelayHook RelayTests | grep -v 'DiagnosticTimestampFormatter\.fixed' || echo SWEEP_CLEAN
rg -n 'DiagnosticTimestampFormatter\.fixed|static let fixed' Relay RelayTests
test -d RelayUITests || echo NO_UI_TESTS; test -d /Users/darius/Personal/relay/Relay/Relay.xcodeproj || echo NO_STRAY_PROJECT
```

Expected: `SWEEP_CLEAN`, then `.fixed` only in `RelayTests/System/DiagnosticsTests.swift` (its definition and one use), then `NO_UI_TESTS` and `NO_STRAY_PROJECT`.

- [ ] **Step 3: Branch shape**

```bash
cd /Users/darius/Personal/relay/.worktrees/cleanup-2-dead-code && git log --oneline main..HEAD && git log main..HEAD --format='%B' | grep -niE 'co-authored-by|claude-session|generated with' || echo NO_ATTRIBUTION_LINES && git status --short
```

Expected: 8 commits (Tasks 1-8), `NO_ATTRIBUTION_LINES`, and a clean `git status`.

- [ ] **Step 4: Hand off**

Use superpowers:finishing-a-development-branch (it also covers removing the worktree with `git worktree remove .worktrees/cleanup-2-dead-code` after merge). Do not push or open a PR unless the user asks. If a PR is requested, its body ends at its last real bullet, with no generated-by or co-author lines.
