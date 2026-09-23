# Relay Cleanup 5 — AppModel Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the 1021-line `AppModel` into a thin (<250 line) facade over focused, individually tested sub-models, with one designated initializer, one settings owner with an actor-safe snapshot, one backend-list model, a typed backend id, and a handful of targeted fixes (hotkey matcher reset on activation, clipboard reentrancy, observer/deinit pattern, stale status text).

**Architecture:** `RelayRuntime` stays the composition root and becomes the *only* thing `AppModel(runtime:)` accepts. Every sub-model (`SettingsController`, `IntegrationSetupModel`, `BackendListModel` ×2 inside `SpeechBackendsModel`, `SpeechActions` + `ReplayLastResolver`, `HotkeyController`, `PermissionsModel`) is built from the runtime and shares one `StatusSink` for the menu-bar status line. Tests build runtimes with a test-target `RelayRuntime.testing(...)` factory and never call `makeProduction()`.

**Facade decision (least SwiftUI churn):** `AppModel` remains a thin facade that *exposes* sub-models. Every view keeps `@Bindable var model: AppModel` (so `RelayApp`, `SettingsView` and all tab constructors keep their signatures) and reaches through: `model.integrationSetup.install(.codex)`, `model.settingsController.setDictationMode(.toggle)`, `model.speechBackends.dictation.rows`. Only call sites change. `model.settings` (read-only `AppSettings`) and `model.statusText` stay on the facade because they are read everywhere.

**Tech Stack:** Swift 6 language mode (Xcode 26 toolchain), SwiftUI + Observation, AppKit, `Synchronization.Mutex` (macOS 15+; target is macOS 26), XCTest, XcodeGen.

**Style reference:** `docs/superpowers/plans/2026-09-16-relay-reliability-wave-3-simplification-implementation-plan.md` (Wave 3 introduced `RelayRuntime` and `BackendCatalog`; this plan finishes that job).

---

## Global Constraints

- **Never add `group:` entries to `project.yml`.** xcodegen 2.46 hangs on them. (The two existing `group: RelayHook` lines under the `Relay` target predate this plan; leave them alone.) New files are picked up by the directory globs; just run `xcodegen generate`.
- **Every `xcodebuild` invocation uses `-derivedDataPath /tmp/relay-dd-cleanup5`** (all commands below already include it), so this worktree never shares DerivedData with `main` or another worktree.
- **Worktree:** `.worktrees/cleanup-5-appmodel-split`, branched off `main` only **after plan 4 (`cleanup/4-speech-engines`) has merged** (plans 1–3 are already on `main`).

## Ground rules

- Branch `cleanup/5-appmodel-split`, cut from `main` **after plans 1–4 are merged**. Execute in a git worktree:
  ```bash
  cd /Users/darius/Personal/relay
  git switch main && git pull --ff-only
  git worktree add .worktrees/cleanup-5-appmodel-split -b cleanup/5-appmodel-split main
  cd .worktrees/cleanup-5-appmodel-split
  ```
  All later commands run from the worktree root. Project-file changes this plan makes are committed normally: after `xcodegen generate`, stage `Relay.xcodeproj/project.pbxproj` together with the task's files (each task's commit block lists it where files were added/removed). No task edits `project.yml` (sources are globbed by directory).
- Stage explicit paths only. Never `git add -A` / `git add .`.
- Commit messages: conventional, plain. **No `Co-Authored-By`, no `Claude-Session`, no "Generated with Claude Code" line.** The message ends at its last real line.
- Behavior-preserving except where a task says **Fix**.
- **Re-read every file you are about to edit before each task.** Line numbers below are from `main@6d14400` (plans 1–3 merged) plus the plan 4 branch, and are approximate. Plan 4 does not edit `Relay/App/RelayRuntime.swift` or `Relay/App/AppModel.swift`, so line numbers in those two files are exact as of `6d14400`.
- After adding/removing/renaming any file: `xcodegen generate`.
- Single-test command:
  ```bash
  xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -only-testing:RelayTests/<Class>/<method> 2>&1 | tail -30
  ```
  Class-level: `-only-testing:RelayTests/<Class>`. Full suite: drop `-only-testing`. Success line: `** TEST SUCCEEDED **`.
- Zero new warnings. Privacy rules unchanged: no spoken text, transcripts, paths, or raw error strings in logs/diagnostics.

## End state of plans 1–4 this plan builds on

Plans 1–4 are merged before Task 0 (`docs/superpowers/plans/2026-09-23-relay-cleanup-{1-quick-fixes,2-dead-code,3-integrations-sessions,4-speech-engines}.md`). Code in this plan is written against their end state. Task 0 Step 3 greps confirm it.

| Plan | What exists after it (and what this plan does with it) |
|---|---|
| 1 | **Task 1:** `AppSettings.init(from:)` decodes every field through a local `field(_:default:)` helper (`try?` per field) plus `decodeHotkeys(from:)` (per entry, falls back to the default map when no saved entry is usable). The `schemaVersion` switch is **gone**; Task 6 adds the first real version check. Adds `AppSettingsDecodeTests.testWrongTypedOptionalFieldsFallBackWithoutResettingOthers` (touches the three voice keys; Task 6 converts it). **Task 8:** `AppModel.speechActionTask`; `startSpeechAction` cancels and replaces it; `.stopSpeech` cancels it; `deinit` cancels it; `readSelection`/`replayLast` check `Task.isCancelled` before speaking; every speak path catches `CancellationError` without recording `.ttsFailed`. Adds 4 hotkey tests to `AppModelTests` (`testTwoQuickReadSelectionPressesSpeakOnlyOnce`, `testTwoQuickReplayPressesReplayOnlyOnce`, `testStopSpeechCancelsAPendingReplay`, `testCancelledReadSelectionIsNotReportedAsFailure`). Tasks 7–8 move all of this into `SpeechActions`/`HotkeyController`. **Task 9:** `startIntegrations()` ends with `refreshInstalledHelperIfNeeded()`; `hooksInstalled(_:)`; `installBundledHelperIfPresent` appends `helper`/`refreshed`/`refresh-failed` entries to `integrationDiagnosticsLog`; 3 tests in `AppModelIntegrationsTests`. **Task 11:** `AppModel.hookSocketPath` (stored, init param), `socketStatusMessage`, `anotherInstanceOwnsSocketMessage`, `socketStartFailedMessage`, `socketStartFailureMessage(for:)`; `startIntegrations()` catches start errors; `AppModelIntegrationsTests.makeModel` takes `hookSocketPath: String? = nil`; `IntegrationsSettingsView` reads `model.hookSocketPath` / `model.socketStatusMessage`. **Task 13:** `speakLatestAgentResponse()` has `guard try await integrationManager.speakLatest() else { statusText = "No agent response to speak yet."; return }`; adds `testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission`. |
| 2 | Deleted: `AppModel.recordDiagnostic`, `AppModel.testVoice`, `import AVFoundation` in `AppModel`, `SpeechVoiceCataloging`, `SpeechBackendModelDisplayMode`, `SpeechModelRowPresentation.detailLabel/showsRemove`, `BackendAvailability.initializing`, `STTCapabilities`/`TTSCapabilities` and every backend `capabilities` property, `SpeechToTextBackend.prepare()`, `SpeechModelStatus.isLoaded`, `SpeechModelDescriptor.approximateDownloadBytes`, `PrivacySettingsPane.inputMonitoring`, `NativePermissionChecking.canPostEvents/requestListenForEvents/requestPostEvents`, `AgentResponseEvent.turnID`/`.transcriptPath` (init is `AgentResponseEvent(id:provider:providerSessionID:text:cwd:parentPID:environment:capturedAt:)`), `LatestAgentResponseStore.clear`, `AgentSessionRegistry.removeAll`. Test doubles in this plan use none of these. |
| 3 | `Shared/BuildFlavor.swift`, `Shared/RelayPaths.swift` (`RelayPaths.socketPath()`, `sharedModelsDirectory()`, `stableHelperURL()`); `AppModel.integrationSocketPath` returns `RelayPaths.socketPath()` and `RelayPathsTests.testAppAndHelperDefaultsAgreeWithRelayPaths` reads it (Task 2 retargets it). `StopHookIntegration.claudeCode`/`.codex` replace `ClaudeCodeIntegration()`/`CodexIntegration()`. `StopHookConfigFile` backs both installers (installer inits unchanged: `init(baseDirectory:helperPath:)`); `IntegrationInstallerError.hooksDisabledInConfig` replaces `CodexInstallerError`. `FocusResolutionService(registry:frontmostApps:processSnapshots:resolvers:)` (actor); `SessionFocusResolving.resolveFocus(among:processSnapshot:) -> FocusResolution` (`.focused`, `.decisions`); `FocusContext.processSnapshot`; `pruneDeadSessions(in:snapshot:)`; `ProcessInspector.snapshot()` is `async throws`; `ProcessRunning.run` is `async throws` (sync fakes still conform). Deleted: `ProcessTreeReading`, `AgentProcessContextCapturing`/`AgentProcessContextCapture`, `focusedSession(among:)`. `AppModel.replayLast()` takes one snapshot, prunes with it, and calls `resolveFocus`. `RelayApp.body` uses `BuildFlavorPresentation.current`; `MenuBarContentView` has `var presentation: BuildFlavorPresentation = .current` (this plan's edits to those files leave that untouched). `AgentAutoReadCoordinator(registry:focus:preprocess:speech:autoReadEnabled:diagnostics:processInspector:)` (no `processContext:`; `AgentProcessContext.resolve(for:in:)` is a static on the value type), `HerdrHostOwnershipChecker()` and `TmuxFocusResolver(runner:)` take no process inspector, and `FocusResolutionService` gets `processSnapshots: processInspector`. `HookEnvelope` has an optional `processAncestry`. `AppModel.integrationSocketPath` is `static var … { RelayPaths.socketPath() }` and the public init's `hookSocketPath:` defaults to it. |
| 4 | Plan 4 does **not** touch `Relay/App/RelayRuntime.swift` or `AppModel.swift`; the backend construction lines in `makeProduction()` (`RelayRuntime.swift` 202–208, 232–236, 238–268, 270–274, 364–372 on `main@6d14400`) stay exactly as they are. What changes under them: `STTRouter.selectBackend() -> STTSelection?` and `transcribe(audio:options:selection:)`; `DictationCoordinator` keeps the `STTSelection` chosen at listen time (its `init(microphone:sttRouter:processor:textInserter:stopSpeech:status:activity:diagnostics:liveTranscriptionEnabled:)`, `private var status` and `setStatusHandler(_:)` are unchanged — Task 1 removes the last two). The three FluidAudio engines load through `ModelSessionLoader` and keep `init(modelLoader: … = nil, validatedModelsPresent: Bool = false)`, so `FluidAudioKokoroEngine()` / `FluidAudioPocketTTSEngine()` / `FluidAudioParakeetEngine()` still work. Plan 4 Task 20 removes the `= FluidAudioXEngine()` defaults from `KokoroTTSBackend`/`KokoroModelManager`/`PocketTTSBackend`/`PocketTTSModelManager`/`ParakeetBackend`/`ParakeetModelManager.init(engine:)`, so every construction passes `engine:` explicitly, which `makeProduction()` and `SpeechBackendGraph.make` (Task 1) already do. Kokoro and Pocket stream through `PipedTTSAudioSource`. `WhisperRuntime(engine:modelFolder:)` is unchanged; it gains `unload(ifInvolving:)`. `SpeechBackendGraph.make` (Task 1) is a **cut-and-paste** of those `makeProduction()` lines. |

---

## File structure (end state)

Created (app):
- `Relay/App/StatusSink.swift` — the one owner of the transient menu-bar status line.
- `Relay/App/SpeechBackendGraph.swift` — side-effect-free construction of STT/TTS registries + model managers.
- `Relay/App/IntegrationSetupModel.swift` — socket lifecycle, install/uninstall/check, session summaries.
- `Relay/App/SettingsController.swift` — `SettingsSnapshot` (`Mutex<AppSettings>`) + `SettingsController` (sole writer, typed setters, hotkey conflicts, debounced rate persistence, Whisper selection seam).
- `Relay/Domain/BackendID.swift` — typed backend ids + canonical display names.
- `Relay/App/BackendListModel.swift` — `BackendStatus`, `BackendListEntry`, `BackendListModel` (one class, two instances).
- `Relay/Sessions/ReplayLastResolver.swift` — pure tier resolution for Replay Last.
- `Relay/App/SpeechActions.swift` — read selection, replay, stop, preview, speak latest.
- `Relay/App/HotkeyController.swift` — hotkey dispatch, dictation queue, tap status.
- `Relay/System/NotificationObservation.swift` — self-removing NotificationCenter token.
- `Relay/App/PermissionsModel.swift` — permission snapshot, mic, privacy panes, activation observer, login item.
- `Relay/App/SpeechBackendsModel.swift` — owns `SpeechModelController`, both `BackendListModel`s, `SpeechVoiceCatalog`; the single refresh owner.
- `Relay/App/ActivityOverlayHosting.swift` — overlay protocols + `ActivityOverlayPlacement` (moved).
- `Relay/App/ActivityOverlayActions.swift` — overlay button routing (a function, replaces the dispatcher class).

Deleted (app): `Relay/App/BackendCatalog.swift`, `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/TTSBackendCatalog.swift`, `Relay/App/ActivityOverlayActionDispatcher.swift` (replaced by `Relay/App/ActivityOverlayActions.swift` — see Task 12.2).

Created (tests): `RelayTests/Support/RelayRuntime+Testing.swift`, `RelayTests/App/SpeechBackendGraphTests.swift`, `RelayTests/App/SettingsControllerTests.swift`, `RelayTests/Domain/BackendIDTests.swift`, `RelayTests/App/BackendListModelTests.swift`, `RelayTests/Sessions/ReplayLastResolverTests.swift`, `RelayTests/App/SpeechActionsTests.swift`, `RelayTests/App/HotkeyControllerTests.swift`, `RelayTests/App/PermissionsModelTests.swift`, `RelayTests/System/NotificationObservationTests.swift`, `RelayTests/App/SpeechBackendsModelTests.swift`.

Renamed (tests): `AppModelIntegrationsTests.swift` → `IntegrationSetupModelTests.swift`; `ActivityOverlayActionDispatcherTests.swift` → `ActivityOverlayActionsTests.swift`.

Deleted (tests): `TTSMigrationProductionWiringTests.swift`, `TTSBackendCatalogTests.swift`.

## Task order

The scope list's suggested order is kept except that **SettingsController moves to Task 3** (before BackendID/BackendListModel): `BackendListModel` needs order get/set closures, and those can only be built without capturing a half-initialized `AppModel` once settings live in their own object on the runtime.

| # | Task | Scope item |
|---|---|---|
| 0 | Worktree + baseline | — |
| 1 | Single designated init, `StatusSink`, runtime retention, no `makeProduction()` in tests | 1 |
| 2 | `IntegrationSetupModel` | 2 |
| 3 | `SettingsController` + `Mutex` snapshot + rate debounce + Whisper seam | 5 |
| 4 | `BackendID` | 4 |
| 5 | `BackendListModel` | 3 |
| 6 | Voice selection map + schema v2 migration | 6 |
| 7 | `SpeechActions` + `ReplayLastResolver` | 7 |
| 8 | `HotkeyController` + `ensureTap`/`update(definitions:)` fix | 8 |
| 9 | `PermissionsModel` + `NotificationObservation` | 9 |
| 10 | `SpeechBackendsModel` + final facade | 10 |
| 11 | Clipboard reentrancy + key commands + AX dedupe + selection error | 11 |
| 12 | Small cleanups | 12 |
| 13 | Final verification | — |

---

## Task 0: Worktree and baseline

- [ ] **Step 1: Create the worktree**
```bash
cd /Users/darius/Personal/relay
git switch main && git pull --ff-only
git worktree add .worktrees/cleanup-5-appmodel-split -b cleanup/5-appmodel-split main
cd .worktrees/cleanup-5-appmodel-split
```
- [ ] **Step 2: Confirm plans 1–4 are in history**

Run: `git log --oneline -30 main`
Expected: commits for plans 1–4 are present. If any is missing, stop and report.

- [ ] **Step 3: Confirm the end state of plans 1–4** (table above):
```bash
grep -n "speechActionTask\|hookSocketPath\|socketStatusMessage\|refreshInstalledHelperIfNeeded\|resolveFocus(among" Relay/App/AppModel.swift
grep -rn "static func socketPath\|static func sharedModelsDirectory" Shared/RelayPaths.swift
grep -rn "func field<Value" Relay/Domain/AppSettings.swift
grep -rn "recordDiagnostic\|func testVoice\|SpeechVoiceCataloging\|case initializing\|case inputMonitoring\|transcriptPath" Relay
grep -n "func clear" Relay/Integrations/LatestAgentResponseStore.swift
# plan 4
grep -n "func selectBackend() async -> STTSelection?" Relay/SpeechIn/STTRouter.swift
ls Relay/Backends/ModelSessionLoader.swift Relay/SpeechOut/PipedTTSAudioSource.swift
grep -n "func unload(ifInvolving" Relay/Backends/Whisper/WhisperRuntime.swift
grep -rn "engine: any [A-Za-z]*Engine = " Relay/Backends
```
Expected: the first two commands print matches for every name; the third prints one line; the fourth and fifth print nothing; the three plan-4 checks after the comment each print a match; the last grep prints nothing (plan 4 Task 20 removed the default engines). If any check fails, stop and report — a plan is missing.

- [ ] **Step 4: Baseline**
```bash
xcodegen generate
xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`. If not green, stop — do not start refactoring on a red suite.

- [ ] **Step 5: Record the starting size:** `wc -l Relay/App/AppModel.swift` (≈1000).

---

## Task 1: Single designated initializer, `StatusSink`, runtime retention, no `makeProduction()` in tests

**Findings:**
- Two near-identical ~85-line inits (`AppModel.swift` 195–288 public, 290–373 private).
- The public init's default `focusResolution` (220–224) builds its **own** `AgentSessionRegistry()`/`FrontmostAppMonitor()`, separate from the defaulted `sessionRegistry` — replay focus resolution and the registry disagree by default.
- The private (production) init still carries dangerous defaults (`loginItemService`, `helperInstaller`, `bundledHelperURL`, `integrationDiagnosticsLog`); the public one defaults an `IntegrationManager` (252–257) duplicating `RelayRuntime.swift` 349–355.
- `RelayRuntime` claims to own lifetimes, but `RelayAppDelegate` (`RelayApp.swift:35`, `let model = AppModel(runtime: .makeProduction())`) discards it.
- `DictationCoordinator` is re-pointed after `AppModel` exists (`setStatusHandler`, `AppModel.swift` 185).
- Tests call `makeProduction()` (`TTSMigrationProductionWiringTests.swift:7`, `AppModelTests.swift` 498, `ProjectSmokeTests`, `SettingsViewsSmokeTests`) → `UserDefaults.standard`, real CGEvent tap, real backends.

**Fix:** `AppModel` gets exactly one initializer, `init(runtime: RelayRuntime)`, and **retains** the runtime (`let runtime`). `RelayRuntime` already *is* the RelayRuntime-shaped dependency container (it has an explicit memberwise init), so no second parallel struct is introduced. A test-target `RelayRuntime.testing(...)` fills consistent fakes (one registry shared by focus resolution). A `StatusSink` created first in `makeProduction()` is handed to `DictationCoordinator` at construction, removing `setStatusHandler`. Registries/managers move into a side-effect-free `SpeechBackendGraph.make(...)` so tests can assert the production maps without the rest of the graph.

**Files:**
- Create: `Relay/App/StatusSink.swift`, `Relay/App/SpeechBackendGraph.swift`
- Create: `RelayTests/Support/RelayRuntime+Testing.swift`, `RelayTests/App/SpeechBackendGraphTests.swift`
- Modify: `Relay/App/RelayRuntime.swift`, `Relay/App/AppModel.swift`, `Relay/App/RelayApp.swift`, `Relay/SpeechIn/DictationCoordinator.swift`
- Modify tests: `RelayTests/ProjectSmokeTests.swift`, `RelayTests/App/SettingsViewsSmokeTests.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/AppModelIntegrationsTests.swift`, `RelayTests/App/AppModelHotkeySideEffectTests.swift`, `RelayTests/App/TTSBackendCatalogTests.swift`
- Delete: `RelayTests/App/TTSMigrationProductionWiringTests.swift`

- [ ] **Step 1: Add `StatusSink`** — `Relay/App/StatusSink.swift`:

```swift
import Observation

/// The single owner of Relay's transient, user-facing status line (the menu bar's idle text).
/// Created first in `RelayRuntime.makeProduction()` and handed to every writer — `AppModel`, its
/// sub-models, and `DictationCoordinator` — at construction time, so nothing is re-pointed after
/// `AppModel` exists.
@MainActor
@Observable
final class StatusSink {
    static let idleMessage = "Ready"

    private(set) var message: String

    init(message: String = StatusSink.idleMessage) {
        self.message = message
    }

    func post(_ message: String) {
        self.message = message
    }
}
```

- [ ] **Step 2: Add the test support factory and shared doubles** — `RelayTests/Support/RelayRuntime+Testing.swift`. The doubles are the richest existing private fakes from `AppModelTests.swift`, renamed with a `Spy`/`Stub` prefix so they never collide with the many file-private `Fake*` types elsewhere.

```swift
import Foundation
@testable import Relay

@MainActor
extension RelayRuntime {
    /// A `RelayRuntime` whose every service is a side-effect-free fake unless injected. Never
    /// touches `UserDefaults.standard`, the CGEvent tap, the real socket, `~/.claude`, `~/.codex`
    /// or `~/Library/Application Support`. Focus resolution defaults to a service over the SAME
    /// `sessionRegistry`/`frontmostApps` passed here — never a second registry.
    static func testing(
        settingsStore: any SettingsStoring = SpySettingsStore(),
        selectionReader: any SelectionReading = SpySelectionReader(),
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: any SpeechCoordinating = SpySpeechCoordinator(),
        hotkeyManager: any HotkeyManaging = SpyHotkeyManager(),
        permissionService: any GlobalPermissionAuthorizing = SpyPermissionService(),
        microphonePermissions: any MicrophonePermissionStatusProviding = SpyMicrophonePermission(granted: true),
        privacySettingsOpener: any PrivacySettingsOpening = SpyPrivacyOpener(),
        loginItemService: any LoginItemControlling = SpyLoginItemController(enabled: false),
        diagnostics: DiagnosticsRecorder = DiagnosticsRecorder(capacity: 10),
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        status: StatusSink = StatusSink(),
        dictationCoordinator: (any DictationCoordinating)? = nil,
        overlayModel: ActivityOverlayModel = ActivityOverlayModel(),
        overlayPresenter: any ActivityOverlayPresenting = NoOpActivityOverlayPresenter(),
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:],
        hookEnvelopeReceiver: HookEnvelopeReceiver? = nil,
        integrationManager: IntegrationManager? = nil,
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        hookSocketPath: String? = nil,
        sessionRegistry: AgentSessionRegistry = AgentSessionRegistry(),
        frontmostApps: any FrontmostAppMonitoring = StubFrontmostAppMonitor(pid: nil),
        focusResolution: (any SessionFocusResolving)? = nil,
        processInspector: ProcessInspector = ProcessInspector(runner: AllPIDsAliveProcessRunner())
    ) -> RelayRuntime {
        let settings = settingsStore.load()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        let helperPath = "/Applications/Relay.app/Contents/Helpers/RelayHook"
        let receiver = hookEnvelopeReceiver ?? HookEnvelopeReceiver(diagnostics: integrationDiagnosticsLog)
        let manager = integrationManager ?? IntegrationManager(
            events: receiver.events,
            integrations: [StopHookIntegration.claudeCode, StopHookIntegration.codex],
            speechCoordinator: speechCoordinator,
            diagnostics: integrationDiagnosticsLog
        )
        // Short on purpose: a unix socket path must fit in `sun_path` (104 bytes), and it must
        // never be the production socket.
        let socketPath = hookSocketPath ?? "/tmp/relay-rt-\(UUID().uuidString.prefix(8)).sock"
        return RelayRuntime(
            status: status,
            settingsStore: settingsStore,
            settings: settings,
            settingsBox: SettingsBox(settings),
            diagnostics: diagnostics,
            integrationDiagnosticsLog: integrationDiagnosticsLog,
            permissionService: permissionService,
            microphonePermissions: microphonePermissions,
            privacySettingsOpener: privacySettingsOpener,
            loginItemService: loginItemService,
            sessions: SessionServices(
                registry: sessionRegistry,
                frontmostApps: frontmostApps,
                processInspector: processInspector,
                focusResolution: focusResolution ?? FocusResolutionService(
                    registry: sessionRegistry,
                    frontmostApps: frontmostApps,
                    processSnapshots: processInspector,
                    resolvers: []
                )
            ),
            speechOut: SpeechOutputServices(
                ttsRegistry: ttsRegistry,
                ttsModelManagers: ttsModelManagers,
                speechCoordinator: speechCoordinator,
                overlayModel: overlayModel,
                overlayPresenter: overlayPresenter
            ),
            speechIn: SpeechInputServices(
                sttRegistry: sttRegistry,
                speechModelManagers: speechModelManagers,
                dictationCoordinator: dictationCoordinator,
                whisperSelectionWriter: WhisperSelectionWriterBox(cache: WhisperSelectionCache(nil))
            ),
            integrations: IntegrationServices(
                socketPath: socketPath,
                hookEnvelopeReceiver: receiver,
                integrationManager: manager,
                claudeCodeInstaller: claudeCodeInstaller ?? ClaudeCodeInstaller(
                    baseDirectory: sandbox.appendingPathComponent("claude", isDirectory: true),
                    helperPath: helperPath
                ),
                codexInstaller: codexInstaller ?? CodexInstaller(
                    baseDirectory: sandbox.appendingPathComponent("codex", isDirectory: true),
                    helperPath: helperPath
                ),
                helperInstaller: helperInstaller ?? HelperInstaller(
                    baseDirectory: sandbox.appendingPathComponent("appsupport", isDirectory: true)
                ),
                bundledHelperURL: bundledHelperURL ?? sandbox
                    .appendingPathComponent("no-such-bundle", isDirectory: true)
                    .appendingPathComponent("RelayHook")
            ),
            hotkeyManager: hotkeyManager,
            selectionReader: selectionReader,
            preprocessor: preprocessor
        )
    }
}

// MARK: - Shared app-level test doubles

@MainActor
final class SpySettingsStore: SettingsStoring {
    let settings: AppSettings
    let saveError: Error?
    private(set) var saved: [AppSettings] = []

    init(settings: AppSettings = .defaults, saveError: Error? = nil) {
        self.settings = settings
        self.saveError = saveError
    }

    func load() -> AppSettings { settings }
    func save(_ value: AppSettings) throws {
        if let saveError { throw saveError }
        saved.append(value)
    }
}

@MainActor
final class SpySelectionReader: SelectionReading {
    let text: String
    private(set) var readCount = 0

    init(text: String = "selected") { self.text = text }

    func readSelection() throws -> SelectionResult {
        readCount += 1
        return .init(text: text, source: .accessibility)
    }
}

@MainActor
final class SpySpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stopCount = 0
    private(set) var stoppedSessionIDs: [UUID] = []
    private(set) var replayCount = 0
    private(set) var previews: [(text: String, backendID: String, options: TTSOptions)] = []
    let replayError: Error?
    let speakError: Error?

    init(replayError: Error? = nil, speakError: Error? = nil) {
        self.replayError = replayError
        self.speakError = speakError
    }

    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
        if let speakError { throw speakError }
    }
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {
        previews.append((text, backendID, options))
        if let speakError { throw speakError }
    }
    func stop() { stopCount += 1 }
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws {
        replayCount += 1
        if let replayError { throw replayError }
    }
}

@MainActor
final class SpyHotkeyManager: HotkeyManaging {
    private let status: HotkeyRegistrationStatus
    private var handler: ((HotkeyAction, HotkeyPhase) -> Void)?
    private(set) var registrations: [AppSettings] = []

    init(status: HotkeyRegistrationStatus = .registered) { self.status = status }

    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        registrations.append(settings)
        self.handler = handler
        return status
    }

    func send(_ action: HotkeyAction, _ phase: HotkeyPhase) { handler?(action, phase) }
}

@MainActor
final class SpyPermissionService: GlobalPermissionAuthorizing {
    let value: PermissionSnapshot
    private(set) var snapshotCount = 0
    private(set) var requestCount = 0

    init(snapshot: PermissionSnapshot = .init(inputMonitoringGranted: true, accessibilityGranted: true)) {
        value = snapshot
    }

    func snapshot() -> PermissionSnapshot { snapshotCount += 1; return value }
    func requestPermissions() { requestCount += 1 }
}

@MainActor
final class SpyMicrophonePermission: MicrophonePermissionStatusProviding {
    var grantedValue: Bool
    let requestResult: Bool
    private(set) var requestCount = 0

    init(granted: Bool, requestResult: Bool? = nil) {
        grantedValue = granted
        self.requestResult = requestResult ?? granted
    }

    func isGranted() -> Bool { grantedValue }
    func requestPermission() async -> Bool {
        requestCount += 1
        grantedValue = requestResult
        return requestResult
    }
}

@MainActor
final class SpyPrivacyOpener: PrivacySettingsOpening {
    private(set) var opened: [PrivacySettingsPane] = []
    func open(_ pane: PrivacySettingsPane) { opened.append(pane) }
}

@MainActor
final class SpyLoginItemController: LoginItemControlling {
    private(set) var isEnabled: Bool
    private(set) var setEnabledCalls: [Bool] = []
    private let setEnabledError: Error?

    init(enabled: Bool, setEnabledError: Error? = nil) {
        isEnabled = enabled
        self.setEnabledError = setEnabledError
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let setEnabledError { throw setEnabledError }
        isEnabled = enabled
    }
}

@MainActor
final class SpyDictationCoordinator: DictationCoordinating {
    private(set) var events: [String] = []
    private let blockStart: Bool
    private let blockFinish: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(blockStart: Bool = false, blockFinish: Bool = false) {
        self.blockStart = blockStart
        self.blockFinish = blockFinish
    }

    func start() async {
        events.append("start")
        if blockStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func finish() async {
        events.append("finish")
        if blockFinish { await withCheckedContinuation { finishContinuation = $0 } }
    }
    func toggle() async {
        if events.last == "start" { await finish() } else { await start() }
    }
    func cancel(sessionID: UUID) async {}
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func resumeFinish() { finishContinuation?.resume(); finishContinuation = nil }
}

@MainActor
final class SpyOverlayPresenter: ActivityOverlayPresenting {
    private(set) var states: [ActivityOverlayState] = []
    private(set) var styles: [ActivityOverlayStyle] = []

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        states.append(state)
        styles.append(style)
    }
}

/// Reports `focusedSessionID` (when set) as confidently `.focused`; everything else `.unknown`.
struct StubSessionFocusResolver: SessionFocusResolving {
    let focusedSessionID: AgentSessionID?
    func resolve(session: AgentSession) async -> FocusDecision {
        guard let focusedSessionID, session.id == focusedSessionID else {
            return .unknown(resolverID: "stub", reason: "not the stubbed focused session")
        }
        return .focused(resolverID: "stub", reason: "stubbed focused session")
    }
}

/// Reports a fixed frontmost pid, or no frontmost application when `pid` is nil.
struct StubFrontmostAppMonitor: FrontmostAppMonitoring {
    let pid: Int32?
    func current() async -> FrontmostApplication? {
        guard let pid else { return nil }
        return FrontmostApplication(pid: pid, bundleIdentifier: "com.test.terminal", localizedName: "TestTerminal")
    }
}

/// A process table where every pid in 1...10_000 is alive, so fabricated pids are never pruned.
final class AllPIDsAliveProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let lines = (1...10_000).map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
}

/// An empty process table: every pid looks dead.
final class AllPIDsDeadProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        ProcessResult(stdout: Data(), terminationStatus: 0)
    }
}

extension AgentResponseEvent {
    static func fixture(
        provider: AgentProvider = .claudeCode,
        providerSessionID: String,
        text: String = "Reply",
        parentPID: Int32 = 900,
        capturedAt: Date = Date()
    ) -> AgentResponseEvent {
        .init(
            id: UUID(), provider: provider, providerSessionID: providerSessionID,
            text: text, cwd: "/tmp/repo",
            parentPID: parentPID, environment: [:], capturedAt: capturedAt
        )
    }
}
```

- [ ] **Step 3: Write the failing tests** — replace `RelayTests/ProjectSmokeTests.swift` entirely:

```swift
import XCTest
@testable import Relay

@MainActor
final class ProjectSmokeTests: XCTestCase {
    func testAppModelStartsReady() {
        let model = AppModel(runtime: .testing())
        XCTAssertEqual(model.statusText, "Ready")
    }

    /// `RelayRuntime` owns every service's lifetime, so whoever holds the `AppModel` must keep
    /// the runtime alive — `RelayAppDelegate` used to build the runtime inline and drop it.
    func testAppModelRetainsItsRuntime() {
        weak var weakRuntime: RelayRuntime?
        let model: AppModel
        do {
            let runtime = RelayRuntime.testing()
            weakRuntime = runtime
            model = AppModel(runtime: runtime)
        }
        XCTAssertNotNil(weakRuntime, "AppModel must retain its RelayRuntime")
        withExtendedLifetime(model) {}
    }

    /// `DictationCoordinator` writes the shared status line directly — no post-init re-wiring.
    func testRuntimeStatusSinkIsTheModelsStatusText() {
        let runtime = RelayRuntime.testing()
        let model = AppModel(runtime: runtime)

        runtime.status.post("Inserted dictation")

        XCTAssertEqual(model.statusText, "Inserted dictation")
    }
}
```

Create `RelayTests/App/SpeechBackendGraphTests.swift` (replaces the `makeProduction()` registry assertions in `TTSMigrationProductionWiringTests` and `ProjectSmokeTests`):

```swift
import XCTest
@testable import Relay

/// Pins the production speech registries without building the rest of `makeProduction()`
/// (no UserDefaults, event tap, or socket).
@MainActor
final class SpeechBackendGraphTests: XCTestCase {
    private func makeGraph() -> SpeechBackendGraph {
        SpeechBackendGraph.make(whisperSelection: { nil }, setWhisperSelection: { _ in })
    }

    func testRegistersConcreteSpeechToTextBackendsAndManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.sttRegistry["apple-speech"] is AppleSpeechBackend)
        XCTAssertTrue(graph.sttRegistry["parakeet"] is ParakeetBackend)
        XCTAssertTrue(graph.sttRegistry["whisper"] is WhisperBackend)
        XCTAssertTrue(graph.speechModelManagers["apple-speech"] is AppleSpeechModelManager)
        XCTAssertTrue(graph.speechModelManagers["parakeet"] is ParakeetModelManager)
        XCTAssertTrue(graph.speechModelManagers["whisper"] is WhisperModelManager)
    }

    func testRegistersConcreteTextToSpeechBackendsAndOnlyModelBackedManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.ttsRegistry["pocket-tts"] is PocketTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["kokoro"] is KokoroTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["apple-tts"] is AppleTTSBackend)
        XCTAssertTrue(graph.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
        XCTAssertTrue(graph.ttsModelManagers["kokoro"] is KokoroModelManager)
        XCTAssertNil(graph.ttsModelManagers["apple-tts"])
    }

    func testRegistryKeysMatchTheIDsAppSettingsRecognizes() {
        let graph = makeGraph()

        XCTAssertEqual(Set(graph.sttRegistry.keys), AppSettings.knownSTTBackendIDs)
        XCTAssertEqual(Set(graph.ttsRegistry.keys), AppSettings.knownTTSBackendIDs)
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ProjectSmokeTests 2>&1 | tail -30`
Expected: build FAILS — `RelayRuntime` has no `status:` parameter / `SpeechBackendGraph` not found.

- [ ] **Step 5: Add `SpeechBackendGraph`** — `Relay/App/SpeechBackendGraph.swift`. Cut the backend/manager construction out of `makeProduction()` and paste it here unchanged. On `main@6d14400` those lines are `RelayRuntime.swift` 202–208 (Apple/Kokoro/Pocket TTS, one shared engine per backend+manager pair), 210–214 (`ttsRegistry`), 232–236 (Apple Speech + Parakeet; the local `sttBackend` is renamed `appleSpeech` here), 238–268 (Whisper, **except** the cache/writer-box lines 254–257, which stay in `makeProduction()`, see Step 6), 270–274 (`sttRegistry`) and 364–372 (the two manager maps). Plan 4 leaves every one of these constructor calls valid (see the table above):

```swift
import Foundation

/// The speech backend registries and their model managers. Constructing these touches no settings
/// storage, event tap, socket, or other process-wide state, so a test can pin the production maps
/// (`SpeechBackendGraphTests`) without building the rest of `RelayRuntime.makeProduction()`.
@MainActor
struct SpeechBackendGraph {
    let ttsRegistry: [String: any TextToSpeechBackend]
    let ttsModelManagers: [String: any SpeechModelManaging]
    let sttRegistry: [String: any SpeechToTextBackend]
    let speechModelManagers: [String: any SpeechModelManaging]

    static func make(
        whisperSelection: @escaping WhisperModelSelection,
        setWhisperSelection: @escaping WhisperModelSelectionWriter
    ) -> SpeechBackendGraph {
        let appleTTS = AppleTTSBackend()
        let kokoroEngine: any KokoroEngine = FluidAudioKokoroEngine()
        let kokoroTTS = KokoroTTSBackend(engine: kokoroEngine)
        let kokoroModelManager = KokoroModelManager(engine: kokoroEngine)
        let pocketEngine: any PocketTTSEngine = FluidAudioPocketTTSEngine()
        let pocketTTS = PocketTTSBackend(engine: pocketEngine)
        let pocketModelManager = PocketTTSModelManager(engine: pocketEngine)

        let appleSpeech = AppleSpeechBackend()
        let appleSpeechModelManager = AppleSpeechModelManager()
        let parakeetEngine: any ParakeetEngine = FluidAudioParakeetEngine()
        let parakeetBackend = ParakeetBackend(engine: parakeetEngine)
        let parakeetModelManager = ParakeetModelManager(engine: parakeetEngine)

        // Whisper is registered but never enabled by default: `sttBackendOrder` defaults to
        // `["apple-speech"]`; the user opts in and picks a model in Settings.
        // Models are shared by Debug and Release (see `RelayPaths.sharedModelsDirectory`).
        let whisperCacheDirectory = RelayPaths.sharedModelsDirectory()
            .appendingPathComponent("Whisper", isDirectory: true)
        let whisperStore = WhisperModelStore(
            cacheDirectory: whisperCacheDirectory,
            downloader: HuggingFaceWhisperDownloader()
        )
        let whisperRuntime = WhisperRuntime(
            engine: WhisperKitEngine(),
            modelFolder: { whisperStore.modelDirectory(for: $0) }
        )
        let whisperBackend = WhisperBackend(
            store: whisperStore,
            runtime: whisperRuntime,
            selectedModel: whisperSelection
        )
        let whisperModelManager = WhisperModelManager(
            store: whisperStore,
            runtime: whisperRuntime,
            selectedModel: whisperSelection,
            setSelectedModel: setWhisperSelection
        )

        return SpeechBackendGraph(
            ttsRegistry: [
                appleTTS.id: appleTTS,
                kokoroTTS.id: kokoroTTS,
                pocketTTS.id: pocketTTS,
            ],
            ttsModelManagers: [
                kokoroModelManager.backendID: kokoroModelManager,
                pocketModelManager.backendID: pocketModelManager,
            ],
            sttRegistry: [
                appleSpeech.id: appleSpeech,
                parakeetBackend.id: parakeetBackend,
                whisperBackend.id: whisperBackend,
            ],
            speechModelManagers: [
                appleSpeechModelManager.backendID: appleSpeechModelManager,
                parakeetModelManager.backendID: parakeetModelManager,
                whisperModelManager.backendID: whisperModelManager,
            ]
        )
    }
}
```

- [ ] **Step 6: Update `RelayRuntime`** (`Relay/App/RelayRuntime.swift`):

1. `SpeechInputServices.dictationCoordinator` (currently the concrete `let dictationCoordinator: DictationCoordinator?`, kept concrete only for `setStatusHandler`) becomes `let dictationCoordinator: (any DictationCoordinating)?`; replace that struct's doc comment with: `/// Speech-input services: the STT backend registry, its per-backend model managers, and the dictation coordinator built around them.`
2. Add `let status: StatusSink` as the first stored property of `RelayRuntime` and `status: StatusSink,` as the first init parameter (`self.status = status`).
3. Replace the `RelayRuntime` class doc comment with:
```swift
/// The composition root for Relay's dependency graph. Constructs every subsystem; `AppModel`
/// retains the runtime (`AppModel.runtime`) for its whole life, which is what keeps every service
/// alive. Explicit initializer, no DI framework. Production uses `makeProduction()`; tests use
/// `RelayRuntime.testing(...)` in `RelayTests/Support/RelayRuntime+Testing.swift` and never
/// call `makeProduction()`.
```
4. Replace the `makeProduction()` doc comment with `/// Builds Relay's real production dependency graph. Touches UserDefaults, the CGEvent tap and real backends — never call from tests.`
5. In `makeProduction()`: first line becomes `let status = StatusSink()`. Delete the pasted-out backend construction and build the graph instead, **at the top of `makeProduction()`, right after the settings are loaded and before `TTSRouter` is built** (the router needs `ttsRegistry`). The Whisper cache and writer box are created here too (they are the graph's only inputs):
```swift
        let whisperSelectionCache = WhisperSelectionCache(
            settings.selectedSpeechModelByBackend["whisper"].flatMap(WhisperModelID.init(rawValue:))
        )
        let whisperSelectionWriter = WhisperSelectionWriterBox(cache: whisperSelectionCache)
        let graph = SpeechBackendGraph.make(
            whisperSelection: { whisperSelectionCache.read() },
            setWhisperSelection: { whisperSelectionWriter.write($0) }
        )
        let ttsRegistry = graph.ttsRegistry
        let sttRegistry = graph.sttRegistry
```
   `TTSRouter` keeps `backends: ttsRegistry`. `StreamingAudioPlayer()` stays in `makeProduction()`. In the `STTRouter` order closure replace `[sttBackend.id]` with `["apple-speech"]` (Task 12 removes the double default entirely).
5a. `IntegrationServices` gains the socket path as its first stored property, with the production value as a static:
```swift
    /// Where `IntegrationSetupModel.start()` opens the hook socket. `productionSocketPath` in the
    /// app; a short temp path in tests (`RelayRuntime.testing`), so tests never bind the real one.
    let socketPath: String

    /// This build's socket (`Relay/relay.sock` for Release, `Relay Debug/relay.sock` for Debug).
    /// `RelayHook` derives the same path from its own location.
    static var productionSocketPath: String { RelayPaths.socketPath() }
```
   and `makeProduction()`'s `IntegrationServices(` call gets `socketPath: IntegrationServices.productionSocketPath,` first. `AppModel.integrationSocketPath` becomes `static var integrationSocketPath: String { IntegrationServices.productionSocketPath }` (deleted in Task 2).
6. `DictationCoordinator(... status: { _ in }, ...)` → `status: { status.post($0) },`.
7. Final `RelayRuntime(` call: add `status: status,` first; `speechOut` uses `ttsModelManagers: graph.ttsModelManagers`; `speechIn` uses `speechModelManagers: graph.speechModelManagers`. Delete the now-unused local `speechModelManagers`/`ttsModelManagers` dictionaries.

- [ ] **Step 7: Delete `setStatusHandler`** from `Relay/SpeechIn/DictationCoordinator.swift` (the one-liner `func setStatusHandler(_ handler: @escaping (String) -> Void) { status = handler }` right after `init`, ~line 103 after plan 4) and make `status` immutable: `private var status: (String) -> Void` → `private let status: (String) -> Void`. Also delete the `AppModel(runtime:)` line that called it: `runtime.speechIn.dictationCoordinator?.setStatusHandler { [weak self] in self?.statusText = $0 }` (`AppModel.swift` 185, removed with the convenience init in Step 8).

- [ ] **Step 8: Collapse `AppModel` to one initializer** (`Relay/App/AppModel.swift`):

1. Delete `convenience init(runtime:)`, the public `init(settingsStore:…)` and the `private init(settingsStore:…loadedSettings:…)` (`AppModel.swift` 149–373).
2. Replace every *dependency* stored property (`overlayModel`, `sttRegistry`, `ttsRegistry`, `settingsStore`, `selectionReader`, `preprocessor`, `speechCoordinator`, `dictationCoordinator`, `hotkeyManager`, `settingsState`, `permissionService`, `microphonePermissions`, `privacySettingsOpener`, `loginItemService`, `diagnostics`, `overlayPresenter`, `hookEnvelopeReceiver`, `integrationManager`, `claudeCodeInstaller`, `codexInstaller`, `helperInstaller`, `bundledHelperURL`, `sessionRegistry`, `focusResolution`, `frontmostApps`, `processInspector`, `integrationDiagnosticsLog`) and their doc comments with the block below. `statusText` becomes a forward to the sink. State stored properties (`settings`, `dictationPhase`, …, `installerStatuses`, `modelController`, `voiceCatalog`, generations, initial refresh tasks, `activationObserver`, `dictationTask`) stay.

```swift
    /// The graph this model was built from. Retained for the model's (= the app's) lifetime.
    @ObservationIgnored let runtime: RelayRuntime

    var statusText: String {
        get { runtime.status.message }
        set { runtime.status.post(newValue) }
    }

    var overlayModel: ActivityOverlayModel { runtime.speechOut.overlayModel }
    var sttRegistry: [String: any SpeechToTextBackend] { runtime.speechIn.sttRegistry }
    var ttsRegistry: [String: any TextToSpeechBackend] { runtime.speechOut.ttsRegistry }
    private var settingsStore: any SettingsStoring { runtime.settingsStore }
    private var selectionReader: any SelectionReading { runtime.selectionReader }
    private var preprocessor: RulesSpeechPreprocessor { runtime.preprocessor }
    private var speechCoordinator: any SpeechCoordinating { runtime.speechOut.speechCoordinator }
    private var dictationCoordinator: (any DictationCoordinating)? { runtime.speechIn.dictationCoordinator }
    private var hotkeyManager: any HotkeyManaging { runtime.hotkeyManager }
    private var settingsState: SettingsBox { runtime.settingsBox }
    private var permissionService: any GlobalPermissionAuthorizing { runtime.permissionService }
    private var microphonePermissions: any MicrophonePermissionStatusProviding { runtime.microphonePermissions }
    private var privacySettingsOpener: any PrivacySettingsOpening { runtime.privacySettingsOpener }
    private var loginItemService: any LoginItemControlling { runtime.loginItemService }
    private var diagnostics: DiagnosticsRecorder { runtime.diagnostics }
    private var overlayPresenter: any ActivityOverlayPresenting { runtime.speechOut.overlayPresenter }
    private var hookEnvelopeReceiver: HookEnvelopeReceiver { runtime.integrations.hookEnvelopeReceiver }
    private var integrationManager: IntegrationManager { runtime.integrations.integrationManager }
    private var claudeCodeInstaller: ClaudeCodeInstaller { runtime.integrations.claudeCodeInstaller }
    private var codexInstaller: CodexInstaller { runtime.integrations.codexInstaller }
    private var helperInstaller: HelperInstaller { runtime.integrations.helperInstaller }
    private var bundledHelperURL: URL { runtime.integrations.bundledHelperURL }
    private var sessionRegistry: AgentSessionRegistry { runtime.sessions.registry }
    private var focusResolution: any SessionFocusResolving { runtime.sessions.focusResolution }
    private var frontmostApps: any FrontmostAppMonitoring { runtime.sessions.frontmostApps }
    private var processInspector: ProcessInspector { runtime.sessions.processInspector }
    private var integrationDiagnosticsLog: IntegrationDiagnosticsLog { runtime.integrationDiagnosticsLog }
    /// Plan 1's injectable socket path now comes from the runtime (a temp path in tests).
    var hookSocketPath: String { runtime.integrations.socketPath }
```
   Delete plan 1's stored `hookSocketPath` and its init parameter/assignments (the computed property above replaces it; `startIntegrations()` keeps reading `hookSocketPath`). Change the remaining stored declarations to `@ObservationIgnored let modelController: SpeechModelController`, `@ObservationIgnored let voiceCatalog: SpeechVoiceCatalog`, and remove the old `var statusText = "Ready"`.
3. Add the single initializer where the old ones were:

```swift
    /// The only initializer. Production passes `RelayRuntime.makeProduction()`; tests pass
    /// `RelayRuntime.testing(...)`. No defaults: every dependency comes from `runtime`.
    init(runtime: RelayRuntime) {
        self.runtime = runtime
        modelController = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers
            ),
            diagnostics: runtime.diagnostics
        )
        voiceCatalog = SpeechVoiceCatalog()
        permissionSnapshot = runtime.permissionService.snapshot()
        microphonePermissionGranted = runtime.microphonePermissions.isGranted()
        launchAtLoginEnabled = runtime.loginItemService.isEnabled
        settings = runtime.settings
        configureModelController()
        registerHotkeys()
        observeAppActivation()
        bindOverlayPresenter()
        // Remaining post-init wiring; removed in Task 3 when settings get their own owner.
        runtime.speechIn.whisperSelectionWriter.persist = { [weak self] modelID in
            self?.setSelectedSpeechModel(backendID: "whisper", modelID: modelID?.rawValue)
        }
        initialSpeechBackendRefresh = Task { [weak self] in
            await self?.refreshSpeechBackendStatuses()
            await self?.modelController.refresh(domain: .dictation)
        }
        initialTTSBackendRefresh = Task { [weak self] in
            await self?.refreshTTSBackendStatuses()
            await self?.modelController.refresh(domain: .textToSpeech)
        }
    }
```
4. Fix the stale doc comment on `setSelectedSpeechModel` (it references the deleted `AppModel(runtime:)` convenience init): `/// Persists a multi-model STT backend's selected model id. Reached from Whisper's model manager through the writer wired in init.`

- [ ] **Step 9: `RelayApp.swift`** — replace the delegate's doc comment:
```swift
/// Owns the single production `AppModel`, which retains the `RelayRuntime` it is built from, and
/// drives the agent-integration socket from real launch/termination events. Tests never use this
/// type and never call `makeProduction()`.
```

- [ ] **Step 10: Migrate the test files to `.testing(...)`**

`RelayTests/App/AppModelTests.swift`:
1. Delete these file-private declarations (they now live in Support): `FakeOverlayPresenter`, `FakeDictationCoordinator`, `FakePermissionService`, `FakeMicrophonePermissionStatus`, `FakePrivacySettingsOpener`, `FakeLoginItemController`, `FakeSettingsStore`, `FakeSelectionReader`, `FakeSpeechCoordinator`, `StubSessionFocusResolver`, `StubFrontmostAppMonitor`, `AlwaysAliveProcessRunner`, `FakeHotkeyManager`. Also delete the dead `FakeMultiModelSpeechModelManager`, `FakeSpeechModelManager` and `makeModelStatus` (declared, never used).
2. Rename references:
```bash
cd RelayTests/App
sed -i '' \
  -e 's/FakeOverlayPresenter/SpyOverlayPresenter/g' \
  -e 's/FakeDictationCoordinator/SpyDictationCoordinator/g' \
  -e 's/FakePermissionService/SpyPermissionService/g' \
  -e 's/FakeMicrophonePermissionStatus/SpyMicrophonePermission/g' \
  -e 's/FakePrivacySettingsOpener/SpyPrivacyOpener/g' \
  -e 's/FakeLoginItemController/SpyLoginItemController/g' \
  -e 's/FakeSettingsStore/SpySettingsStore/g' \
  -e 's/FakeSelectionReader/SpySelectionReader/g' \
  -e 's/FakeSpeechCoordinator/SpySpeechCoordinator/g' \
  -e 's/FakeHotkeyManager/SpyHotkeyManager/g' \
  -e 's/AlwaysAliveProcessRunner/AllPIDsAliveProcessRunner/g' \
  -e 's/AllProcessesDeadRunner/AllPIDsDeadProcessRunner/g' \
  AppModelTests.swift
cd ../..
```
   Then delete the private `AllProcessesDeadRunner` declaration (now `AllPIDsDeadProcessRunner`, in Support).
3. Delete `testRealAppModelRegistersExpectedTTSModelManagers` (covered by `SpeechBackendGraphTests`).
4. Replace `makeModel(...)` with (same parameters, same call sites):
```swift
    private func makeModel(
        store: SpySettingsStore? = nil,
        selection: SpySelectionReader? = nil,
        speech: SpySpeechCoordinator? = nil,
        hotkeys: SpyHotkeyManager? = nil,
        permissions: SpyPermissionService? = nil,
        dictation: SpyDictationCoordinator? = nil,
        microphone: SpyMicrophonePermission? = nil,
        opener: SpyPrivacyOpener? = nil,
        loginItem: SpyLoginItemController? = nil,
        overlayModel: ActivityOverlayModel? = nil,
        overlayPresenter: (any ActivityOverlayPresenting)? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        diagnostics: DiagnosticsRecorder? = nil,
        sessionRegistry: AgentSessionRegistry? = nil,
        focusResolution: (any SessionFocusResolving)? = nil,
        frontmostApps: (any FrontmostAppMonitoring)? = nil,
        integrationManager: IntegrationManager? = nil,
        processInspector: ProcessInspector? = nil
    ) -> AppModel {
        AppModel(runtime: .testing(
            settingsStore: store ?? SpySettingsStore(),
            selectionReader: selection ?? SpySelectionReader(),
            speechCoordinator: speech ?? SpySpeechCoordinator(),
            hotkeyManager: hotkeys ?? SpyHotkeyManager(),
            permissionService: permissions ?? SpyPermissionService(),
            microphonePermissions: microphone ?? SpyMicrophonePermission(granted: true),
            privacySettingsOpener: opener ?? SpyPrivacyOpener(),
            loginItemService: loginItem ?? SpyLoginItemController(enabled: false),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: dictation,
            overlayModel: overlayModel ?? ActivityOverlayModel(),
            overlayPresenter: overlayPresenter ?? NoOpActivityOverlayPresenter(),
            sttRegistry: sttRegistry,
            speechModelManagers: speechModelManagers,
            integrationManager: integrationManager,
            sessionRegistry: sessionRegistry ?? AgentSessionRegistry(),
            frontmostApps: frontmostApps ?? StubFrontmostAppMonitor(pid: nil),
            focusResolution: focusResolution,
            processInspector: processInspector ?? ProcessInspector(runner: AllPIDsAliveProcessRunner())
        ))
    }
```
5. In `makeTTSRoutingModel`, replace the `AppModel(settingsStore: …)` call with:
```swift
        let model = AppModel(runtime: .testing(
            settingsStore: store,
            selectionReader: SpySelectionReader(text: "hello"),
            speechCoordinator: coordinator,
            hotkeyManager: hotkeys,
            overlayModel: overlay,
            ttsRegistry: ["pocket-tts": pocket, "kokoro": kokoro, "apple-tts": apple]
        ))
```
6. Delete the private `makeAgentResponseEvent` helper and replace its call sites: `sed -i '' 's/makeAgentResponseEvent(/AgentResponseEvent.fixture(/g' RelayTests/App/AppModelTests.swift`.

`RelayTests/App/AppModelIntegrationsTests.swift`: delete its private `FakeSettingsStore`, `FakeSelectionReader`, `FakeHotkeyManager`, `AlwaysAliveProcessRunner` (use Support's `AllPIDsAliveProcessRunner`: `sed -i '' 's/AlwaysAliveProcessRunner/AllPIDsAliveProcessRunner/g'`). Keep its private `FakeSpeechCoordinator` (the speak-latest tests construct it directly), `AlwaysSucceedIntegration`, `StubWiringSessionFocusResolver`, `RecordingWiringSpeechSink` and `TestError`. `makeModel` keeps plan 1's `hookSocketPath: String? = nil` parameter and its `hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver()` parameter; replace its body (a `nil` path means the factory's unique temp path — never the real socket), then delete the now-unused private `uniqueTestSocketPath()` helper and, in the file-level SAFETY doc comment, replace "`makeModel`'s default `hookSocketPath` is a unique `/tmp` path per call" with "`RelayRuntime.testing` defaults the socket path to a unique `/tmp` path per call":
```swift
        AppModel(runtime: .testing(
            hookEnvelopeReceiver: hookEnvelopeReceiver,
            integrationManager: integrationManager,
            claudeCodeInstaller: claudeCodeInstaller ?? makeClaudeInstaller(),
            codexInstaller: codexInstaller ?? makeCodexInstaller(),
            helperInstaller: helperInstaller ?? makeHelperInstaller(),
            bundledHelperURL: bundledHelperURL ?? nonexistentBundledHelperURL,
            hookSocketPath: hookSocketPath
        ))
```

`RelayTests/App/AppModelHotkeySideEffectTests.swift`: delete private `FakeSettingsStore`, `FakeSelectionReader`, `FakeSpeechCoordinator`; `makeModel` body becomes `AppModel(runtime: .testing(hotkeyManager: hotkeys))`.

`RelayTests/App/TTSBackendCatalogTests.swift`: delete `NoOpSelectionReader`, `NoOpSpeechCoordinator`, `NoOpHotkeyManager`; `makeModel` body becomes:
```swift
        AppModel(runtime: .testing(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            ttsRegistry: ttsRegistry,
            ttsModelManagers: ttsModelManagers
        ))
```

`RelayTests/App/SettingsViewsSmokeTests.swift`: in `testAllSettingsTabViewsConstruct` and `testMenuBarContentViewConstructsInBothAutoReadStates` replace `AppModel(runtime: .makeProduction())` with `AppModel(runtime: .testing())`. `testPermissionsSettingsViewConstructsWithZeroFrameCaptureDiagnostics` currently calls the public init with a real `SettingsStore()`, `SelectionReader(accessibility: AccessibilityService(), clipboard: ClipboardService())`, a `SpeechCoordinator` over `TTSRouter(backends: [:], backendOrder: { [] }, player: FakePlayer())` and a real `GlobalHotkeyManager(diagnostics: diagnosticsRecorder)`; replace that whole `AppModel(settingsStore: …)` call with:
```swift
        let model = AppModel(runtime: .testing(diagnostics: diagnosticsRecorder))
```
   and drop the "restores it afterward" part of the menu-bar test's doc comment (a spy store never touches disk).

Delete `RelayTests/App/TTSMigrationProductionWiringTests.swift`.

- [ ] **Step 11: Verify no test builds the production graph**

Run: `grep -rn "makeProduction" RelayTests`
Expected: no output.

- [ ] **Step 12: Run the full suite**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 13: Commit**
```bash
git add Relay/App/StatusSink.swift Relay/App/SpeechBackendGraph.swift Relay/App/RelayRuntime.swift \
  Relay/App/AppModel.swift Relay/App/RelayApp.swift Relay/SpeechIn/DictationCoordinator.swift \
  RelayTests/Support/RelayRuntime+Testing.swift RelayTests/App/SpeechBackendGraphTests.swift \
  RelayTests/ProjectSmokeTests.swift RelayTests/App/SettingsViewsSmokeTests.swift \
  RelayTests/App/AppModelTests.swift RelayTests/App/AppModelIntegrationsTests.swift \
  RelayTests/App/AppModelHotkeySideEffectTests.swift RelayTests/App/TTSBackendCatalogTests.swift \
  RelayTests/App/TTSMigrationProductionWiringTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(app): give AppModel one runtime-based initializer and a shared status sink"
```

---

## Task 2: `IntegrationSetupModel`

**Finding:** `AppModel.swift` (after plans 1 and 3) holds the socket lifecycle and its failure reporting, install/uninstall/check, the launch-time helper refresh, installer statuses, status merge, error mapping, session summaries and the socket path — a self-contained feature.

**Files:**
- Create: `Relay/App/IntegrationSetupModel.swift`
- Modify: `Relay/App/AppModel.swift`, `Relay/App/RelayApp.swift`, `Relay/App/Settings/IntegrationsSettingsView.swift`, `Relay/App/MenuBarContentView.swift`
- Rename/modify test: `RelayTests/App/AppModelIntegrationsTests.swift` → `RelayTests/App/IntegrationSetupModelTests.swift`
- Modify test: `RelayTests/Shared/RelayPathsTests.swift`

- [ ] **Step 1: Move and retarget the tests**
```bash
git mv RelayTests/App/AppModelIntegrationsTests.swift RelayTests/App/IntegrationSetupModelTests.swift
sed -i '' \
  -e 's/final class AppModelIntegrationsTests/final class IntegrationSetupModelTests/' \
  -e 's/model\.installIntegration(/model.install(/g' \
  -e 's/model\.uninstallIntegration(/model.uninstall(/g' \
  -e 's/model\.checkIntegration(/model.check(/g' \
  -e 's/model\.integrationStatus(for:/model.status(for:/g' \
  -e 's/model\.latestAgentResponseAvailable/model.latestResponseAvailable/g' \
  -e 's/model\.startIntegrations()/model.start()/g' \
  -e 's/model\.integrationDiagnosticsEntries()/integrationLog.snapshot()/g' \
  -e 's/AppModel\.anotherInstanceOwnsSocketMessage/IntegrationSetupModel.anotherInstanceOwnsSocketMessage/g' \
  -e 's/AppModel\.socketStartFailedMessage/IntegrationSetupModel.socketStartFailedMessage/g' \
  RelayTests/App/IntegrationSetupModelTests.swift
sed -i '' 's/AppModel\.integrationSocketPath/IntegrationServices.productionSocketPath/g' RelayTests/Shared/RelayPathsTests.swift
```
(`model.socketStatusMessage` and `model.isSocketListening` keep their names on the new model.) In `RelayPathsTests.testAppAndHelperDefaultsAgreeWithRelayPaths`, the sed rewrites both assertions (lines 49–50); also delete its now-wrong doc line "`@MainActor`: `AppModel` (and its static `integrationSocketPath`) is MainActor-isolated." and the `@MainActor` attribute on that test (`IntegrationServices` is a plain struct).

Add a stored log to the test class (XCTest builds one instance per test, so it is fresh each time), and replace `makeModel` with a runtime builder plus a thin wrapper:
```swift
    /// The integration-pipeline log every runtime in this file writes to.
    private let integrationLog = IntegrationDiagnosticsLog()

    private func makeRuntime(
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        hookSocketPath: String? = nil
    ) -> RelayRuntime {
        .testing(
            integrationDiagnosticsLog: integrationLog,
            hookEnvelopeReceiver: hookEnvelopeReceiver,
            integrationManager: integrationManager,
            claudeCodeInstaller: claudeCodeInstaller ?? makeClaudeInstaller(),
            codexInstaller: codexInstaller ?? makeCodexInstaller(),
            helperInstaller: helperInstaller ?? makeHelperInstaller(),
            bundledHelperURL: bundledHelperURL ?? nonexistentBundledHelperURL,
            hookSocketPath: hookSocketPath
        )
    }

    private func makeModel(
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        hookSocketPath: String? = nil
    ) -> IntegrationSetupModel {
        IntegrationSetupModel(runtime: makeRuntime(
            claudeCodeInstaller: claudeCodeInstaller,
            codexInstaller: codexInstaller,
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            integrationManager: integrationManager,
            hookEnvelopeReceiver: hookEnvelopeReceiver,
            hookSocketPath: hookSocketPath
        ))
    }
```
Four tests still exercise `AppModel.speakLatestAgentResponse()` until Task 7 moves it: `testLatestAgentResponseAvailableReflectsTheInjectedManagerAndSpeakLatestDelegatesToItsCoordinator`, `testSpeakLatestAgentResponseFailureIsCaughtAndSurfacedWithoutCrashing`, plan 1's `testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission`, and `testSpeakLatestAgentResponseSuccessClearsAStaleStatusText` (it sets `model.statusText = "Could not speak the latest agent response."` first; Task 1's `statusText` setter forwards to the sink, so that line compiles unchanged). In each, replace `let model = makeModel(integrationManager: manager)` with `let model = AppModel(runtime: makeRuntime(integrationManager: manager))`; in the first, the two availability checks read `model.integrationSetup.latestResponseAvailable`. Update the file-level doc comment: `AppModel.startIntegrations()` → `IntegrationSetupModel.start()`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/IntegrationSetupModelTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'IntegrationSetupModel' in scope`.

- [ ] **Step 3: Create `Relay/App/IntegrationSetupModel.swift`.** It carries plans 1 and 3 over unchanged; only the dependencies move (`statusText`/`AppModel` statics → this type, `hookSocketPath` → `socketPath`, stored services → `services.*`):

```swift
import Foundation
import Observation
import os

/// Thrown by `IntegrationSetupModel.installBundledHelperIfPresent` when, after attempting to
/// refresh the bundled `RelayHook` helper at its stable Application Support path, there is still
/// no valid (present and executable) helper there. `install(_:)` surfaces it as
/// `.configurationError` instead of writing an agent config that points at nothing runnable.
enum HelperInstallVerificationError: Error, Sendable {
    case stableHelperUnavailable
}

/// Agent-integration setup for the Integrations tab and app lifecycle: the hook socket, the
/// per-provider Stop-hook installers, the stable helper, and the compact session list.
@MainActor
@Observable
final class IntegrationSetupModel {
    /// Compact, privacy-safe metadata for one ephemeral agent session: provider, cwd, last
    /// activity. Never response text, never a focus verdict.
    struct AgentSessionSummary: Identifiable, Equatable, Sendable {
        let id: AgentSessionID
        let cwd: String
        let lastActivityAt: Date

        var provider: AgentProvider { id.provider }
    }

    static let anotherInstanceOwnsSocketMessage =
        "Another Relay instance is already listening for agent hooks. Quit it, then relaunch Relay."
    static let socketStartFailedMessage =
        "Relay could not open the agent hook socket. See Diagnostics for details."

    /// Only ever flipped by `start()`/`stop()`, called from the real app lifecycle.
    private(set) var isSocketListening = false
    /// Why the hook socket could not be opened, when the user can act on it. `nil` while
    /// listening, and before `start()` has run.
    private(set) var socketStatusMessage: String?
    /// Install-time status per provider; `status(for:)` merges it with the manager's runtime status.
    private(set) var installerStatuses: [AgentProvider: IntegrationStatus] = [:]

    /// Where `start()` opens the hook socket (`IntegrationServices.productionSocketPath` in the
    /// app, a temp path in tests). Shown in Integrations settings.
    @ObservationIgnored let socketPath: String
    @ObservationIgnored private let services: IntegrationServices
    @ObservationIgnored private let sessionRegistry: AgentSessionRegistry
    @ObservationIgnored private let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    @ObservationIgnored private let installerLogger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")

    init(runtime: RelayRuntime) {
        services = runtime.integrations
        socketPath = runtime.integrations.socketPath
        sessionRegistry = runtime.sessions.registry
        integrationDiagnosticsLog = runtime.integrationDiagnosticsLog
    }

    /// Whether an ephemeral latest agent response is available to speak.
    var latestResponseAvailable: Bool {
        services.integrationManager.latestResponse != nil
    }

    /// Called ONLY from `RelayAppDelegate.applicationDidFinishLaunching`; never from an
    /// initializer, so constructing the model in a test never opens a socket. A start failure
    /// never crashes: `.alreadyStarted` (a redundant call) is ignored; anything else is recorded
    /// in `integrationDiagnosticsLog` and surfaced through `socketStatusMessage`.
    /// `isSocketListening` is always read back from the receiver afterward. Then re-reads each
    /// provider's install status and refreshes the stable `RelayHook` helper when needed.
    func start() {
        do {
            try services.hookEnvelopeReceiver.start(path: socketPath)
            socketStatusMessage = nil
        } catch UnixSocketServerError.alreadyStarted {
            // A redundant call while the receiver already listens: nothing to report.
        } catch {
            let label = (error as? UnixSocketServerError)?.diagnosticsLabel ?? "unexpected-error"
            integrationDiagnosticsLog.append(stage: "socket-start", outcome: "failed", detail: label)
            socketStatusMessage = Self.socketStartFailureMessage(for: error)
        }
        isSocketListening = services.hookEnvelopeReceiver.isListening
        services.integrationManager.start()
        refreshInstalledHelperIfNeeded()
    }

    /// Called ONLY from `RelayAppDelegate.applicationWillTerminate`.
    func stop() {
        services.integrationManager.stop()
        services.hookEnvelopeReceiver.stop()
        isSocketListening = false
    }

    /// The manager's live `.active` status when present, else the last install-time status.
    func status(for provider: AgentProvider) -> IntegrationStatus {
        if let runtimeStatus = services.integrationManager.status[provider], case .active = runtimeStatus {
            return runtimeStatus
        }
        return installerStatuses[provider] ?? .notInstalled
    }

    /// Refreshes the stable helper first; the config is never written pointing at nothing runnable.
    func install(_ provider: AgentProvider) {
        do {
            try installBundledHelperIfPresent()
            switch provider {
            case .claudeCode: try services.claudeCodeInstaller.install()
            case .codex: try services.codexInstaller.install()
            }
            check(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Also clears the provider's runtime status so a stale `.active` can't outlive the uninstall.
    func uninstall(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: try services.claudeCodeInstaller.uninstall()
            case .codex: try services.codexInstaller.uninstall()
            }
            services.integrationManager.clearRuntimeStatus(for: provider)
            check(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    func check(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: installerStatuses[provider] = try services.claudeCodeInstaller.status()
            case .codex: installerStatuses[provider] = try services.codexInstaller.status()
            }
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Most-recently-active first. Diagnostics display only; never persisted.
    func agentSessionSummaries() async -> [AgentSessionSummary] {
        await sessionRegistry.sessions().map {
            AgentSessionSummary(id: $0.id, cwd: $0.cwd, lastActivityAt: $0.lastActivityAt)
        }
    }

    // MARK: Private

    /// Keeps the stable-path `RelayHook` copy in step with the helper bundled in THIS build, but
    /// only when at least one provider's config points hooks at it. Never throws: a failure is
    /// recorded in `integrationDiagnosticsLog`, and a previously installed helper stays.
    private func refreshInstalledHelperIfNeeded() {
        for provider in AgentProvider.allCases {
            check(provider)
        }
        guard AgentProvider.allCases.contains(where: { Self.hooksInstalled(installerStatuses[$0]) }) else {
            return
        }
        do {
            try installBundledHelperIfPresent()
        } catch {
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refresh-failed", detail: "stable-helper-unavailable")
        }
    }

    private static func hooksInstalled(_ status: IntegrationStatus?) -> Bool {
        switch status {
        case .installedAwaitingFirstEvent, .installedTrustRequired, .active:
            true
        case .notInstalled, .configurationError, nil:
            false
        }
    }

    /// Copies the bundled helper to its stable path (no-op when this build ships none), then
    /// verifies something executable is there; throws `HelperInstallVerificationError` if not.
    private func installBundledHelperIfPresent() throws {
        let bundledHelperURL = services.bundledHelperURL
        guard FileManager.default.fileExists(atPath: bundledHelperURL.path) else { return }

        let fileManager = FileManager.default
        let installedHelperPath = services.helperInstaller.installedHelperURL.path
        let hadValidStableHelperBefore = fileManager.isExecutableFile(atPath: installedHelperPath)

        do {
            try services.helperInstaller.installBundledHelper(from: bundledHelperURL)
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refreshed", detail: "")
        } catch {
            if hadValidStableHelperBefore {
                installerLogger.log("bundled RelayHook helper refresh failed; a previously installed helper is still present")
            } else {
                installerLogger.log("bundled RelayHook helper refresh failed")
            }
            integrationDiagnosticsLog.append(
                stage: "helper",
                outcome: "refresh-failed",
                detail: hadValidStableHelperBefore ? "previous-helper-kept" : "copy-failed"
            )
        }

        guard fileManager.isExecutableFile(atPath: installedHelperPath) else {
            installerLogger.log("stable RelayHook helper unavailable after refresh; aborting hook install")
            throw HelperInstallVerificationError.stableHelperUnavailable
        }
    }

    private static func socketStartFailureMessage(for error: Error) -> String {
        if case UnixSocketServerError.activeListenerPresent = error {
            return anotherInstanceOwnsSocketMessage
        }
        return socketStartFailedMessage
    }

    /// Never includes the underlying error's text (it may carry paths or content).
    private static func configurationErrorStatus(for provider: AgentProvider, error: Error) -> IntegrationStatus {
        if provider == .codex, case IntegrationInstallerError.hooksDisabledInConfig = error {
            return .configurationError(CodexInstaller.hooksDisabledMessage)
        }
        switch provider {
        case .claudeCode: return .configurationError("Could not update the Claude Code integration.")
        case .codex: return .configurationError("Could not update the Codex integration.")
        }
    }
}
```
Every method body above is verbatim from `AppModel.swift@6d14400` (848–1079, with `hookSocketPath` → `socketPath`, the stored services → `services.*`, and `checkIntegration`/`installIntegration`/`uninstallIntegration` → `check`/`install`/`uninstall`); `HelperInstallVerificationError` moves from `AppModel.swift` 5–12. Only doc comments were shortened.

- [ ] **Step 4: Trim `AppModel`.** Delete `HelperInstallVerificationError`, `isSocketListening`, `socketStatusMessage`, `installerStatuses`, `installerLogger`, `integrationSocketPath`, `hookSocketPath`, `anotherInstanceOwnsSocketMessage`, `socketStartFailedMessage`, `socketStartFailureMessage(for:)`, `startIntegrations`, `stopIntegrations`, `refreshInstalledHelperIfNeeded`, `hooksInstalled(_:)`, `integrationStatus(for:)`, `latestAgentResponseAvailable`, `installIntegration`, `installBundledHelperIfPresent`, `uninstallIntegration`, `checkIntegration`, `configurationErrorStatus`, `AgentSessionSummary`, `agentSessionSummaries`, and the now-unused `hookEnvelopeReceiver`/`claudeCodeInstaller`/`codexInstaller`/`helperInstaller`/`bundledHelperURL` computed accessors. Keep `speakLatestAgentResponse()` (moves in Task 7) and `integrationDiagnosticsEntries()` (DiagnosticsView). Add the stored sub-model and build it in `init` right after `self.runtime = runtime`:
```swift
    @ObservationIgnored let integrationSetup: IntegrationSetupModel
```
```swift
        integrationSetup = IntegrationSetupModel(runtime: runtime)
```

- [ ] **Step 5: Update call sites.**
`RelayApp.swift`: `model.startIntegrations()` → `model.integrationSetup.start()`; `model.stopIntegrations()` → `model.integrationSetup.stop()`.
`MenuBarContentView.swift`: `.disabled(!model.latestAgentResponseAvailable)` → `.disabled(!model.integrationSetup.latestResponseAvailable)`.
`IntegrationsSettingsView.swift`:
```bash
sed -i '' \
  -e 's/\[AppModel\.AgentSessionSummary\]/[IntegrationSetupModel.AgentSessionSummary]/' \
  -e 's/model\.isSocketListening/model.integrationSetup.isSocketListening/g' \
  -e 's/model\.hookSocketPath/model.integrationSetup.socketPath/g' \
  -e 's/model\.socketStatusMessage/model.integrationSetup.socketStatusMessage/g' \
  -e 's/model\.agentSessionSummaries()/model.integrationSetup.agentSessionSummaries()/g' \
  -e 's/model\.checkIntegration(/model.integrationSetup.check(/g' \
  -e 's/model\.installIntegration(/model.integrationSetup.install(/g' \
  -e 's/model\.uninstallIntegration(/model.integrationSetup.uninstall(/g' \
  -e 's/model\.integrationStatus(for:/model.integrationSetup.status(for:/g' \
  Relay/App/Settings/IntegrationsSettingsView.swift
grep -rn "integrationSocketPath\|model\.hookSocketPath\|startIntegrations\|stopIntegrations" Relay RelayTests
```
Expected: the final grep prints nothing.

- [ ] **Step 6: Run the moved suite, then the full suite**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/IntegrationSetupModelTests -only-testing:RelayTests/RelayPathsTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **` (includes plan 1's socket-ownership and helper-refresh tests). Then the full suite: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**
```bash
git add Relay/App/IntegrationSetupModel.swift Relay/App/AppModel.swift Relay/App/RelayApp.swift \
  Relay/App/Settings/IntegrationsSettingsView.swift Relay/App/MenuBarContentView.swift \
  RelayTests/App/IntegrationSetupModelTests.swift RelayTests/App/AppModelIntegrationsTests.swift \
  RelayTests/Shared/RelayPathsTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(app): extract IntegrationSetupModel from AppModel"
```

---

## Task 3: `SettingsController` with an actor-safe `Mutex` snapshot

**Findings:**
- Settings are held twice: `AppModel.settings` and `SettingsBox.value` (`RelayRuntime.swift` ~9–16), kept in sync by hand in `updateSettings`.
- Whisper selection needs two more boxes (`WhisperSelectionCache` ~67–86, `WhisperSelectionWriterBox` ~102–115) plus post-init re-pointing in `AppModel.init` — only because `SettingsBox` is `@MainActor` and `WhisperBackend` reads selection from its own actor.
- `AgentAutoReadCoordinator` hops to the main actor just to read one Bool.
- `setSpeechRate` JSON-encodes and writes `UserDefaults` on **every slider tick**.
- Whisper selection persistence has no test.

**Fix:** `SettingsSnapshot` wraps `Mutex<AppSettings>` (`Synchronization`) — readable from any actor, synchronously. `SettingsController` (on `RelayRuntime`, created first in `makeProduction()`) is the sole writer; its observable `current` is a computed view over the snapshot, so there is exactly **one** copy. Hotkey changes notify via `onHotkeysChanged`. Speech-rate writes apply immediately but persist once (debounced, and flushed when the slider drag ends or the app quits). Whisper's read/write seam is two computed closures on the controller.

**Files:**
- Create: `Relay/App/SettingsController.swift`, `RelayTests/App/SettingsControllerTests.swift`
- Modify: `Relay/App/RelayRuntime.swift`, `Relay/App/AppModel.swift`, `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/TTSBackendCatalog.swift`, `Relay/App/RelayApp.swift`, `Relay/Backends/Whisper/WhisperModelManager.swift` (doc comment only), views `GeneralSettingsView`, `DictationSettingsView`, `KeybindsSettingsView`, `IntegrationsSettingsView`, `TTSSettingsView`, `MenuBarContentView`
- Modify tests: `RelayTests/Support/RelayRuntime+Testing.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/AppModelHotkeySideEffectTests.swift`, `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1: Write the failing tests** — `RelayTests/App/SettingsControllerTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class SettingsControllerTests: XCTestCase {
    private func makeController(
        store: SpySettingsStore = SpySettingsStore(),
        statusSink: StatusSink = StatusSink(),
        saveDelay: Duration = .seconds(60)
    ) -> SettingsController {
        SettingsController(store: store, statusSink: statusSink, saveDelay: saveDelay)
    }

    func testLoadsFromStoreAndExposesOneValueThroughCurrentAndSnapshot() {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        let controller = makeController(store: SpySettingsStore(settings: saved))

        XCTAssertEqual(controller.current.dictationMode, .toggle)
        XCTAssertEqual(controller.snapshot.value, controller.current)
    }

    func testSnapshotIsReadableOffTheMainActor() async {
        let controller = makeController()
        controller.setAutoReadEnabled(false)
        let snapshot = controller.snapshot

        let autoRead = await Task.detached { snapshot.value.autoReadEnabled }.value

        XCTAssertFalse(autoRead)
    }

    func testToggleAutoReadPersistsAndAnnounces() {
        let store = SpySettingsStore()
        let statusSink = StatusSink()
        let controller = makeController(store: store, statusSink: statusSink)

        controller.toggleAutoRead()
        XCTAssertFalse(controller.current.autoReadEnabled)
        XCTAssertEqual(statusSink.message, "Auto-read disabled")

        controller.toggleAutoRead()
        XCTAssertTrue(controller.current.autoReadEnabled)
        XCTAssertEqual(statusSink.message, "Auto-read enabled")
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false, true])
    }

    func testSetAutoReadEnabledToCurrentValueIsANoOp() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setAutoReadEnabled(true)

        XCTAssertTrue(store.saved.isEmpty)
    }

    func testConflictingHotkeyIsRejectedWithActionableMessage() {
        let store = SpySettingsStore()
        let statusSink = StatusSink()
        let controller = makeController(store: store, statusSink: statusSink)
        let notified = HotkeyChangeRecorder()
        controller.onHotkeysChanged = { notified.values.append($0) }
        let existing = try! XCTUnwrap(controller.current.hotkeys[.replayLast])

        controller.setHotkey(existing, for: .readSelection)

        let expected = "Read Selection conflicts with Replay Last. Choose a different shortcut."
        XCTAssertEqual(controller.hotkeyConflictMessage, expected)
        XCTAssertEqual(statusSink.message, expected)
        XCTAssertEqual(controller.current, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(notified.values.isEmpty)
    }

    func testHotkeyChangeNotifiesOnlyWhenDefinitionsChange() {
        let controller = makeController()
        let notified = HotkeyChangeRecorder()
        controller.onHotkeysChanged = { notified.values.append($0) }
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        controller.setDictationMode(.toggle)
        controller.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(notified.values.count, 1)
        XCTAssertEqual(notified.values.first?[.readSelection], replacement)
    }

    func testRemoveHotkeyClearsConflictMessage() {
        let controller = makeController()
        let existing = try! XCTUnwrap(controller.current.hotkeys[.replayLast])
        controller.setHotkey(existing, for: .readSelection)
        XCTAssertNotNil(controller.hotkeyConflictMessage)

        controller.removeHotkey(for: .readSelection)

        XCTAssertNil(controller.hotkeyConflictMessage)
        XCTAssertNil(controller.current.hotkeys[.readSelection])
    }

    func testSaveFailureStillAppliesChangeAndSurfacesError() {
        let statusSink = StatusSink()
        let controller = makeController(
            store: SpySettingsStore(saveError: NSError(domain: "test", code: 1)),
            statusSink: statusSink
        )

        controller.setDictationMode(.toggle)

        XCTAssertEqual(controller.current.dictationMode, .toggle)
        XCTAssertTrue(statusSink.message.contains("Could not save settings"))
    }

    // MARK: Speech rate debounce

    func testSpeechRateAppliesImmediatelyButPersistsOnceWhenFlushed() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        for rate: Float in [0.55, 0.6, 0.65, 0.7] { controller.setSpeechRate(rate) }

        XCTAssertEqual(controller.current.ttsRate, 0.7, accuracy: 0.0001)
        XCTAssertEqual(controller.snapshot.value.ttsRate, 0.7, accuracy: 0.0001)
        XCTAssertTrue(store.saved.isEmpty, "slider ticks must not write UserDefaults")

        controller.flushPendingSave()
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.7, accuracy: 0.0001)

        controller.flushPendingSave()
        XCTAssertEqual(store.saved.count, 1, "nothing pending, nothing written")
    }

    func testDebouncedSpeechRateSavesAfterTheDelay() async {
        let store = SpySettingsStore()
        let controller = makeController(store: store, saveDelay: .milliseconds(10))

        controller.setSpeechRate(0.8)

        let deadline = Date().addingTimeInterval(2)
        while store.saved.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.8, accuracy: 0.0001)
    }

    func testAnImmediateWriteAlsoPersistsThePendingRate() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setSpeechRate(0.8)
        controller.setDictationMode(.toggle)
        controller.flushPendingSave()

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(store.saved.last?.dictationMode, .toggle)
    }

    // MARK: Whisper selection seam (previously untested)

    func testWhisperSelectionIsSeededFromPersistedSettings() {
        var saved = AppSettings.defaults
        saved.selectedSpeechModelByBackend["whisper"] = "base.en"
        let controller = makeController(store: SpySettingsStore(settings: saved))

        XCTAssertEqual(controller.whisperSelection(), .baseEn)
    }

    func testWhisperSelectionWriterPersistsAndIsVisibleFromAnyActor() async {
        let store = SpySettingsStore()
        let controller = makeController(store: store)
        let read = controller.whisperSelection
        let write = controller.whisperSelectionWriter

        write(.smallEn)

        XCTAssertEqual(controller.current.selectedSpeechModelByBackend["whisper"], "small.en")
        XCTAssertEqual(store.saved.last?.selectedSpeechModelByBackend["whisper"], "small.en")
        let seenOffMain = await Task.detached { read() }.value
        XCTAssertEqual(seenOffMain, .smallEn)

        write(nil)

        XCTAssertNil(controller.current.selectedSpeechModelByBackend["whisper"])
        XCTAssertNil(read())
    }

    func testUnknownPersistedWhisperIDReadsAsNoSelection() {
        var saved = AppSettings.defaults
        saved.selectedSpeechModelByBackend["whisper"] = "not-a-model"
        let controller = makeController(store: SpySettingsStore(settings: saved))

        XCTAssertNil(controller.whisperSelection())
    }
}

/// Collects `onHotkeysChanged` calls. A class, so the escaping `@MainActor` closure mutates a
/// reference instead of a captured local `var`.
@MainActor
private final class HotkeyChangeRecorder {
    var values: [[HotkeyAction: HotkeyDefinition]] = []
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/SettingsControllerTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'SettingsController' in scope`.

- [ ] **Step 3: Implement** — `Relay/App/SettingsController.swift`:

```swift
import Foundation
import Observation
import Synchronization

/// The one copy of the current `AppSettings`, lock-protected so any actor can read it
/// synchronously (the TTS/STT routers, `WhisperBackend`'s own actor, `AgentAutoReadCoordinator`).
/// Only `SettingsController` writes it.
final class SettingsSnapshot: Sendable {
    private let storage: Mutex<AppSettings>

    init(_ initial: AppSettings) {
        storage = Mutex(initial)
    }

    var value: AppSettings {
        storage.withLock { $0 }
    }

    fileprivate func replace(_ newValue: AppSettings) {
        storage.withLock { $0 = newValue }
    }
}

/// Relay's sole settings writer: typed setters, hotkey conflict validation, persistence, and the
/// Whisper selection seam. `current` is an Observation-tracked view over `snapshot` — there is no
/// second copy to keep in sync.
@MainActor
@Observable
final class SettingsController {
    /// How long a speech-rate change waits before it is written to disk.
    static let speechRateSaveDelay: Duration = .milliseconds(400)

    private(set) var hotkeyConflictMessage: String?

    @ObservationIgnored let snapshot: SettingsSnapshot
    /// Called after a write that changed the hotkey DEFINITIONS (and only then), so the hotkey
    /// matcher is rebuilt only when it has to be.
    @ObservationIgnored var onHotkeysChanged: (@MainActor ([HotkeyAction: HotkeyDefinition]) -> Void)?
    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(
        store: any SettingsStoring,
        statusSink: StatusSink,
        saveDelay: Duration = SettingsController.speechRateSaveDelay
    ) {
        self.store = store
        self.statusSink = statusSink
        self.saveDelay = saveDelay
        snapshot = SettingsSnapshot(store.load())
    }

    var current: AppSettings {
        access(keyPath: \.current)
        return snapshot.value
    }

    // MARK: Writes

    /// Applies `change` and persists immediately (also persisting any pending debounced change).
    func update(_ change: (inout AppSettings) -> Void) {
        apply(change)
        save()
    }

    func setHotkey(_ definition: HotkeyDefinition, for action: HotkeyAction) {
        let hotkeys = current.hotkeys
        if let conflictingAction = HotkeyAction.allCases.first(where: {
            guard $0 != action, let existing = hotkeys[$0] else { return false }
            return definition.conflicts(with: existing)
        }) {
            let message = "\(action.title) conflicts with \(conflictingAction.title). Choose a different shortcut."
            hotkeyConflictMessage = message
            statusSink.post(message)
            return
        }
        hotkeyConflictMessage = nil
        update { $0.hotkeys[action] = definition }
    }

    func removeHotkey(for action: HotkeyAction) {
        hotkeyConflictMessage = nil
        update { $0.hotkeys[action] = nil }
    }

    func setDictationMode(_ mode: DictationMode) { update { $0.dictationMode = mode } }
    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) { update { $0.activityOverlayStyle = style } }
    func setLiveTranscriptionEnabled(_ enabled: Bool) { update { $0.liveTranscriptionEnabled = enabled } }
    func setSTTBackendOrder(_ order: [String]) { update { $0.sttBackendOrder = order } }
    func setTTSBackendOrder(_ order: [String]) { update { $0.ttsBackendOrder = order } }
    func setVoiceIdentifier(_ identifier: String?) { update { $0.ttsVoiceIdentifier = identifier } }
    func setKokoroVoice(_ voice: String?) { update { $0.kokoroVoice = voice } }
    func setPocketVoice(_ voice: String?) { update { $0.pocketVoice = voice } }

    func setSelectedSpeechModel(backendID: String, modelID: String?) {
        update { $0.selectedSpeechModelByBackend[backendID] = modelID }
    }

    /// No-op when unchanged, so re-toggling the same control doesn't spam the status line.
    func setAutoReadEnabled(_ enabled: Bool) {
        guard enabled != current.autoReadEnabled else { return }
        update { $0.autoReadEnabled = enabled }
        statusSink.post(enabled ? "Auto-read enabled" : "Auto-read disabled")
    }

    func toggleAutoRead() {
        setAutoReadEnabled(!current.autoReadEnabled)
    }

    /// Applies immediately (so the next utterance uses it) but persists once after the slider
    /// settles, instead of JSON-encoding and writing on every drag tick.
    func setSpeechRate(_ rate: Float) {
        apply { $0.ttsRate = rate }
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Writes a pending debounced change now. Called when the rate slider's drag ends and when the
    /// app terminates. No-op when nothing is pending.
    func flushPendingSave() {
        guard pendingSave != nil else { return }
        save()
    }

    // MARK: Whisper selection seam

    /// Synchronous, actor-agnostic read of Whisper's selected model (for `WhisperBackend` and
    /// `WhisperModelManager`).
    var whisperSelection: WhisperModelSelection {
        let snapshot = snapshot
        return {
            snapshot.value.selectedSpeechModelByBackend["whisper"].flatMap(WhisperModelID.init(rawValue:))
        }
    }

    /// Write half of the seam: persists through this controller like every other setting.
    var whisperSelectionWriter: WhisperModelSelectionWriter {
        { [weak self] modelID in
            self?.setSelectedSpeechModel(backendID: "whisper", modelID: modelID?.rawValue)
        }
    }

    // MARK: Private

    private func apply(_ change: (inout AppSettings) -> Void) {
        let previous = snapshot.value
        var next = previous
        change(&next)
        withMutation(keyPath: \.current) { snapshot.replace(next) }
        if next.hotkeys != previous.hotkeys {
            onHotkeysChanged?(next.hotkeys)
        }
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try store.save(snapshot.value)
        } catch {
            statusSink.post("Could not save settings: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/SettingsControllerTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Rewire `RelayRuntime`.**
1. Delete `SettingsBox`, `WhisperSelectionCache`, `WhisperSelectionWriterBox` and their doc comments.
2. `SpeechInputServices`: delete `whisperSelectionWriter`.
3. `RelayRuntime`: replace stored `settingsStore`, `settings`, `settingsBox` (and the matching init params/assignments) with `let settingsController: SettingsController`.
4. `makeProduction()` opening lines become:
```swift
        let status = StatusSink()
        let diagnostics = DiagnosticsRecorder()
        let settingsController = SettingsController(
            store: SettingsStore(diagnostics: diagnostics),
            statusSink: status
        )
        let settings = settingsController.snapshot
        let overlayModel = ActivityOverlayModel()
        let graph = SpeechBackendGraph.make(
            whisperSelection: settingsController.whisperSelection,
            setWhisperSelection: settingsController.whisperSelectionWriter
        )
```
   Delete the cache/writer-box lines from Task 1. Replace every `settingsBox.value` with `settings.value`:
   - `TTSRouter(... backendOrder: { settings.value.ttsBackendOrder } ...)`
   - `SpeechCoordinator` options: `settings.value.ttsVoiceIdentifier` / `.ttsRate` / `.kokoroVoice` / `.pocketVoice`
   - `STTRouter` order: `let configured = settings.value.sttBackendOrder.filter { sttRegistry[$0] != nil }`
   - `autoReadEnabled: { settings.value.autoReadEnabled },` — delete the long MainActor-hop comment above it (no hop needed; the snapshot is lock-protected).
   - `liveTranscriptionEnabled: { settings.value.liveTranscriptionEnabled }`
5. Final `RelayRuntime(`: pass `settingsController: settingsController` instead of the three removed args; drop `whisperSelectionWriter:` from `SpeechInputServices(`.

- [ ] **Step 6: Update the test factory** (`RelayTests/Support/RelayRuntime+Testing.swift`): delete `let settings = settingsStore.load()`; in `RelayRuntime(` replace `settingsStore: settingsStore, settings: settings, settingsBox: SettingsBox(settings),` with
```swift
            settingsController: SettingsController(store: settingsStore, statusSink: status),
```
and drop `whisperSelectionWriter:` from `SpeechInputServices(`.

- [ ] **Step 7: Rewire `AppModel`.**
1. Delete: stored `settings`, `hotkeyConflictMessage`, the `settingsStore`/`settingsState` accessors, `setHotkey`, `removeHotkey`, `setDictationMode`, `setVoiceIdentifier`, `setKokoroVoice`, `setPocketVoice`, `setSpeechRate`, `setLiveTranscriptionEnabled`, `updateSettings`, `setSTTBackendOrder`, `setTTSBackendOrder`, `setSelectedSpeechModel`, `toggleAutoRead`, `setAutoReadEnabled`, and the `whisperSelectionWriter.persist` wiring + `settings = runtime.settings` line in `init`.
2. Add:
```swift
    @ObservationIgnored let settingsController: SettingsController
    /// Read-only settings for views; writes go through `settingsController`.
    var settings: AppSettings { settingsController.current }
```
   In `init`, right after `self.runtime = runtime`: `settingsController = runtime.settingsController`, and before `registerHotkeys()`:
```swift
        settingsController.onHotkeysChanged = { [weak self] _ in self?.registerHotkeys() }
```
3. `selectVoice` switch calls `settingsController.setVoiceIdentifier/ setKokoroVoice/ setPocketVoice`.
4. `setActivityOverlayStyle`:
```swift
    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
        settingsController.setActivityOverlayStyle(style)
        overlayPresenter.update(state: overlayModel.state, style: style)
    }
```
5. `bindOverlayPresenter`: `style: settingsState.value.activityOverlayStyle` → `style: settingsController.current.activityOverlayStyle`.
6. `handleHotkey`: `settings.dictationMode` stays (facade getter); `.toggleAutoRead` case → `settingsController.toggleAutoRead()`.
7. `registerHotkeys()` keeps `hotkeyManager.register(settings: settings)` (facade getter).

- [ ] **Step 8: Catalog adapters.** `SpeechBackendCatalog.swift`: `setSTTBackendOrder(order)` → `settingsController.setSTTBackendOrder(order)`. `TTSBackendCatalog.swift`: `setTTSBackendOrder(order)` → `settingsController.setTTSBackendOrder(order)`.

- [ ] **Step 9: Views and app delegate.**
```bash
sed -i '' 's/model\.setLiveTranscriptionEnabled(/model.settingsController.setLiveTranscriptionEnabled(/' Relay/App/Settings/GeneralSettingsView.swift
sed -i '' 's/model\.setDictationMode(/model.settingsController.setDictationMode(/' Relay/App/Settings/DictationSettingsView.swift
sed -i '' -e 's/model\.setHotkey(/model.settingsController.setHotkey(/' \
          -e 's/model\.removeHotkey(/model.settingsController.removeHotkey(/' \
          -e 's/model\.hotkeyConflictMessage/model.settingsController.hotkeyConflictMessage/' \
          Relay/App/Settings/KeybindsSettingsView.swift
sed -i '' 's/model\.setAutoReadEnabled(/model.settingsController.setAutoReadEnabled(/' Relay/App/Settings/IntegrationsSettingsView.swift
sed -i '' 's/model\.toggleAutoRead()/model.settingsController.toggleAutoRead()/' Relay/App/MenuBarContentView.swift
```
`TTSSettingsView.swift` — replace the rate `Slider` (lines 30–33: `Slider(value: Binding(get: { Double(model.settings.ttsRate) }, set: { model.setSpeechRate(Float($0)) }), in: 0.1...1.0, step: 0.05)`) with (flushes when the drag ends):
```swift
                    Slider(
                        value: Binding(
                            get: { Double(model.settings.ttsRate) },
                            set: { model.settingsController.setSpeechRate(Float($0)) }
                        ),
                        in: 0.1...1.0,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing { model.settingsController.flushPendingSave() }
                        }
                    )
```
`RelayApp.swift` `applicationWillTerminate`:
```swift
    func applicationWillTerminate(_ notification: Notification) {
        model.settingsController.flushPendingSave()
        model.integrationSetup.stop()
    }
```
`WhisperModelManager.swift`: in the `WhisperModelSelectionWriter` doc comment replace the `AppModel.setSelectedSpeechModel` / `AppModel.updateSettings` / `SettingsBox` references with: `production's writer is SettingsController.whisperSelectionWriter, so the write persists through Relay's single settings writer.`

- [ ] **Step 10: Retarget existing tests.**
```bash
sed -i '' \
  -e 's/model\.setHotkey(/model.settingsController.setHotkey(/g' \
  -e 's/model\.removeHotkey(/model.settingsController.removeHotkey(/g' \
  -e 's/model\.setDictationMode(/model.settingsController.setDictationMode(/g' \
  -e 's/model\.toggleAutoRead()/model.settingsController.toggleAutoRead()/g' \
  -e 's/model\.hotkeyConflictMessage/model.settingsController.hotkeyConflictMessage/g' \
  RelayTests/App/AppModelTests.swift
sed -i '' \
  -e 's/model\.setVoiceIdentifier(/model.settingsController.setVoiceIdentifier(/g' \
  -e 's/model\.setHotkey(/model.settingsController.setHotkey(/g' \
  -e 's/model\.setSpeechRate(/model.settingsController.setSpeechRate(/g' \
  RelayTests/App/AppModelHotkeySideEffectTests.swift
sed -i '' 's/model\.toggleAutoRead()/model.settingsController.toggleAutoRead()/g' RelayTests/App/SettingsViewsSmokeTests.swift
```
Delete from `AppModelTests.swift` the tests now covered by `SettingsControllerTests`: `testToggleAutoReadMethodTogglesSettingAndStatusText`, `testDuplicateHotkeyRejectionSurfacesActionableConflictMessage`, `testRemoveHotkeyClearsAnExistingConflictMessage`. Keep every test that asserts `hotkeys.registrations` (settings→hotkey wiring lives in `AppModel` until Task 8).

- [ ] **Step 11: Verify the boxes are gone**

Run: `grep -rn "SettingsBox\|WhisperSelectionCache\|WhisperSelectionWriterBox\|settingsBox\|setStatusHandler" Relay RelayTests`
Expected: no output.

- [ ] **Step 12: Full suite**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 13: Commit**
```bash
git add Relay/App/SettingsController.swift Relay/App/RelayRuntime.swift Relay/App/AppModel.swift \
  Relay/App/SpeechBackendCatalog.swift Relay/App/TTSBackendCatalog.swift Relay/App/RelayApp.swift \
  Relay/Backends/Whisper/WhisperModelManager.swift Relay/App/MenuBarContentView.swift \
  Relay/App/Settings/GeneralSettingsView.swift Relay/App/Settings/DictationSettingsView.swift \
  Relay/App/Settings/KeybindsSettingsView.swift Relay/App/Settings/IntegrationsSettingsView.swift \
  Relay/App/Settings/TTSSettingsView.swift RelayTests/App/SettingsControllerTests.swift \
  RelayTests/Support/RelayRuntime+Testing.swift RelayTests/App/AppModelTests.swift \
  RelayTests/App/AppModelHotkeySideEffectTests.swift RelayTests/App/SettingsViewsSmokeTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): make SettingsController the single owner with a Mutex snapshot"
```

---

## Task 4: `BackendID`

**Findings:** Backend id literals (`"kokoro"`, `"pocket-tts"`, `"apple-tts"`, `"whisper"`, `"parakeet"`, `"apple-speech"`) are scattered across `AppSettings.swift`, `SpeechVoiceCatalog.swift`, `AppModel.swift`, `SettingsController.swift`, `RelayRuntime.swift`, `SpeechModelController.swift` ~175–185, `Diagnostics.swift` ~27–33 and every backend/manager. Display names live in three places (backends, `SpeechModelController.displayName`, `DiagnosticsEvent.speechBackendDisplayName`), and the diagnostics copy only knows Parakeet/Apple Speech, so a Kokoro download logs **"Speech recognition model download started"**.

**Fix:** `BackendID` — a `RawRepresentable` struct with static members and one canonical `displayName` (the backends' existing row names). Diagnostics events carry the display name. On-disk strings stay byte-identical. *Copy change (intended, part of the fix):* Whisper model messages now say "OpenAI Whisper model …" (the backend's row name) instead of "Whisper model …".

**Files:**
- Create: `Relay/Domain/BackendID.swift`, `RelayTests/Domain/BackendIDTests.swift`
- Modify: `Relay/Domain/AppSettings.swift`, `Relay/System/Diagnostics.swift`, `Relay/App/SpeechModelController.swift`, `Relay/App/SpeechVoiceCatalog.swift`, `Relay/App/AppModel.swift`, `Relay/App/SettingsController.swift`, `Relay/App/RelayRuntime.swift`, backends: `Relay/Backends/{AppleSpeechBackend,AppleSpeechModelManager,ParakeetBackend,ParakeetModelManager,KokoroTTSBackend,KokoroModelManager,PocketTTSBackend,PocketTTSModelManager}.swift`, `Relay/Backends/Whisper/{WhisperBackend,WhisperModelManager}.swift`, `Relay/SpeechOut/AppleTTSBackend.swift`
- Modify tests: `RelayTests/System/DiagnosticsTests.swift`, `RelayTests/App/SpeechModelControllerTests.swift`

- [ ] **Step 1: Write the failing tests** — `RelayTests/Domain/BackendIDTests.swift`:

```swift
import XCTest
@testable import Relay

final class BackendIDTests: XCTestCase {
    /// These strings are persisted in `AppSettings` (backend orders, voice/model maps) and must
    /// never change.
    func testRawValuesMatchPersistedStrings() {
        XCTAssertEqual(BackendID.appleSpeech.rawValue, "apple-speech")
        XCTAssertEqual(BackendID.parakeet.rawValue, "parakeet")
        XCTAssertEqual(BackendID.whisper.rawValue, "whisper")
        XCTAssertEqual(BackendID.pocketTTS.rawValue, "pocket-tts")
        XCTAssertEqual(BackendID.appleTTS.rawValue, "apple-tts")
        XCTAssertEqual(BackendID.kokoro.rawValue, "kokoro")
    }

    func testDisplayNamesAreCanonicalAndUnknownIDsFallBackToRawValue() {
        XCTAssertEqual(BackendID.appleSpeech.displayName, "Apple Speech")
        XCTAssertEqual(BackendID.parakeet.displayName, "Parakeet")
        XCTAssertEqual(BackendID.whisper.displayName, "OpenAI Whisper")
        XCTAssertEqual(BackendID.pocketTTS.displayName, "PocketTTS")
        XCTAssertEqual(BackendID.appleTTS.displayName, "Apple System Voice")
        XCTAssertEqual(BackendID.kokoro.displayName, "Kokoro")
        XCTAssertEqual(BackendID.displayName(for: "future-backend"), "future-backend")
    }

    func testPatternMatchesPlainStrings() {
        let id = "kokoro"
        switch id {
        case BackendID.kokoro: break
        default: XCTFail("BackendID must pattern-match its raw string")
        }
    }

    func testKnownIDSetsDeriveFromBackendID() {
        XCTAssertEqual(AppSettings.knownSTTBackendIDs, ["apple-speech", "parakeet", "whisper"])
        XCTAssertEqual(AppSettings.knownTTSBackendIDs, ["pocket-tts", "apple-tts", "kokoro"])
    }
}
```

In `RelayTests/System/DiagnosticsTests.swift` replace `testSpeechModelDownloadEventsUseFixedDisplayNameMessages` with:
```swift
    func testSpeechModelEventsRenderTheGivenBackendName() {
        var buffer = DiagnosticsBuffer()
        buffer.append(.speechModelDownloadStarted(backendName: "Kokoro"))
        buffer.append(.speechModelDownloadFinished(backendName: "Kokoro"))
        buffer.append(.speechModelDownloadFailed(backendName: "Parakeet"))

        XCTAssertEqual(
            buffer.copyText,
            "Kokoro model download started\nKokoro model download finished\nParakeet model download failed"
        )
    }
```
Append to `SpeechModelControllerTests`:
```swift
    /// Regression: TTS model downloads used to log "Speech recognition model download started".
    func testTextToSpeechDownloadDiagnosticsNameTheTTSBackend() async {
        let key = SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")
        let diagnostics = DiagnosticsRecorder()
        let controller = SpeechModelController(
            managers: [key: ControllerModelManager(statuses: [status("model")])],
            diagnostics: diagnostics
        )

        await controller.download("model", in: key)

        XCTAssertEqual(
            diagnostics.entries.map(\.event.message),
            ["Kokoro model download started", "Kokoro model download finished"]
        )
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BackendIDTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'BackendID' in scope`.

- [ ] **Step 3: Implement** — `Relay/Domain/BackendID.swift`:

```swift
/// A speech backend's stable identifier. `rawValue` is persisted in `AppSettings` (backend
/// orders, per-backend voice/model maps) and in registry keys, so the static members' strings must
/// never change. `displayName` is the single user-facing name for the backend everywhere (Settings
/// rows, error messages, diagnostics).
struct BackendID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    var description: String { rawValue }

    // Speech-to-text
    static let appleSpeech: BackendID = "apple-speech"
    static let parakeet: BackendID = "parakeet"
    static let whisper: BackendID = "whisper"
    // Text-to-speech
    static let pocketTTS: BackendID = "pocket-tts"
    static let appleTTS: BackendID = "apple-tts"
    static let kokoro: BackendID = "kokoro"

    static let allSpeechToText: [BackendID] = [.appleSpeech, .parakeet, .whisper]
    static let allTextToSpeech: [BackendID] = [.pocketTTS, .appleTTS, .kokoro]

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeet: "Parakeet"
        case .whisper: "OpenAI Whisper"
        case .pocketTTS: "PocketTTS"
        case .appleTTS: "Apple System Voice"
        case .kokoro: "Kokoro"
        default: rawValue
        }
    }

    static func displayName(for rawValue: String) -> String {
        BackendID(rawValue: rawValue).displayName
    }

    /// Lets `switch someString { case BackendID.kokoro: … }` match registry/settings strings.
    static func ~= (pattern: BackendID, value: String) -> Bool {
        pattern.rawValue == value
    }
}
```

- [ ] **Step 4: Replace literals.**
- `AppSettings.swift`:
```swift
    static let knownSTTBackendIDs: Set<String> = Set(BackendID.allSpeechToText.map(\.rawValue))
    static let knownTTSBackendIDs: Set<String> = Set(BackendID.allTextToSpeech.map(\.rawValue))
```
  and in `defaults`: `sttBackendOrder: [BackendID.appleSpeech.rawValue]`, `ttsBackendOrder: BackendID.allTextToSpeech.map(\.rawValue)` (same order: pocket-tts, apple-tts, kokoro).
- `Diagnostics.swift`: the seven `speechModel*` cases (`DownloadStarted`, `DownloadFinished`, `DownloadFailed`, `SelectionFinished`, `SelectionFailed`, `RemovalFinished`, `RemovalFailed`) take `backendName: String`; delete `speechBackendDisplayName`; each message becomes e.g. `case let .speechModelDownloadStarted(backendName): "\(backendName) model download started"`.
- `SpeechModelController.swift`: delete `displayName(for:)`; every `diagnostics.record(.speechModelX(backendID: backend.backendID))` → `diagnostics.record(.speechModelX(backendName: BackendID.displayName(for: backend.backendID)))`; every `"\(displayName(for: backend.backendID)) model …"` → `"\(BackendID.displayName(for: backend.backendID)) model …"`.
- `SpeechVoiceCatalog.swift`: every `case "apple-tts":` → `case BackendID.appleTTS:`, `"kokoro"` → `BackendID.kokoro`, `"pocket-tts"` → `BackendID.pocketTTS`.
- `AppModel.selectVoice`: same `case BackendID.…:` replacements.
- `SettingsController.swift`: both `"whisper"` literals → `BackendID.whisper.rawValue`.
- `RelayRuntime.swift`: `["apple-speech"]` fallback → `[BackendID.appleSpeech.rawValue]`.
- Backends/managers: `let id = "kokoro"` → `let id = BackendID.kokoro.rawValue`; `let displayName = "Kokoro"` → `let displayName = BackendID.kokoro.displayName`; `let backendID = "kokoro"` → `let backendID = BackendID.kokoro.rawValue` — likewise for AppleSpeech, Parakeet, PocketTTS, AppleTTS, and Whisper (`nonisolated let id = BackendID.whisper.rawValue`, `nonisolated let displayName = BackendID.whisper.displayName`).

- [ ] **Step 5: Verify no stray literals in app code**

Run: `grep -rn '"kokoro"\|"pocket-tts"\|"apple-tts"\|"whisper"\|"parakeet"\|"apple-speech"' Relay --include='*.swift' | grep -v "BackendID.swift\|Logger(subsystem" | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//'`
Expected: no output. (The last filter drops doc/line comments, which legitimately quote ids — e.g. `RelayRuntime.swift`'s ``["apple-speech"]`` note and `FluidAudioKokoroEngine.swift`'s `("kokoro")` directory note. Any remaining hit is code and must use `BackendID`.)

- [ ] **Step 6: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**
```bash
git add Relay/Domain/BackendID.swift Relay/Domain/AppSettings.swift Relay/System/Diagnostics.swift \
  Relay/App/SpeechModelController.swift Relay/App/SpeechVoiceCatalog.swift Relay/App/AppModel.swift \
  Relay/App/SettingsController.swift Relay/App/RelayRuntime.swift \
  Relay/Backends/AppleSpeechBackend.swift Relay/Backends/AppleSpeechModelManager.swift \
  Relay/Backends/ParakeetBackend.swift Relay/Backends/ParakeetModelManager.swift \
  Relay/Backends/KokoroTTSBackend.swift Relay/Backends/KokoroModelManager.swift \
  Relay/Backends/PocketTTSBackend.swift Relay/Backends/PocketTTSModelManager.swift \
  Relay/Backends/Whisper/WhisperBackend.swift Relay/Backends/Whisper/WhisperModelManager.swift \
  Relay/SpeechOut/AppleTTSBackend.swift RelayTests/Domain/BackendIDTests.swift \
  RelayTests/System/DiagnosticsTests.swift RelayTests/App/SpeechModelControllerTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "refactor(backends): introduce BackendID and name backends correctly in diagnostics"
```

---

## Task 5: `BackendListModel` (one class, two instances)

**Findings:** `SpeechBackendCatalog.swift` and `TTSBackendCatalog.swift` are line-for-line identical (61 lines each) except names, and add four stored properties each to `AppModel` (`sttBackends`/`speechBackendMessage`/`ttsBackends`/`ttsBackendMessage` ~59–62, `refreshGeneration`/`ttsRefreshGeneration` ~76–77). `BackendCatalog<Backend>` is generic only for `registry[id] != nil`. `BackendStatus.State.downloading/.downloadFailed` are never produced by `mapAvailability` (only rendered in `SpeechBackendSettingsSection.statusLabel` ~91–92).

**Fix:** One `@MainActor @Observable BackendListModel(entries:order:setOrder:refusalMessage:statusSink:)`, instantiated twice. Known ids are a `Set<String>`. Dead states removed. Both extension files, the generic, and the `STTBackendStatus`/`TTSBackendStatus` aliases deleted. The two test suites merge into one that tests the model directly with closures.

**Files:**
- Create: `Relay/App/BackendListModel.swift`, `RelayTests/App/BackendListModelTests.swift`
- Delete: `Relay/App/BackendCatalog.swift`, `Relay/App/SpeechBackendCatalog.swift`, `Relay/App/TTSBackendCatalog.swift`, `RelayTests/App/TTSBackendCatalogTests.swift`
- Modify: `Relay/App/AppModel.swift`, `Relay/App/Settings/SpeechBackendSettingsSection.swift`, `Relay/App/Settings/DictationSettingsView.swift`, `Relay/App/Settings/TTSSettingsView.swift`, `Relay/App/Settings/SettingsView.swift`, `RelayTests/App/AppModelTests.swift`

- [ ] **Step 1: Write the failing tests** — `RelayTests/App/BackendListModelTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class BackendListModelTests: XCTestCase {
    private var order: [String] = []
    private var writes: [[String]] = []
    private var statusSink = StatusSink()

    override func setUp() {
        super.setUp()
        order = []
        writes = []
        statusSink = StatusSink()
    }

    private func makeList(
        _ ids: [String],
        availability: [String: BackendAvailability] = [:],
        refusal: String = "At least one backend must stay enabled."
    ) -> BackendListModel {
        BackendListModel(
            entries: ids.map { id in
                BackendListEntry(id: id, displayName: id.uppercased(), availability: { availability[id] ?? .available })
            },
            order: { [unowned self] in order },
            setOrder: { [unowned self] in order = $0; writes.append($0) },
            refusalMessage: refusal,
            statusSink: statusSink
        )
    }

    func testRowsListEnabledInOrderThenDisabledByID() async {
        order = ["b", "a"]
        let list = makeList(["a", "b", "c"])

        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(list.rows.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(list.rows.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(list.rows.map(\.displayName), ["B", "A", "C"])
        XCTAssertEqual(list.rows.map(\.state), [.ready, .ready, .ready])
    }

    func testEnablingAppendsToOrderAndPersists() async {
        order = ["a"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.setEnabled("b", true)

        XCTAssertEqual(writes, [["a", "b"]])
        XCTAssertEqual(list.rows.first { $0.id == "b" }?.isEnabled, true)
        XCTAssertEqual(list.rows.first { $0.id == "b" }?.position, 1)
    }

    func testEnablingAlreadyEnabledOrUnknownIDIsANoOp() async {
        order = ["a"]
        let list = makeList(["a"])
        await list.refresh()

        list.setEnabled("a", true)
        list.setEnabled("ghost", true)

        XCTAssertTrue(writes.isEmpty)
    }

    func testMovingEnabledBackendReorders() async {
        order = ["a", "b"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.move("b", up: true)

        XCTAssertEqual(writes, [["b", "a"]])
        XCTAssertEqual(list.rows.map(\.id), ["b", "a"])
    }

    func testMovingPastEitherEndIsANoOp() async {
        order = ["a", "b"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.move("a", up: true)
        list.move("b", up: false)

        XCTAssertTrue(writes.isEmpty)
    }

    func testCannotDisableTheLastEnabledBackend() async {
        order = ["a"]
        let list = makeList(["a", "b"], refusal: "At least one TTS backend must stay enabled.")
        await list.refresh()

        list.setEnabled("a", false)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(list.message, "At least one TTS backend must stay enabled.")
        XCTAssertEqual(statusSink.message, "At least one TTS backend must stay enabled.")
    }

    func testMessageClearsOnNextSuccessfulChange() async {
        order = ["a"]
        let list = makeList(["a", "b"])
        await list.refresh()
        list.setEnabled("a", false)
        XCTAssertNotNil(list.message)

        list.setEnabled("b", true)

        XCTAssertNil(list.message)
    }

    func testUnknownIDsInSettingsOrderAreIgnoredAndDroppedOnPersist() async {
        order = ["ghost", "a"]
        let list = makeList(["a", "b"])
        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(list.rows.first { $0.id == "a" }?.position, 0)

        list.setEnabled("a", false)
        XCTAssertTrue(writes.isEmpty, "ghost must not count toward the last-enabled guard")

        list.setEnabled("b", true)
        XCTAssertEqual(writes, [["a", "b"]])
    }

    func testAvailabilityMapsToFixedStates() async {
        let cases: [(BackendAvailability, BackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedOS, .unsupported),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("reason"), .unavailable),
            (.failed("boom"), .unavailable),
        ]
        for (availability, expected) in cases {
            let list = makeList(["x"], availability: ["x": availability])
            await list.refresh()
            XCTAssertEqual(list.rows.first?.state, expected, "availability: \(availability)")
        }
    }

    func testStaleRefreshCannotOverwriteANewerOne() async {
        let gate = AvailabilityGate()
        let list = BackendListModel(
            entries: [BackendListEntry(id: "a", displayName: "A", availability: { await gate.next() })],
            order: { ["a"] },
            setOrder: { _ in },
            refusalMessage: "",
            statusSink: statusSink
        )

        let stale = Task { await list.refresh() }
        while gate.pending == nil { await Task.yield() }
        gate.value = .available
        await list.refresh()
        gate.pending?.resume()
        await stale.value

        XCTAssertEqual(list.rows.first?.state, .ready)
    }
}

/// First call suspends (returning the value captured at call time); later calls return `value`.
@MainActor
private final class AvailabilityGate {
    var value: BackendAvailability = .modelNotDownloaded
    var pending: CheckedContinuation<Void, Never>?
    private var calls = 0

    func next() async -> BackendAvailability {
        calls += 1
        let captured = value
        if calls == 1 { await withCheckedContinuation { pending = $0 } }
        return captured
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BackendListModelTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'BackendListModel' in scope`.

- [ ] **Step 3: Implement** — create `Relay/App/BackendListModel.swift`, then `git rm Relay/App/BackendCatalog.swift Relay/App/SpeechBackendCatalog.swift Relay/App/TTSBackendCatalog.swift`:

```swift
import Foundation
import Observation

/// One backend row in Settings: its place in the user's order and its live readiness. Labels
/// and icons live in the view layer.
struct BackendStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case modelNotDownloaded
        case unsupported
        case unavailable
    }

    let id: String
    let displayName: String
    var state: State
    var isEnabled: Bool
    var position: Int
}

/// What the list needs from a backend: identity, label, and a readiness probe. Lets one list type
/// serve both the `Sendable` STT backends and the `@MainActor` TTS backends.
struct BackendListEntry {
    let id: String
    let displayName: String
    let availability: @MainActor () async -> BackendAvailability
}

@MainActor
extension BackendListEntry {
    static func entries(_ registry: [String: any SpeechToTextBackend]) -> [BackendListEntry] {
        registry.map { id, backend in
            BackendListEntry(id: id, displayName: backend.displayName, availability: { await backend.availability() })
        }
    }

    static func entries(_ registry: [String: any TextToSpeechBackend]) -> [BackendListEntry] {
        registry.map { id, backend in
            BackendListEntry(id: id, displayName: backend.displayName, availability: { await backend.availability() })
        }
    }
}

/// The ordered, enable-able backend list for one speech domain (STT or TTS). Owns the visible rows,
/// the refusal message, and refresh race-safety; reads/writes the order through closures so the
/// settings owner stays the only writer. Model lifecycle state lives in `SpeechModelController`.
@MainActor
@Observable
final class BackendListModel {
    private(set) var rows: [BackendStatus] = []
    private(set) var message: String?

    @ObservationIgnored private let entries: [BackendListEntry]
    @ObservationIgnored private let knownIDs: Set<String>
    @ObservationIgnored private let readOrder: @MainActor () -> [String]
    @ObservationIgnored private let writeOrder: @MainActor ([String]) -> Void
    @ObservationIgnored private let refusalMessage: String
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var generation = 0

    init(
        entries: [BackendListEntry],
        order: @escaping @MainActor () -> [String],
        setOrder: @escaping @MainActor ([String]) -> Void,
        refusalMessage: String,
        statusSink: StatusSink
    ) {
        self.entries = entries.sorted { $0.id < $1.id }
        knownIDs = Set(entries.map(\.id))
        readOrder = order
        writeOrder = setOrder
        self.refusalMessage = refusalMessage
        self.statusSink = statusSink
    }

    /// Re-probes every backend. A refresh overtaken by a newer one discards its results.
    func refresh() async {
        generation += 1
        let current = generation
        let order = knownOrder()
        var fresh: [BackendStatus] = []
        for entry in entries {
            let availability = await entry.availability()
            fresh.append(BackendStatus(
                id: entry.id,
                displayName: entry.displayName,
                state: Self.state(for: availability),
                isEnabled: order.contains(entry.id),
                position: order.firstIndex(of: entry.id) ?? Int.max
            ))
        }
        guard current == generation else { return }
        rows = Self.sorted(fresh)
    }

    /// Refuses to disable the last enabled backend; unknown ids and no-op changes are ignored.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard knownIDs.contains(id) else { return }
        var order = knownOrder()
        if enabled {
            guard !order.contains(id) else { return }
            order.append(id)
        } else {
            guard order.contains(id) else { return }
            guard order.count > 1 else {
                setMessage(refusalMessage)
                return
            }
            order.removeAll { $0 == id }
        }
        apply(order)
    }

    func move(_ id: String, up: Bool) {
        var order = knownOrder()
        guard let index = order.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        apply(order)
    }

    static func state(for availability: BackendAvailability) -> BackendStatus.State {
        switch availability {
        case .available: .ready
        case .modelNotDownloaded: .modelNotDownloaded
        case .unsupportedOS, .unsupportedHardware: .unsupported
        case .permissionDenied, .unavailable, .failed: .unavailable
        }
    }

    private func apply(_ order: [String]) {
        writeOrder(order)
        rows = Self.sorted(rows.map { row in
            var row = row
            row.isEnabled = order.contains(row.id)
            row.position = order.firstIndex(of: row.id) ?? Int.max
            return row
        })
        setMessage(nil)
    }

    private func setMessage(_ newMessage: String?) {
        message = newMessage
        if let newMessage { statusSink.post(newMessage) }
    }

    /// The persisted order restricted to ids this list knows, so stale ids never count.
    private func knownOrder() -> [String] {
        readOrder().filter { knownIDs.contains($0) }
    }

    /// Enabled first (configured order), then disabled alphabetically by id.
    private static func sorted(_ statuses: [BackendStatus]) -> [BackendStatus] {
        statuses.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }
}
```

- [ ] **Step 4: Wire into `AppModel`.** Delete `sttBackends`, `speechBackendMessage`, `ttsBackends`, `ttsBackendMessage`, `refreshGeneration`, `ttsRefreshGeneration`. Add:
```swift
    @ObservationIgnored let sttBackendList: BackendListModel
    @ObservationIgnored let ttsBackendList: BackendListModel
```
In `init`, after `settingsController = runtime.settingsController`:
```swift
        let settings = runtime.settingsController
        sttBackendList = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechIn.sttRegistry),
            order: { settings.current.sttBackendOrder },
            setOrder: { settings.setSTTBackendOrder($0) },
            refusalMessage: "At least one speech recognition backend must stay enabled.",
            statusSink: runtime.status
        )
        ttsBackendList = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechOut.ttsRegistry),
            order: { settings.current.ttsBackendOrder },
            setOrder: { settings.setTTSBackendOrder($0) },
            refusalMessage: "At least one TTS backend must stay enabled.",
            statusSink: runtime.status
        )
```
Replace `refreshSpeechBackendStatuses()` → `sttBackendList.refresh()` and `refreshTTSBackendStatuses()` → `ttsBackendList.refresh()` in `configureModelController`, `recheckDiagnostics` and the two initial-refresh tasks. Delete the now-unused `sttRegistry`/`ttsRegistry` accessors.

- [ ] **Step 5: Views.**
`SpeechBackendSettingsSection.swift` — `statusLabel` drops the two dead cases:
```swift
    static func statusLabel(_ state: BackendStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .modelNotDownloaded: "Model not downloaded"
        case .unsupported: "Unsupported on this Mac"
        case .unavailable: "Unavailable"
        }
    }
```
`DictationSettingsView.swift`: `backends: model.sttBackendList.rows`, `message: model.modelController.messages[.dictation] ?? model.sttBackendList.message`, `setEnabled: model.sttBackendList.setEnabled`, `move: model.sttBackendList.move`.
`TTSSettingsView.swift`: same with `ttsBackendList` / `.textToSpeech`; `.task` first line → `await model.ttsBackendList.refresh()`.
`SettingsView.swift`: `.task { await model.sttBackendList.refresh() }` (Task 10 removes it).

- [ ] **Step 6: Tests.** `git rm RelayTests/App/TTSBackendCatalogTests.swift`. From `AppModelTests.swift` delete `testSpeechBackendStatusesDeriveFromSettingsOrderEnabledFirstThenDisabled`, `testEnablingBackendAppendsItToOrderAndPersists`, `testMovingEnabledBackendReordersSettings`, `testCannotDisableTheLastEnabledBackend`, `testUnknownIDsInSettingsOrderAreIgnoredAndDroppedWhenPersisted`, `testSpeechBackendMessageIsSetOnRefusalAndClearedOnNextSuccessfulAction`, `testRefreshMapsBackendAvailabilityCasesToFixedStates`, and add one wiring test (keeps `FakeSTTBackend`):
```swift
    func testBackendListsReadAndPersistOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, sttRegistry: [
            "a": FakeSTTBackend(id: "a", displayName: "A"),
            "b": FakeSTTBackend(id: "b", displayName: "B"),
        ])
        await model.initialSpeechBackendRefresh?.value

        model.sttBackendList.setEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
    }
```

Two comments name the deleted types and would trip Step 7's grep: in `Relay/Domain/AppSettings.swift` (~94–95, inside `init(from:)`) replace "`BackendCatalog.knownOrder` (the equivalent runtime-side filter in `Relay/App/BackendCatalog.swift`)" with "`BackendListModel.knownOrder()` (the equivalent runtime-side filter in `Relay/App/BackendListModel.swift`)"; in `RelayTests/App/SettingsViewsSmokeTests.swift` (~141) replace `STTBackendStatus.State` with `BackendStatus.State`. Add both files to the commit.

- [ ] **Step 7: Verify deletions**

Run: `grep -rn "BackendCatalog\|STTBackendStatus\|TTSBackendStatus\|refreshSpeechBackendStatuses\|refreshTTSBackendStatuses" Relay RelayTests`
Expected: no output.

- [ ] **Step 8: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**
```bash
git add Relay/App/BackendListModel.swift Relay/App/BackendCatalog.swift Relay/App/SpeechBackendCatalog.swift \
  Relay/App/TTSBackendCatalog.swift Relay/App/AppModel.swift \
  Relay/App/Settings/SpeechBackendSettingsSection.swift Relay/App/Settings/DictationSettingsView.swift \
  Relay/App/Settings/TTSSettingsView.swift Relay/App/Settings/SettingsView.swift \
  RelayTests/App/BackendListModelTests.swift RelayTests/App/TTSBackendCatalogTests.swift \
  RelayTests/App/AppModelTests.swift Relay/Domain/AppSettings.swift RelayTests/App/SettingsViewsSmokeTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): replace duplicated backend catalogs with one BackendListModel"
```

---

## Task 6: Voice selection map + schema v1→v2 migration

**Findings:** `AppSettings.ttsVoiceIdentifier`/`kokoroVoice`/`pocketVoice` + three setters + a `selectVoice` switch (`AppModel` ~418–438) + parallel switches in `SpeechVoiceCatalog.activeVoiceID`/`options(for:)`; `TTSOptions` construction duplicated (`RelayRuntime` options closure, `SpeechVoiceCatalog.options` ~106–111). Adding a TTS backend means touching all of them.

**Fix:** `AppSettings.voiceByBackend: [String: String]` (key = `BackendID.rawValue`). `currentSchemaVersion` becomes 2; `init(from:)` migrates the three legacy keys when the saved version is < 2 — the first real use of `schemaVersion` since plan 1 removed the no-op switch (plan 1's `currentSchemaVersion` doc already says: bump it and add an explicit transform when a field is reshaped). `TTSOptions.init(settings:)` is the one mapping from settings to options. One `SettingsController.setVoice(_:for:)`. `TTSOptions` itself keeps its three fields (backends read them; unchanged here).

*Downgrade note:* an older build reading a v2 blob falls back to default voices (per-field decode); no other field is affected.

**Files:**
- Modify: `Relay/Domain/AppSettings.swift`, `Relay/App/SettingsController.swift`, `Relay/App/SpeechVoiceCatalog.swift`, `Relay/App/AppModel.swift`, `Relay/App/RelayRuntime.swift`
- Modify tests: `RelayTests/Domain/AppSettingsTests.swift`, `RelayTests/Domain/AppSettingsDecodeTests.swift`, `RelayTests/App/SpeechVoiceCatalogTests.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/AppModelHotkeySideEffectTests.swift`, `RelayTests/App/SettingsControllerTests.swift`

- [ ] **Step 1: Write the failing tests.** In `AppSettingsTests.swift` delete `testDefaultsHaveNoKokoroVoiceConfigured`, `testKokoroVoiceRoundTrips`, `testDecodingPreKokoroSettingsDefaultsKokoroVoiceToNilWithoutResettingOtherFields`, `testDefaultsHaveNoPocketVoiceConfigured`, `testPocketVoiceRoundTrips`, `testDecodingPrePocketVoiceSettingsDefaultsPocketVoiceToNilWithoutResettingOtherFields`; in `testDefaultLiveTranscriptionIsOff` remove the `ttsVoiceIdentifier: nil,` argument; in `testDecodingPreOverlaySettingsAddsInteractiveWithoutResettingOtherFields` replace `saved.ttsVoiceIdentifier = "voice.test"` with `saved.voiceByBackend["apple-tts"] = "voice.test"` and `XCTAssertEqual(decoded.ttsVoiceIdentifier, "voice.test")` with `XCTAssertEqual(decoded.voiceByBackend["apple-tts"], "voice.test")`; in `testDefaultsUsePhaseOneBackendsAndExpectedHotkeys` replace `XCTAssertNil(AppSettings.defaults.ttsVoiceIdentifier)` with `XCTAssertTrue(AppSettings.defaults.voiceByBackend.isEmpty)`. Add:

```swift
    func testDefaultsHaveNoVoicesConfigured() {
        XCTAssertTrue(AppSettings.defaults.voiceByBackend.isEmpty)
        XCTAssertEqual(AppSettings.currentSchemaVersion, 2)
    }

    func testVoiceMapRoundTrips() throws {
        var value = AppSettings.defaults
        value.voiceByBackend = ["kokoro": "am_adam", "pocket-tts": "alba", "apple-tts": "com.apple.voice.x"]

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value))

        XCTAssertEqual(decoded.voiceByBackend, value.voiceByBackend)
    }

    /// A v1 blob stored one optional voice per backend under its own key.
    func testLegacyV1VoiceKeysMigrateIntoTheVoiceMap() throws {
        var object = try legacyV1Object()
        object["ttsVoiceIdentifier"] = "com.apple.voice.x"
        object["kokoroVoice"] = "am_adam"
        object["pocketVoice"] = "alba"
        object["dictationMode"] = "toggle"

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.voiceByBackend, [
            "apple-tts": "com.apple.voice.x",
            "kokoro": "am_adam",
            "pocket-tts": "alba",
        ])
        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testLegacyV1BlobWithoutVoiceKeysMigratesToAnEmptyMap() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacyV1Object())
        )

        XCTAssertTrue(decoded.voiceByBackend.isEmpty)
    }

    func testMigratedBlobReEncodesAsV2WithoutLegacyKeys() throws {
        var object = try legacyV1Object()
        object["kokoroVoice"] = "am_adam"
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        let reencoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any]
        )

        XCTAssertEqual(reencoded["schemaVersion"] as? Int, 2)
        XCTAssertEqual(reencoded["voiceByBackend"] as? [String: String], ["kokoro": "am_adam"])
        XCTAssertNil(reencoded["kokoroVoice"])
        XCTAssertNil(reencoded["pocketVoice"])
        XCTAssertNil(reencoded["ttsVoiceIdentifier"])
    }

    func testV2BlobIgnoresStrayLegacyKeys() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any]
        )
        object["voiceByBackend"] = ["kokoro": "af_heart"]
        object["kokoroVoice"] = "am_adam"

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.voiceByBackend, ["kokoro": "af_heart"])
    }

    /// Current defaults re-shaped as a schema-1 blob (no `voiceByBackend`).
    private func legacyV1Object() throws -> [String: Any] {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any]
        )
        object.removeValue(forKey: "voiceByBackend")
        object["schemaVersion"] = 1
        return object
    }
```
In `AppSettingsDecodeTests.swift`:
- `testOldSchemaVersionMigrates`: replace `"kokoroVoice", "pocketVoice"` in the removed-keys list with `"voiceByBackend"`, and replace the two `XCTAssertNil(decoded.kokoroVoice)` / `pocketVoice` lines with `XCTAssertTrue(decoded.voiceByBackend.isEmpty)`.
- `testValidCurrentBlobRoundTripsIdentically`: replace the three voice assignments with `value.voiceByBackend = ["apple-tts": "voice.test", "kokoro": "af_heart", "pocket-tts": "alba"]`.
- `testInvalidOneFieldDoesNotResetUnrelated`: `saved.ttsVoiceIdentifier = "voice.test"` → `saved.voiceByBackend["apple-tts"] = "voice.test"`; `XCTAssertEqual(decoded.ttsVoiceIdentifier, "voice.test")` → `XCTAssertEqual(decoded.voiceByBackend["apple-tts"], "voice.test")`.
- Replace plan 1's `testWrongTypedOptionalFieldsFallBackWithoutResettingOthers` (its three voice keys no longer exist on a v2 blob) with these two, which keep its intent for both schema shapes:
```swift
    /// A v1 blob with wrong-typed legacy voice values migrates the valid ones and drops only
    /// the bad ones; no other field is reset.
    func testWrongTypedLegacyVoiceKeysMigrateWithoutResettingOthers() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.ttsRate = 0.8
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        object.removeValue(forKey: "voiceByBackend")
        object["schemaVersion"] = 1
        object["ttsVoiceIdentifier"] = 42
        object["kokoroVoice"] = "am_adam"
        object["pocketVoice"] = ["not", "a", "string"]
        object["liveTranscriptionEnabled"] = "yes"

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.voiceByBackend, ["kokoro": "am_adam"])
        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.ttsRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(decoded.liveTranscriptionEnabled, AppSettings.defaults.liveTranscriptionEnabled)
    }

    func testWrongTypedVoiceMapFallsBackToEmptyWithoutResettingOthers() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        object["voiceByBackend"] = ["kokoro": 7]

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertTrue(decoded.voiceByBackend.isEmpty)
        XCTAssertEqual(decoded.dictationMode, .toggle)
    }
```
  Plan 1's other decode tests (overlay style, hotkeys, including the follow-up that falls back to the default hotkey map when no saved entry is usable) touch no voice field and stay unchanged.

Append to `SettingsControllerTests`:
```swift
    func testSetVoiceWritesAndClearsOneBackendsEntry() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setVoice("am_adam", for: BackendID.kokoro.rawValue)
        XCTAssertEqual(controller.current.voiceByBackend, ["kokoro": "am_adam"])

        controller.setVoice(nil, for: BackendID.kokoro.rawValue)
        XCTAssertTrue(controller.current.voiceByBackend.isEmpty)
        XCTAssertEqual(store.saved.count, 2)
    }

    func testTTSOptionsMapTheVoiceMapOntoBackendFields() {
        var settings = AppSettings.defaults
        settings.ttsRate = 0.7
        settings.voiceByBackend = ["apple-tts": "com.apple.voice.x", "kokoro": "am_adam", "pocket-tts": "alba"]

        let options = TTSOptions(settings: settings)

        XCTAssertEqual(options, TTSOptions(voiceIdentifier: "com.apple.voice.x", rate: 0.7, kokoroVoice: "am_adam", pocketVoice: "alba"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppSettingsTests 2>&1 | tail -30`
Expected: build FAILS — `value of type 'AppSettings' has no member 'voiceByBackend'`.

- [ ] **Step 3: Implement `AppSettings`.**
1. Stored properties: delete `ttsVoiceIdentifier`, `kokoroVoice`, `pocketVoice`; add
```swift
    /// The selected voice per TTS backend id (`BackendID.rawValue` → backend-specific voice id).
    /// A missing entry means that backend's default voice.
    var voiceByBackend: [String: String]
```
2. `static let currentSchemaVersion = 2` (doc: `/// 2: per-backend voice keys folded into voiceByBackend.`).
3. `CodingKeys`: replace `ttsVoiceIdentifier`, `kokoroVoice`, `pocketVoice` with `voiceByBackend`. Add:
```swift
    /// Keys only schema < 2 wrote; read during migration, never encoded.
    private enum LegacyCodingKeys: String, CodingKey {
        case ttsVoiceIdentifier, kokoroVoice, pocketVoice
    }
```
4. In `init(from:)` (plan 1's per-field version), delete the three lines `ttsVoiceIdentifier = field(.ttsVoiceIdentifier, …)`, `kokoroVoice = field(.kokoroVoice, …)`, `pocketVoice = field(.pocketVoice, …)` and put this in their place (the existing final `schemaVersion = AppSettings.currentSchemaVersion` line stays):
```swift
        // The first reshaped field: schema < 2 stored one optional voice per TTS backend under
        // its own key. A blob with no/invalid `schemaVersion` reads as 0 and migrates too.
        let savedSchemaVersion = field(.schemaVersion, default: 0)
        if savedSchemaVersion < 2 {
            voiceByBackend = AppSettings.migrateLegacyVoices(from: decoder)
        } else {
            // Current, or newer than this build knows: best-effort per-field decode.
            voiceByBackend = field(.voiceByBackend, default: fallback.voiceByBackend)
        }
```
   and add:
```swift
    private static func migrateLegacyVoices(from decoder: Decoder) -> [String: String] {
        guard let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) else { return [:] }
        let pairs: [(LegacyCodingKeys, BackendID)] = [
            (.ttsVoiceIdentifier, .appleTTS),
            (.kokoroVoice, .kokoro),
            (.pocketVoice, .pocketTTS),
        ]
        var voices: [String: String] = [:]
        for (key, backend) in pairs {
            if let voice = try? legacy.decode(String.self, forKey: key) {
                voices[backend.rawValue] = voice
            }
        }
        return voices
    }
```
5. Memberwise init: remove `ttsVoiceIdentifier`, `kokoroVoice`, `pocketVoice` params/assignments; add `voiceByBackend: [String: String] = [:],` after `activityOverlayStyle`. `defaults`: remove `ttsVoiceIdentifier: nil,`.
6. At the bottom of the file:
```swift
extension TTSOptions {
    /// The single mapping from persisted settings to per-utterance options.
    init(settings: AppSettings) {
        self.init(
            voiceIdentifier: settings.voiceByBackend[BackendID.appleTTS.rawValue],
            rate: settings.ttsRate,
            kokoroVoice: settings.voiceByBackend[BackendID.kokoro.rawValue],
            pocketVoice: settings.voiceByBackend[BackendID.pocketTTS.rawValue]
        )
    }
}
```

- [ ] **Step 4: Settings, catalog, runtime, model.**
`SettingsController`: delete `setVoiceIdentifier`/`setKokoroVoice`/`setPocketVoice`; add
```swift
    func setVoice(_ voice: String?, for backendID: String) {
        update { $0.voiceByBackend[backendID] = voice }
    }
```
`SpeechVoiceCatalog`: replace `activeVoiceID` and `options(for:)` with (`voices(for:)` and `storedValue` unchanged):
```swift
    func activeVoiceID(for backendID: String, settings: AppSettings) -> String? {
        let options = voices(for: backendID)
        guard let defaultOption = options.first(where: { $0.storedValue == nil }) else { return nil }
        guard let value = settings.voiceByBackend[backendID], value != recommendedValue(for: backendID) else {
            return defaultOption.id
        }
        return options.first(where: { $0.storedValue == value })?.id
    }

    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions? {
        guard BackendID.allTextToSpeech.contains(BackendID(rawValue: backendID)),
              let mapped = storedValue(for: voiceID, backendID: backendID)
        else { return nil }
        var previewSettings = settings
        previewSettings.voiceByBackend[backendID] = mapped
        return TTSOptions(settings: previewSettings)
    }

    /// The stored value that means "the recommended default" for backends that name one.
    private func recommendedValue(for backendID: String) -> String? {
        switch backendID {
        case BackendID.kokoro: recommendedKokoroVoice
        case BackendID.pocketTTS: pocketVoice
        default: nil
        }
    }
```
`RelayRuntime.makeProduction()`: `options: { TTSOptions(settings: settings.value) },`.
`AppModel.selectVoice`:
```swift
    func selectVoice(backendID: String, voiceID: String) {
        guard let value = voiceCatalog.storedValue(for: voiceID, backendID: backendID) else { return }
        settingsController.setVoice(value, for: backendID)
    }
```

- [ ] **Step 5: Remaining tests.**
- `SpeechVoiceCatalogTests.testOptionsOverrideOnlyClickedProvidersVoiceAndPreserveRate`: replace the three assignments with `settings.voiceByBackend = ["apple-tts": "apple.saved", "kokoro": "af_heart", "pocket-tts": "alba"]`.
- `AppModelTests`: in `testPreviewVoiceUsesClickedProviderAndCurrentRateWithoutPersistingSelection` use `settings.voiceByBackend["kokoro"] = "af_heart"` and assert `model.settings.voiceByBackend["kokoro"] == "af_heart"`; in `testSelectVoicePersistsThroughProviderNeutralCatalogMapping` assert `model.settings.voiceByBackend["kokoro"] == "am_adam"`; in `makeTTSRoutingModel` use `settings.voiceByBackend = ["kokoro": "af_bella", "pocket-tts": "alba"]` and `options: { TTSOptions(settings: settings) }`.
- `AppModelHotkeySideEffectTests`: `model.settingsController.setVoiceIdentifier("com.apple.voice.some-voice")` → `model.settingsController.setVoice("com.apple.voice.some-voice", for: BackendID.appleTTS.rawValue)` (both occurrences).

- [ ] **Step 6: Verify**

Run: `grep -rn "ttsVoiceIdentifier\|settings\.kokoroVoice\|settings\.pocketVoice\|\$0\.kokoroVoice\|\$0\.pocketVoice\|setKokoroVoice\|setPocketVoice\|setVoiceIdentifier" Relay RelayTests`
Expected: exactly these hits and nothing else —
- `Relay/Domain/AppSettings.swift`: the `LegacyCodingKeys` case line and the `(.ttsVoiceIdentifier, .appleTTS)` migration pair;
- `RelayTests/Domain/AppSettingsTests.swift`: `object["ttsVoiceIdentifier"] = …` in `testLegacyV1VoiceKeysMigrateIntoTheVoiceMap`, and the `XCTAssertNil(reencoded["ttsVoiceIdentifier"])` line;
- `RelayTests/Domain/AppSettingsDecodeTests.swift`: `object["ttsVoiceIdentifier"] = 42` in `testWrongTypedLegacyVoiceKeysMigrateWithoutResettingOthers`.
(`TTSOptions.kokoroVoice`/`pocketVoice` are option fields, not settings; `options.kokoroVoice` reads don't match the pattern.) Then full suite → `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**
```bash
git add Relay/Domain/AppSettings.swift Relay/App/SettingsController.swift Relay/App/SpeechVoiceCatalog.swift \
  Relay/App/AppModel.swift Relay/App/RelayRuntime.swift RelayTests/Domain/AppSettingsTests.swift \
  RelayTests/Domain/AppSettingsDecodeTests.swift RelayTests/App/SpeechVoiceCatalogTests.swift \
  RelayTests/App/AppModelTests.swift RelayTests/App/AppModelHotkeySideEffectTests.swift \
  RelayTests/App/SettingsControllerTests.swift
git commit -m "refactor(settings): store voices per backend and migrate schema v1 to v2"
```

---

## Task 7: `SpeechActions` + `ReplayLastResolver`

**Finding:** `readSelection`, the three-tier `replayLast`, stop, `previewVoice` and `speakLatestAgentResponse` (`AppModel.swift` 684–825 and 1043–1058; the stop case is inline in `handleHotkey`, 629–634) live in `AppModel`; the replay tier decision is only testable end-to-end through a hotkey.

**Fix:** A pure `ReplayLastResolver.resolve(globalLatestAvailable:) async -> ReplayTarget` (`.focusedSession(AgentSession)` | `.globalLatest` | `.lastSpoken`), using plan 3's one-snapshot `resolveFocus(among:processSnapshot:)`, plus a stateless `SpeechActions` that acts on the target and keeps plan 1's cancellation contract: it checks `Task.isCancelled` after resolving and before every speak, and a `CancellationError` is an intentional stop (no `.ttsFailed`, no status text). The six `testReplayLast…` tests left after plan 2 move to the resolver; the failure/speak-latest tests move to `SpeechActionsTests`. (Who owns and cancels the task is Task 8's `HotkeyController`; until then `AppModel.startSpeechAction` keeps doing it.)

**Files:**
- Create: `Relay/Sessions/ReplayLastResolver.swift`, `Relay/App/SpeechActions.swift`, `RelayTests/Sessions/ReplayLastResolverTests.swift`, `RelayTests/App/SpeechActionsTests.swift`
- Modify: `Relay/App/AppModel.swift`, `Relay/App/MenuBarContentView.swift`, `Relay/App/Settings/TTSSettingsView.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/IntegrationSetupModelTests.swift`

- [ ] **Step 1: Resolver tests** — `RelayTests/Sessions/ReplayLastResolverTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class ReplayLastResolverTests: XCTestCase {
    private func makeResolver(
        registry: AgentSessionRegistry,
        focused: AgentSessionID? = nil,
        frontmostPID: Int32? = nil,
        runner: any ProcessRunning = AllPIDsAliveProcessRunner()
    ) -> ReplayLastResolver {
        ReplayLastResolver(
            registry: registry,
            processInspector: ProcessInspector(runner: runner),
            focusResolution: StubSessionFocusResolver(focusedSessionID: focused),
            frontmostApps: StubFrontmostAppMonitor(pid: frontmostPID)
        )
    }

    private func upsert(_ registry: AgentSessionRegistry, _ id: String, ancestry: [Int32] = []) async -> AgentSession {
        await registry.upsert(response: .fixture(providerSessionID: id), processAncestry: ancestry, tty: nil)
    }

    func testConfidentlyFocusedSessionWins() async {
        let registry = AgentSessionRegistry()
        let sessionA = await upsert(registry, "session-a")
        _ = await upsert(registry, "session-b")

        let target = await makeResolver(registry: registry, focused: sessionA.id)
            .resolve(globalLatestAvailable: { true })

        guard case let .focusedSession(session) = target else { return XCTFail("got \(target)") }
        XCTAssertEqual(session.id, sessionA.id)
    }

    func testDeadProcessSessionIsPrunedBeforeFocusResolution() async {
        let registry = AgentSessionRegistry()
        let dead = await upsert(registry, "dead-session", ancestry: [1_234_567])

        let target = await makeResolver(registry: registry, focused: dead.id, runner: AllPIDsDeadProcessRunner())
            .resolve(globalLatestAvailable: { false })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testAmbiguousFocusWithFrontmostHostingASessionPrefersGlobalLatest() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 4242)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .globalLatest)
    }

    func testFrontmostHostingNoSessionFallsBackToLastSpoken() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 9999)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testNoFrontmostApplicationFallsBackToLastSpoken() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: nil)
            .resolve(globalLatestAvailable: { true })

        XCTAssertEqual(target, .lastSpoken)
    }

    func testEmptyGlobalLatestFallsBackToLastSpokenEvenWhenFrontmostHostsASession() async {
        let registry = AgentSessionRegistry()
        _ = await upsert(registry, "session-a", ancestry: [4242])

        let target = await makeResolver(registry: registry, frontmostPID: 4242)
            .resolve(globalLatestAvailable: { false })

        XCTAssertEqual(target, .lastSpoken)
    }
}
```

- [ ] **Step 2: `SpeechActions` tests** — `RelayTests/App/SpeechActionsTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class SpeechActionsTests: XCTestCase {
    private func makeActions(
        speech: SpySpeechCoordinator = SpySpeechCoordinator(),
        selection: SpySelectionReader = SpySelectionReader(),
        store: SpySettingsStore = SpySettingsStore(),
        integrationManager: IntegrationManager? = nil,
        registry: AgentSessionRegistry = AgentSessionRegistry(),
        frontmostPID: Int32? = nil,
        focused: AgentSessionID? = nil
    ) -> (actions: SpeechActions, runtime: RelayRuntime) {
        let runtime = RelayRuntime.testing(
            settingsStore: store,
            selectionReader: selection,
            speechCoordinator: speech,
            integrationManager: integrationManager,
            sessionRegistry: registry,
            frontmostApps: StubFrontmostAppMonitor(pid: frontmostPID),
            focusResolution: StubSessionFocusResolver(focusedSessionID: focused)
        )
        let catalog = SpeechVoiceCatalog(
            appleVoices: [], kokoroVoices: ["af_heart", "am_adam"], recommendedKokoroVoice: "af_heart", pocketVoice: "alba"
        )
        return (SpeechActions(runtime: runtime, voiceCatalog: catalog), runtime)
    }

    /// Drives one event through a real `IntegrationManager` consume loop so `latestResponse`
    /// and its store agree, exactly as the socket pipeline keeps them.
    private func drivenManager(
        latest: AgentResponseEvent,
        store: LatestAgentResponseStore,
        speech: SpySpeechCoordinator
    ) async -> IntegrationManager {
        await store.set(latest)
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(
            events: events,
            integrations: [StubDecodingIntegration(provider: .claudeCode, event: latest)],
            store: store,
            speechCoordinator: speech
        )
        manager.start()
        continuation.yield(HookEnvelope(
            schemaVersion: 1, provider: .claudeCode, rawPayload: "{}",
            parentPID: 100, environment: [:], capturedAt: latest.capturedAt
        ))
        let deadline = Date().addingTimeInterval(2)
        while manager.latestResponse == nil, Date() < deadline { await Task.yield() }
        manager.stop()
        return manager
    }

    func testReadSelectionPreprocessesAndSpeaksAUserRequest() async {
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(
            speech: speech,
            selection: SpySelectionReader(text: "Intro\n```swift\nsecret()\n```\nEnd")
        )

        await actions.readSelection()

        XCTAssertEqual(speech.requests, [SpeechRequest(
            text: "Intro There is a code block on screen. Please read it there. End",
            source: .selection, mode: .userRequested, sessionID: nil
        )])
        XCTAssertEqual(runtime.status.message, "Ready")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsSubmitted)
    }

    func testFocusedSessionReplaySpeaksThatSessionsReply() async {
        let registry = AgentSessionRegistry()
        let sessionA = await registry.upsert(response: .fixture(providerSessionID: "session-a", text: "Reply A"), processAncestry: [], tty: nil)
        let speech = SpySpeechCoordinator()
        let (actions, _) = makeActions(speech: speech, registry: registry, focused: sessionA.id)

        await actions.replayLast()

        XCTAssertEqual(speech.requests.first?.sessionID, "claude-code:session-a")
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertEqual(speech.replayCount, 0)
    }

    func testGlobalLatestReplaySpeaksTheLatestAgentResponse() async {
        let registry = AgentSessionRegistry()
        _ = await registry.upsert(response: .fixture(providerSessionID: "session-a"), processAncestry: [4242], tty: nil)
        let speech = SpySpeechCoordinator()
        let manager = await drivenManager(
            latest: .fixture(providerSessionID: "global-latest", text: "Global reply"),
            store: LatestAgentResponseStore(),
            speech: speech
        )
        let (actions, _) = makeActions(speech: speech, integrationManager: manager, registry: registry, frontmostPID: 4242)

        await actions.replayLast()

        XCTAssertEqual(speech.requests.map(\.sessionID), ["claude-code:global-latest"])
        XCTAssertEqual(speech.replayCount, 0)
    }

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let (actions, runtime) = makeActions(speech: SpySpeechCoordinator(replayError: SpeechBoom()))

        await actions.replayLast()

        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsFailed)
    }

    /// Plan 1: a cancelled speak (Stop, or a newer press) is intentional, not a failure.
    func testCancelledReplayIsNotReportedAsFailure() async {
        let (actions, runtime) = makeActions(speech: SpySpeechCoordinator(replayError: CancellationError()))

        await actions.replayLast()

        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(runtime.status.message, "Ready")
    }

    func testCancelledReadSelectionIsNotReportedAsFailure() async {
        let speech = SpySpeechCoordinator(speakError: CancellationError())
        let (actions, runtime) = makeActions(speech: speech)

        await actions.readSelection()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(runtime.status.message, "Ready")
    }

    /// A replay whose task was cancelled while focus was resolving never speaks.
    func testReplayInACancelledTaskSpeaksNothing() async {
        let speech = SpySpeechCoordinator()
        let (actions, _) = makeActions(speech: speech)

        let task = Task { await actions.replayLast() }
        task.cancel()
        await task.value

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testStopSpeechStopsAndAnnounces() {
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(speech: speech)

        actions.stopSpeech()

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(runtime.status.message, "Speech stopped")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsStopped)
    }

    func testPreviewVoiceUsesClickedProviderAndCurrentRateWithoutPersisting() async {
        var settings = AppSettings.defaults
        settings.voiceByBackend["kokoro"] = "af_heart"
        settings.ttsRate = 0.75
        let store = SpySettingsStore(settings: settings)
        let speech = SpySpeechCoordinator()
        let (actions, runtime) = makeActions(speech: speech, store: store)

        await actions.previewVoice(backendID: "kokoro", voiceID: "kokoro:am_adam")

        XCTAssertEqual(speech.previews.first?.backendID, "kokoro")
        XCTAssertEqual(speech.previews.first?.options.kokoroVoice, "am_adam")
        XCTAssertEqual(speech.previews.first?.options.rate, 0.75)
        XCTAssertEqual(speech.previews.first?.text, SpeechActions.previewSampleText)
        XCTAssertEqual(runtime.settingsController.current.voiceByBackend["kokoro"], "af_heart")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testSpeakLatestAgentResponseFailureIsSurfaced() async {
        let store = LatestAgentResponseStore()
        await store.set(.fixture(provider: .codex, providerSessionID: "session-2"))
        let speech = SpySpeechCoordinator(speakError: SpeechBoom())
        let manager = IntegrationManager(events: AsyncStream { _ in }, integrations: [], store: store, speechCoordinator: speech)
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)

        await actions.speakLatestAgentResponse()

        XCTAssertEqual(runtime.status.message, "Could not speak the latest agent response.")
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .ttsFailed)
    }

    /// Moved from plan 1's `AppModelIntegrationsTests`: nothing to speak is not a submission.
    func testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission() async {
        let speech = SpySpeechCoordinator()
        let manager = IntegrationManager(
            events: AsyncStream<HookEnvelope> { _ in },
            integrations: [],
            store: LatestAgentResponseStore(),
            speechCoordinator: speech
        )
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)

        await actions.speakLatestAgentResponse()

        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertFalse(runtime.diagnostics.entries.contains { $0.event == .ttsSubmitted })
        XCTAssertEqual(runtime.status.message, "No agent response to speak yet.")
    }

    /// Moved from `AppModelIntegrationsTests`: a successful speak clears a stale failure message.
    func testSpeakLatestAgentResponseSuccessClearsAStaleStatusText() async {
        let store = LatestAgentResponseStore()
        await store.set(.fixture(providerSessionID: "session-3", text: "Done."))
        let speech = SpySpeechCoordinator()
        let manager = IntegrationManager(events: AsyncStream { _ in }, integrations: [], store: store, speechCoordinator: speech)
        let (actions, runtime) = makeActions(speech: speech, integrationManager: manager)
        runtime.status.post("Could not speak the latest agent response.")

        await actions.speakLatestAgentResponse()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(runtime.status.message, "Ready")
    }
}

private struct SpeechBoom: Error {}

private struct StubDecodingIntegration: RelayIntegration {
    let provider: AgentProvider
    let event: AgentResponseEvent
    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent { event }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ReplayLastResolverTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'ReplayLastResolver' in scope`.

- [ ] **Step 4: Implement the resolver** — `Relay/Sessions/ReplayLastResolver.swift`:

```swift
import Foundation

/// What "Replay Last" should speak.
enum ReplayTarget: Equatable, Sendable {
    /// Tier 1: a confidently focused agent session's own last reply.
    case focusedSession(AgentSession)
    /// Tier 2: the frontmost app hosts an agent session but focus is ambiguous — the global latest reply.
    case globalLatest
    /// Tier 3: a non-agent context — re-speak the last spoken/selected text.
    case lastSpoken
}

/// Decides the Replay Last tier. Reads the session registry, one process snapshot, focus
/// resolution and the frontmost app; performs no speech.
@MainActor
struct ReplayLastResolver {
    let registry: AgentSessionRegistry
    let processInspector: ProcessInspector
    let focusResolution: any SessionFocusResolving
    let frontmostApps: any FrontmostAppMonitoring

    /// - Parameter globalLatestAvailable: evaluated only at the tier-2 check, so it reflects the
    ///   store at that moment.
    func resolve(globalLatestAvailable: () -> Bool) async -> ReplayTarget {
        // One snapshot for this decision, shared by pruning and every focus resolver — the same
        // shape as `AgentAutoReadCoordinator.handle(_:)`. Pruning first means a dead-process
        // session is never offered to focus resolution or treated as hosting the frontmost app.
        let snapshot = try? await processInspector.snapshot()
        await pruneDeadSessions(in: registry, snapshot: snapshot)
        let sessions = await registry.sessions()

        if let focused = await focusResolution.resolveFocus(among: sessions, processSnapshot: snapshot).focused {
            return .focusedSession(focused)
        }
        if let frontmostPID = await frontmostApps.current()?.pid,
           sessions.contains(where: { $0.processAncestry.contains(frontmostPID) }),
           globalLatestAvailable() {
            return .globalLatest
        }
        return .lastSpoken
    }
}
```

- [ ] **Step 5: Implement `SpeechActions`** — `Relay/App/SpeechActions.swift`. This is `AppModel`'s end-of-plan-1/3 behavior (Task 8 cancellation, Task 13 speak-latest guard) with `statusText =` → `statusSink.post(…)`:

```swift
import Foundation

/// User-initiated speech: read the selection, session-aware replay, stop, voice preview, and
/// speaking the latest agent response. Holds no state; failures go to diagnostics + status line.
/// The caller owns the task these run in: every speak re-checks `Task.isCancelled` first, and a
/// `CancellationError` (Stop, or a newer press) is intentional — never `.ttsFailed`.
@MainActor
final class SpeechActions {
    /// Fixed sample for voice previews — never user content.
    static let previewSampleText = "This is a preview of the selected voice and speaking rate."

    private let selectionReader: any SelectionReading
    private let preprocessor: RulesSpeechPreprocessor
    private let speechCoordinator: any SpeechCoordinating
    private let integrationManager: IntegrationManager
    private let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    private let replayResolver: ReplayLastResolver
    private let voiceCatalog: SpeechVoiceCatalog
    private let settings: SettingsController
    private let diagnostics: DiagnosticsRecorder
    private let statusSink: StatusSink

    init(runtime: RelayRuntime, voiceCatalog: SpeechVoiceCatalog) {
        selectionReader = runtime.selectionReader
        preprocessor = runtime.preprocessor
        speechCoordinator = runtime.speechOut.speechCoordinator
        integrationManager = runtime.integrations.integrationManager
        integrationDiagnosticsLog = runtime.integrationDiagnosticsLog
        replayResolver = ReplayLastResolver(
            registry: runtime.sessions.registry,
            processInspector: runtime.sessions.processInspector,
            focusResolution: runtime.sessions.focusResolution,
            frontmostApps: runtime.sessions.frontmostApps
        )
        self.voiceCatalog = voiceCatalog
        settings = runtime.settingsController
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
    }

    func readSelection() async {
        do {
            let selection = try selectionReader.readSelection()
            diagnostics.record(selection.source == .accessibility ? .selectionAccessibility : .selectionClipboard)
            let request = SpeechRequest(
                text: preprocessor.prepare(text: selection.text, mode: .userRequested),
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            )
            guard !Task.isCancelled else { return }
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(error is SelectionReadingError ? .selectionUnavailable : .ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }

    /// Session-aware Replay Last; tiers documented on `ReplayTarget`. Always `.userRequested`.
    func replayLast() async {
        let manager = integrationManager
        let target = await replayResolver.resolve(globalLatestAvailable: { manager.latestResponse != nil })
        guard !Task.isCancelled else { return }
        switch target {
        case let .focusedSession(session):
            await speakFocusedSessionReply(session)
        case .globalLatest:
            if await speakGlobalLatestReply() { return }
            guard !Task.isCancelled else { return }
            await speakLastSpokenText()
        case .lastSpoken:
            await speakLastSpokenText()
        }
    }

    /// Stops playback. Cancelling the in-flight action task is the caller's job (`HotkeyController`).
    func stopSpeech() {
        speechCoordinator.stop()
        diagnostics.record(.ttsStopped)
        statusSink.post("Speech stopped")
    }

    func previewVoice(backendID: String, voiceID: String) async {
        guard let options = voiceCatalog.options(for: voiceID, backendID: backendID, settings: settings.current) else { return }
        do {
            try await speechCoordinator.previewVoice(text: Self.previewSampleText, backendID: backendID, options: options)
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post("Voice preview failed. Try again.")
        }
    }

    func speakLatestAgentResponse() async {
        do {
            guard try await integrationManager.speakLatest() else {
                statusSink.post("No agent response to speak yet.")
                return
            }
            diagnostics.record(.ttsSubmitted)
            // Clears a stale "Could not speak…" / "No agent response…" left by an earlier call.
            statusSink.post(StatusSink.idleMessage)
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post("Could not speak the latest agent response.")
        }
    }

    private func speakFocusedSessionReply(_ session: AgentSession) async {
        do {
            try await integrationManager.speakResponse(session.latestResponse)
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(
                stage: "replay-last",
                outcome: "focused-session",
                detail: "provider=\(session.id.provider.rawValue)"
            )
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }

    /// `true` when tier 2 handled the request (spoke, was cancelled, or failed loudly); `false`
    /// when the store had nothing, so the caller falls through to tier 3.
    private func speakGlobalLatestReply() async -> Bool {
        do {
            guard try await integrationManager.speakLatest() else { return false }
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "global-latest", detail: "")
            return true
        } catch is CancellationError {
            return true
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
            return true
        }
    }

    private func speakLastSpokenText() async {
        do {
            try await speechCoordinator.replayLast()
            diagnostics.record(.ttsReplayed)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "last-spoken", detail: "")
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }
}
```
The bodies above match `AppModel.swift@6d14400` line for line (`readSelection` 684–704, `replayLast` 720–743 split into resolver + dispatch, `speakFocusedSessionReply`/`speakGlobalLatestReply`/`speakLastSpokenText` 748–802, `previewVoice` 808–825, `speakLatestAgentResponse` 1043–1058 including its success-path reset to "Ready", the `.stopSpeech` lines 632–634) with `statusText =` → `statusSink.post(…)`; only doc comments were shortened.

- [ ] **Step 6: Trim `AppModel`.** Delete `readSelection`, `replayLast`, `speakFocusedSessionReply`, `speakGlobalLatestReply`, `speakLastSpokenText`, the preview sample constant, `previewVoice`, `speakLatestAgentResponse`, and the accessors only they used: `selectionReader`, `preprocessor`, `integrationManager`, `sessionRegistry` (its last other user, `agentSessionSummaries`, moved in Task 2), `focusResolution`, `frontmostApps`, `processInspector`. Keep `integrationDiagnosticsLog` (`integrationDiagnosticsEntries()`/`clearIntegrationDiagnostics()` use it) and `speechCoordinator` (`configureModelController`'s `beforeRemoval` hook uses it until Task 10). Add `@ObservationIgnored let speechActions: SpeechActions`, built in `init` after `voiceCatalog`:
```swift
        speechActions = SpeechActions(runtime: runtime, voiceCatalog: voiceCatalog)
```
Plan 1's `startSpeechAction` now hands the closure the actions object instead of the model:
```swift
    /// Replaces any in-flight speech action with `action`. The cancelled one re-checks
    /// `Task.isCancelled` before speaking, so it never reaches the speech coordinator.
    private func startSpeechAction(_ action: @escaping @MainActor (SpeechActions) async -> Void) {
        speechActionTask?.cancel()
        let actions = speechActions
        speechActionTask = Task {
            guard !Task.isCancelled else { return }
            await action(actions)
        }
    }
```
and in `handleHotkey` the `.stopSpeech` case becomes `speechActionTask?.cancel(); speechActionTask = nil; speechActions.stopSpeech()` (the `.readSelection` / `.replayLast` cases, `startSpeechAction { await $0.readSelection() }` / `{ await $0.replayLast() }`, compile unchanged).

- [ ] **Step 7: Views.** `MenuBarContentView`: `await model.speakLatestAgentResponse()` → `await model.speechActions.speakLatestAgentResponse()`. `TTSSettingsView`: `model.previewVoice(` → `model.speechActions.previewVoice(`.

- [ ] **Step 8: Remove moved tests.** From `AppModelTests.swift` delete: `testReplayFailureIsLoggedAsTTSFailure`, the six `testReplayLast…` tests (plan 2 already deleted the seventh, `…GateIsTrueButStoreHasNothingToSpeak`), plan 1's `testCancelledReadSelectionIsNotReportedAsFailure` (now in `SpeechActionsTests`), `testPreviewVoiceUsesClickedProviderAndCurrentRateWithoutPersistingSelection`, and the private `StubIntegration` and `AllPIDsDead…` usages that become unused. Keep `testReadSelectionPressedPreprocessesAndSpeaksUserRequest`, `testStopAndReplayOnlyActWhenPressed` and plan 1's `testTwoQuickReadSelectionPressesSpeakOnlyOnce` / `testTwoQuickReplayPressesReplayOnlyOnce` / `testStopSpeechCancelsAPendingReplay` (hotkey wiring; they move in Task 8). From `IntegrationSetupModelTests.swift`: rewrite `testLatestAgentResponseAvailableReflects…` to keep only its availability half (`makeModel(integrationManager:)` + `model.latestResponseAvailable`, no speak assertions), and delete `testSpeakLatestAgentResponseFailureIsCaughtAndSurfacedWithoutCrashing`, plan 1's `testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission` and `testSpeakLatestAgentResponseSuccessClearsAStaleStatusText` (all three now in `SpeechActionsTests`). Its private `FakeSpeechCoordinator` stays only if a remaining test still constructs it; otherwise delete it too (the compiler does not warn, so check with `grep -n FakeSpeechCoordinator RelayTests/App/IntegrationSetupModelTests.swift`).

- [ ] **Step 9: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**
```bash
git add Relay/Sessions/ReplayLastResolver.swift Relay/App/SpeechActions.swift Relay/App/AppModel.swift \
  Relay/App/MenuBarContentView.swift Relay/App/Settings/TTSSettingsView.swift \
  RelayTests/Sessions/ReplayLastResolverTests.swift RelayTests/App/SpeechActionsTests.swift \
  RelayTests/App/AppModelTests.swift RelayTests/App/IntegrationSetupModelTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "refactor(speech): extract SpeechActions and a pure ReplayLastResolver"
```

---

## Task 8: `HotkeyController` + stop rebuilding the matcher on activation

**Findings:** Hotkey registration/dispatch/dictation queue live in `AppModel`. **Bug:** `recheckDiagnostics()` (`AppModel.swift` 568–574) runs on every `didBecomeActive` and calls `registerHotkeys()`, which rebuilds `HotkeyMatcher` (`GlobalHotkeyManager.register`), dropping any in-flight chord/double-tap gesture each time Relay is activated.

**Fix:** Split `HotkeyManaging` into `setHandler(_:)`, `ensureTap() -> HotkeyRegistrationStatus` and `update(definitions:)`; `GlobalHotkeyManager.update` rebuilds the matcher **only when definitions change**. Recheck calls `ensureTap()` only. `HotkeyController` owns dispatch, the dictation queue, `dictationPhase` and `eventTapStatus`.

**Files:**
- Create: `Relay/App/HotkeyController.swift`, `RelayTests/App/HotkeyControllerTests.swift`
- Modify: `Relay/System/GlobalHotkeyManager.swift`, `Relay/App/AppModel.swift`, `Relay/App/DiagnosticsView.swift`
- Modify tests: `RelayTests/System/GlobalHotkeyManagerTests.swift`, `RelayTests/Support/RelayRuntime+Testing.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/AppModelHotkeySideEffectTests.swift`

- [ ] **Step 1: Failing manager tests** — append to `GlobalHotkeyManagerTests`:

```swift
    func testUpdatingWithUnchangedDefinitionsPreservesAnInFlightChord() {
        let manager = GlobalHotkeyManager(tapFactory: { _, _ in nil })
        let recorder = InvocationRecorder()
        manager.setHandler { recorder.values.append(.init(action: $0, phase: $1)) }
        let definitions: [HotkeyAction: HotkeyDefinition] = [.readSelection: .chord(keyCode: 15, modifiers: [.option])]
        manager.update(definitions: definitions)

        manager.receive(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false))
        manager.update(definitions: definitions) // e.g. the didBecomeActive recheck
        manager.receive(.keyUp(keyCode: 15, modifiers: [.option]))

        XCTAssertEqual(recorder.values, [
            .init(action: .readSelection, phase: .pressed),
            .init(action: .readSelection, phase: .released),
        ])
    }

    func testUpdatingWithChangedDefinitionsRebuildsTheMatcher() {
        let manager = GlobalHotkeyManager(tapFactory: { _, _ in nil })
        let recorder = InvocationRecorder()
        manager.setHandler { recorder.values.append(.init(action: $0, phase: $1)) }
        manager.update(definitions: [.readSelection: .chord(keyCode: 15, modifiers: [.option])])

        manager.receive(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false))
        manager.update(definitions: [.readSelection: .chord(keyCode: 16, modifiers: [.option])])
        manager.receive(.keyUp(keyCode: 15, modifiers: [.option]))

        XCTAssertEqual(recorder.values, [.init(action: .readSelection, phase: .pressed)])
    }
```
and at file bottom:
```swift
@MainActor
private final class InvocationRecorder {
    var values: [HotkeyInvocation] = []
}
```
(`GlobalHotkeyManagerTests` is already `@MainActor`.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/GlobalHotkeyManagerTests 2>&1 | tail -30`
Expected: build FAILS — `value of type 'GlobalHotkeyManager' has no member 'setHandler'`.

- [ ] **Step 3: Split the protocol** in `GlobalHotkeyManager.swift`:

```swift
@MainActor
protocol HotkeyManaging: AnyObject {
    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void)
    /// Creates the event tap if it doesn't exist yet; never re-creates it. Cheap to call often.
    @discardableResult
    func ensureTap() -> HotkeyRegistrationStatus
    /// Rebuilds the matcher only when `definitions` differ from the current ones, so an
    /// unchanged update never discards in-flight chord/double-tap state.
    func update(definitions: [HotkeyAction: HotkeyDefinition])
}
```
In `GlobalHotkeyManager`: add `private var definitions: [HotkeyAction: HotkeyDefinition] = [:]`; replace `register(settings:handler:)` with:
```swift
    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void) {
        self.handler = handler
    }

    func update(definitions: [HotkeyAction: HotkeyDefinition]) {
        guard definitions != self.definitions else { return }
        self.definitions = definitions
        matcher = HotkeyMatcher(definitions: definitions)
    }

    @discardableResult
    func ensureTap() -> HotkeyRegistrationStatus {
        if eventTap != nil {
            diagnostics?.record(.eventTapRegistered)
            return .registered
        }
        // …the rest of the old register() body from `let mask = …` to `return .registered`, unchanged…
    }
```
Change `private func receive(_ input:)` to `func receive(_ input: HotkeyInputEvent)` (internal, for tests; doc: `/// Feeds one decoded input event through the matcher. Internal so tests can drive it without CGEvents.`).

- [ ] **Step 4: Update test doubles.** `SpyHotkeyManager` (Support):
```swift
@MainActor
final class SpyHotkeyManager: HotkeyManaging {
    private let status: HotkeyRegistrationStatus
    private var handler: (@MainActor (HotkeyAction, HotkeyPhase) -> Void)?
    private(set) var updates: [[HotkeyAction: HotkeyDefinition]] = []
    private(set) var ensureTapCount = 0

    init(status: HotkeyRegistrationStatus = .registered) { self.status = status }

    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void) { self.handler = handler }
    func ensureTap() -> HotkeyRegistrationStatus { ensureTapCount += 1; return status }
    func update(definitions: [HotkeyAction: HotkeyDefinition]) { updates.append(definitions) }
    func send(_ action: HotkeyAction, _ phase: HotkeyPhase) { handler?(action, phase) }
}
```
`AppModelHotkeySideEffectTests`: delete its private `FakeHotkeyManager` (the `register(settings:handler:)` one recording `registrations: [AppSettings]`) and use `SpyHotkeyManager`; `hotkeys.registrations.count` → `hotkeys.updates.count`; `hotkeys.registrations.last?.hotkeys[` → `hotkeys.updates.last?[`. Its `testEventTapNotReRegisteredOnAnyChange` keeps the real `GlobalHotkeyManager(tapFactory:)` + `TapCreationSpy` and still expects `callCount == 1` (`ensureTap()` never re-creates the tap). Same two seds in `AppModelTests.swift` (whose `FakeHotkeyManager` Task 1 already renamed to `SpyHotkeyManager`):
```bash
sed -i '' -e 's/FakeHotkeyManager()/SpyHotkeyManager()/g' RelayTests/App/AppModelHotkeySideEffectTests.swift
sed -i '' -e 's/hotkeys\.registrations\.count/hotkeys.updates.count/g' \
          -e 's/hotkeys\.registrations\.last?\.hotkeys\[/hotkeys.updates.last?[/g' \
  RelayTests/App/AppModelTests.swift RelayTests/App/AppModelHotkeySideEffectTests.swift
```
Update that file's class doc comment: `GlobalHotkeyManager.register`'s `eventTap != nil` guard now lives in `ensureTap()`, and the matcher is rebuilt by `update(definitions:)` only when definitions change.
Then edit `testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot` (the **fix** regression):
```swift
        model.recheckDiagnostics()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(hotkeys.ensureTapCount, 2, "recheck retries the tap")
        XCTAssertEqual(hotkeys.updates.count, 1, "recheck must not rebuild the matcher")
        XCTAssertEqual(model.permissionSnapshot.inputMonitoringGranted, false)
```

- [ ] **Step 5: Controller tests** — `RelayTests/App/HotkeyControllerTests.swift` (moves the dispatch/dictation tests out of `AppModelTests`):

```swift
import XCTest
@testable import Relay

@MainActor
final class HotkeyControllerTests: XCTestCase {
    private func makeController(
        hotkeys: SpyHotkeyManager = SpyHotkeyManager(),
        dictation: SpyDictationCoordinator? = nil,
        speech: SpySpeechCoordinator = SpySpeechCoordinator(),
        selection: SpySelectionReader = SpySelectionReader()
    ) -> (controller: HotkeyController, runtime: RelayRuntime) {
        let runtime = RelayRuntime.testing(
            selectionReader: selection,
            speechCoordinator: speech,
            hotkeyManager: hotkeys,
            dictationCoordinator: dictation
        )
        let actions = SpeechActions(runtime: runtime, voiceCatalog: SpeechVoiceCatalog(
            appleVoices: [], kokoroVoices: [], recommendedKokoroVoice: "af_heart", pocketVoice: "alba"
        ))
        let controller = HotkeyController(runtime: runtime, speechActions: actions)
        controller.start()
        return (controller, runtime)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            await Task.yield()
        }
    }

    func testStartPushesDefinitionsAndEnsuresTheTapOnce() {
        let hotkeys = SpyHotkeyManager()
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        XCTAssertEqual(hotkeys.updates, [runtime.settingsController.current.hotkeys])
        XCTAssertEqual(hotkeys.ensureTapCount, 1)
        XCTAssertEqual(controller.eventTapStatus, .registered)
    }

    func testUnavailableTapSurfacesActionableStatus() {
        let hotkeys = SpyHotkeyManager(status: .unavailable("Enable Accessibility permission, then reopen Relay."))
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        XCTAssertEqual(controller.eventTapStatus, .unavailable("Enable Accessibility permission, then reopen Relay."))
        XCTAssertEqual(runtime.status.message, "Enable Accessibility permission, then reopen Relay.")
    }

    func testHoldToTalkStartsOnPressAndFinishesOnRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        await waitUntil { dictation.events == ["start", "finish"] }

        XCTAssertEqual(controller.dictationPhase, .released)
    }

    func testToggleDictationAlternatesOnPressAndIgnoresRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let (_, runtime) = makeController(hotkeys: hotkeys, dictation: dictation)
        runtime.settingsController.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start", "finish"] }
    }

    func testHoldToTalkQueuesReleaseUntilBlockedStartCompletes() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockStart: true)
        let (controller, _) = makeController(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start"] }
        hotkeys.send(.dictate, .released)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start"])

        dictation.resumeStart()
        await waitUntil { dictation.events == ["start", "finish"] }
        withExtendedLifetime(controller) {}
    }

    func testToggleQueuesNewPressUntilBlockedFinishCompletes() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockFinish: true)
        let (controller, runtime) = makeController(hotkeys: hotkeys, dictation: dictation)
        runtime.settingsController.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start"] }
        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start", "finish"] }
        hotkeys.send(.dictate, .pressed)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start", "finish"])

        dictation.resumeFinish()
        await waitUntil { dictation.events == ["start", "finish", "start"] }
        withExtendedLifetime(controller) {}
    }

    func testReadSelectionReleasedDoesNothing() async {
        let hotkeys = SpyHotkeyManager()
        let selection = SpySelectionReader()
        let speech = SpySpeechCoordinator()
        let (controller, runtime) = makeController(hotkeys: hotkeys, speech: speech, selection: selection)

        hotkeys.send(.readSelection, .released)
        await Task.yield()

        XCTAssertEqual(selection.readCount, 0)
        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertEqual(runtime.diagnostics.counters.dispatched, 0)
        withExtendedLifetime(controller) {}
    }

    func testStopAndReplayOnlyActWhenPressed() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.stopSpeech, .released)
        hotkeys.send(.replayLast, .released)
        hotkeys.send(.stopSpeech, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(controller) {}
    }

    // Plan 1 Task 8's single-action tests, moved from AppModelTests.

    func testTwoQuickReadSelectionPressesSpeakOnlyOnce() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.readSelection, .pressed)
        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.requests.count, 1)
        withExtendedLifetime(controller) {}
    }

    func testTwoQuickReplayPressesReplayOnlyOnce() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(controller) {}
    }

    func testStopSpeechCancelsAPendingReplay() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.stopSpeech, .pressed)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertEqual(speech.stopCount, 1)
        withExtendedLifetime(controller) {}
    }

    func testToggleAutoReadHotkeyPersistsWithoutPushingDefinitions() {
        let hotkeys = SpyHotkeyManager()
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(runtime.settingsController.current.autoReadEnabled)
        XCTAssertEqual(hotkeys.updates.count, 1)
        withExtendedLifetime(controller) {}
    }
}
```
Delete from `AppModelTests.swift`: plan 1's `testTwoQuickReadSelectionPressesSpeakOnlyOnce`, `testTwoQuickReplayPressesReplayOnlyOnce`, `testStopSpeechCancelsAPendingReplay`, and `testReadSelectionReleasedDoesNothing`, `testStopAndReplayOnlyActWhenPressed`, `testHoldToTalkStartsOnPressAndFinishesOnRelease`, `testToggleDictationAlternatesOnPressAndIgnoresRelease`, `testHoldToTalkQueuesReleaseUntilBlockedStartCompletes`, `testToggleQueuesNewPressUntilBlockedFinishCompletes`, `testToggleAutoReadPersistsWithoutReregisteringHotkeys`, `testRegistrationFailureSurfacesActionableStatus`.

- [ ] **Step 6: Implement** — `Relay/App/HotkeyController.swift`:

```swift
import Foundation
import Observation

/// Global hotkey wiring: pushes definitions to the manager, dispatches matched actions, and
/// serializes dictation start/finish so a release never overtakes a slow start.
@MainActor
@Observable
final class HotkeyController {
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")

    @ObservationIgnored private let manager: any HotkeyManaging
    @ObservationIgnored private let settings: SettingsController
    @ObservationIgnored private let dictation: (any DictationCoordinating)?
    @ObservationIgnored private let speechActions: SpeechActions
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    /// The in-flight Read Selection / Replay Last action. Each new press of either hotkey, and
    /// Stop Speech, cancels it, so two quick presses can never both reach the speech coordinator.
    @ObservationIgnored private var speechActionTask: Task<Void, Never>?

    init(runtime: RelayRuntime, speechActions: SpeechActions) {
        manager = runtime.hotkeyManager
        settings = runtime.settingsController
        dictation = runtime.speechIn.dictationCoordinator
        self.speechActions = speechActions
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
        manager.setHandler { [weak self] action, phase in
            self?.handle(action, phase: phase)
        }
    }

    deinit {
        dictationTask?.cancel()
        speechActionTask?.cancel()
    }

    func start() {
        manager.update(definitions: settings.current.hotkeys)
        ensureTap()
    }

    /// Called by `SettingsController.onHotkeysChanged`.
    func definitionsChanged(_ definitions: [HotkeyAction: HotkeyDefinition]) {
        manager.update(definitions: definitions)
    }

    /// Retries the event tap (e.g. after Accessibility is granted) without touching the matcher.
    func ensureTap() {
        let status = manager.ensureTap()
        eventTapStatus = status
        if case let .unavailable(message) = status {
            statusSink.post(message)
        }
    }

    private func handle(_ action: HotkeyAction, phase: HotkeyPhase) {
        if action == .dictate {
            diagnostics.record(.actionDispatched(action: action, phase: phase))
            dictationPhase = phase
            guard dictation != nil else { return }
            switch settings.current.dictationMode {
            case .holdToTalk:
                if phase == .pressed { enqueueDictation { await $0.start() } }
                else { enqueueDictation { await $0.finish() } }
            case .toggle:
                guard phase == .pressed else { return }
                enqueueDictation { await $0.toggle() }
            }
            return
        }
        guard phase == .pressed else { return }
        diagnostics.record(.actionDispatched(action: action, phase: phase))

        switch action {
        case .dictate:
            break
        case .readSelection:
            runSpeechAction { await $0.readSelection() }
        case .stopSpeech:
            speechActionTask?.cancel()
            speechActionTask = nil
            speechActions.stopSpeech()
        case .replayLast:
            runSpeechAction { await $0.replayLast() }
        case .toggleAutoRead:
            settings.toggleAutoRead()
        }
    }

    /// Replaces any in-flight speech action. The cancelled one re-checks `Task.isCancelled`
    /// before speaking (inside `SpeechActions`), so it never reaches the speech coordinator.
    private func runSpeechAction(_ operation: @escaping @MainActor (SpeechActions) async -> Void) {
        speechActionTask?.cancel()
        let actions = speechActions
        speechActionTask = Task {
            guard !Task.isCancelled else { return }
            await operation(actions)
        }
    }

    private func enqueueDictation(_ operation: @escaping @MainActor (any DictationCoordinating) async -> Void) {
        let previous = dictationTask
        let coordinator = dictation
        dictationTask = Task { @MainActor in
            await previous?.value
            guard let coordinator else { return }
            await operation(coordinator)
        }
    }
}
```

- [ ] **Step 7: Trim `AppModel`.** Delete `dictationPhase`, `eventTapStatus`, `dictationTask` and `speechActionTask` (and their `deinit` lines), `registerHotkeys`, `handleHotkey`, `startSpeechAction`, `enqueueDictation`, and the `hotkeyManager`/`dictationCoordinator` accessors. Add `@ObservationIgnored let hotkeys: HotkeyController`. In `init`, after `speechActions`:
```swift
        hotkeys = HotkeyController(runtime: runtime, speechActions: speechActions)
```
and replace `settingsController.onHotkeysChanged = { [weak self] _ in self?.registerHotkeys() }` + `registerHotkeys()` with:
```swift
        settingsController.onHotkeysChanged = { [weak hotkeys = self.hotkeys] definitions in
            hotkeys?.definitionsChanged(definitions)
        }
        hotkeys.start()
```
`recheckDiagnostics()`: replace `registerHotkeys()` with `hotkeys.ensureTap()`.

- [ ] **Step 8: View.** `DiagnosticsView`: `model.eventTapStatus` → `model.hotkeys.eventTapStatus`.

- [ ] **Step 9: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**
```bash
git add Relay/App/HotkeyController.swift Relay/System/GlobalHotkeyManager.swift Relay/App/AppModel.swift \
  Relay/App/DiagnosticsView.swift RelayTests/App/HotkeyControllerTests.swift \
  RelayTests/System/GlobalHotkeyManagerTests.swift RelayTests/Support/RelayRuntime+Testing.swift \
  RelayTests/App/AppModelTests.swift RelayTests/App/AppModelHotkeySideEffectTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "fix(hotkeys): keep in-flight gestures across activation rechecks; extract HotkeyController"
```

---

## Task 9: `PermissionsModel` + one observer/deinit pattern

**Findings:** Permission snapshot, mic, privacy panes, login item and the activation observer live in `AppModel`. `AppModel.deinit` (601–605) reads MainActor state (`activationObserver: NSObjectProtocol?`, non-Sendable) from a nonisolated deinit; `ActivityOverlayWindowController` (90, 107–111, 227–238) works around the same problem with `nonisolated(unsafe)`.

**Fix (one pattern for both):** a self-removing `NotificationObservation` token (`@unchecked Sendable`, removes itself in its own `deinit`). Owners just hold it; no owner `deinit`, no `nonisolated(unsafe)`. Chosen over Swift 6.2 `isolated deinit` because it doesn't depend on the toolchain's language-mode feature set (project is Swift 6.0 mode) and is directly unit-testable.

**Files:**
- Create: `Relay/System/NotificationObservation.swift`, `Relay/App/PermissionsModel.swift`, `RelayTests/System/NotificationObservationTests.swift`, `RelayTests/App/PermissionsModelTests.swift`
- Modify: `Relay/App/AppModel.swift`, `Relay/App/ActivityOverlayWindowController.swift`, views `PermissionsSettingsView`, `GeneralSettingsView`, `DiagnosticsView`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1: Failing tests** — `RelayTests/System/NotificationObservationTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class NotificationObservationTests: XCTestCase {
    private let name = Notification.Name("relay.test.notification")

    func testHandlerRunsWhileTheTokenIsAlive() async {
        let center = NotificationCenter()
        let counter = Counter()
        let observation = NotificationObservation(center: center, name: name) { counter.value += 1 }

        center.post(name: name, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while counter.value == 0, Date() < deadline { await Task.yield() }

        XCTAssertEqual(counter.value, 1)
        withExtendedLifetime(observation) {}
    }

    func testReleasingTheTokenStopsDelivery() async {
        let center = NotificationCenter()
        let counter = Counter()
        var observation: NotificationObservation? = NotificationObservation(center: center, name: name) { counter.value += 1 }
        XCTAssertNotNil(observation)

        observation = nil
        center.post(name: name, object: nil)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(counter.value, 0)
    }
}

@MainActor
private final class Counter {
    var value = 0
}
```

`RelayTests/App/PermissionsModelTests.swift` (moves the permission/login tests out of `AppModelTests`):

```swift
import XCTest
@testable import Relay

@MainActor
final class PermissionsModelTests: XCTestCase {
    private func makeModel(
        permissions: SpyPermissionService = SpyPermissionService(),
        microphone: SpyMicrophonePermission = SpyMicrophonePermission(granted: true),
        opener: SpyPrivacyOpener = SpyPrivacyOpener(),
        loginItem: SpyLoginItemController = SpyLoginItemController(enabled: false),
        diagnostics: DiagnosticsRecorder = DiagnosticsRecorder(capacity: 10)
    ) -> (model: PermissionsModel, runtime: RelayRuntime) {
        let runtime = RelayRuntime.testing(
            permissionService: permissions,
            microphonePermissions: microphone,
            privacySettingsOpener: opener,
            loginItemService: loginItem,
            diagnostics: diagnostics
        )
        return (PermissionsModel(runtime: runtime), runtime)
    }

    func testRecheckRefreshesSnapshotAndMicrophoneAndRecordsDiagnostic() {
        let permissions = SpyPermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let microphone = SpyMicrophonePermission(granted: false)
        let (model, runtime) = makeModel(permissions: permissions, microphone: microphone)
        XCTAssertFalse(model.microphoneGranted)

        microphone.grantedValue = true
        model.recheck()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertTrue(model.microphoneGranted)
        XCTAssertFalse(model.snapshot.inputMonitoringGranted)
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .permissionRechecked)
    }

    func testRequestMicrophoneRefreshesStateAndAnnounces() async {
        let microphone = SpyMicrophonePermission(granted: false, requestResult: true)
        let (model, runtime) = makeModel(microphone: microphone)

        await model.requestMicrophone()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(model.microphoneGranted)
        XCTAssertEqual(runtime.status.message, "Microphone permission granted")
    }

    func testRequestAccessibilityDelegatesAndRefreshesSnapshot() {
        let permissions = SpyPermissionService()
        let (model, runtime) = makeModel(permissions: permissions)

        model.requestAccessibility()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .permissionRequested)
    }

    func testPrivacyPanesOpenThroughTheInjectedOpener() {
        let opener = SpyPrivacyOpener()
        let (model, _) = makeModel(opener: opener)

        model.openPrivacySettings(.accessibility)
        model.openMicrophoneSettings()

        XCTAssertEqual(opener.opened, [.accessibility, .microphone])
    }

    func testLastMicrophoneCaptureDiagnosticsPassesThroughTheRecorder() {
        let recorder = DiagnosticsRecorder(capacity: 10)
        let (model, _) = makeModel(diagnostics: recorder)
        XCTAssertNil(model.lastMicrophoneCaptureDiagnostics)
        let record = MicrophoneCaptureDiagnostics(inputSampleRate: 48_000, frameCount: 0, capturedAt: Date(timeIntervalSince1970: 1))

        recorder.recordMicrophoneCapture(record)

        XCTAssertEqual(model.lastMicrophoneCaptureDiagnostics, record)
    }

    func testLaunchAtLoginReflectsServiceAndUpdatesOnSuccess() {
        let loginItem = SpyLoginItemController(enabled: false)
        let (model, _) = makeModel(loginItem: loginItem)
        XCTAssertFalse(model.launchAtLoginEnabled)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testLaunchAtLoginFailureKeepsActualStatusAndAnnounces() {
        let loginItem = SpyLoginItemController(enabled: false, setEnabledError: CancellationError())
        let (model, runtime) = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(runtime.status.message, "Could not change launch-at-login.")
    }

    func testActivationNotificationRunsTheHandler() async {
        let center = NotificationCenter()
        let (model, _) = makeModel()
        let activations = ActivationCounter()
        model.observeActivation(center: center) { activations.value += 1 }

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while activations.value == 0, Date() < deadline { await Task.yield() }

        XCTAssertEqual(activations.value, 1)
    }
}

/// A reference the escaping `@MainActor` activation closure can mutate (no captured `var`).
@MainActor
private final class ActivationCounter {
    var value = 0
}
```
Add `import AppKit` at the top of this file (for `NSApplication`).

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/NotificationObservationTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'NotificationObservation' in scope`.

- [ ] **Step 3: Implement** — `Relay/System/NotificationObservation.swift`:

```swift
import Foundation

/// A NotificationCenter block observer that removes itself when released. Owners just hold the
/// token; they need no `deinit` of their own (which, on a `@MainActor` class, is nonisolated and
/// can't safely read the non-Sendable observer handle).
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    /// `handler` runs on the main actor (the observer is registered on the main queue).
    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
```

`Relay/App/PermissionsModel.swift`:

```swift
import AppKit
import Observation

/// Permissions and startup settings for the Security/General tabs and Diagnostics: the global
/// permission snapshot, microphone, privacy panes, login item, and the app-activation hook that
/// triggers a recheck.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var snapshot: PermissionSnapshot
    private(set) var microphoneGranted: Bool
    /// Mirrors the OS login-item registration; never persisted separately.
    private(set) var launchAtLoginEnabled: Bool

    /// Privacy-safe metadata of the last capture (never audio/text/paths).
    var lastMicrophoneCaptureDiagnostics: MicrophoneCaptureDiagnostics? {
        diagnostics.lastMicrophoneCaptureDiagnostics
    }

    @ObservationIgnored private let permissionService: any GlobalPermissionAuthorizing
    @ObservationIgnored private let microphone: any MicrophonePermissionStatusProviding
    @ObservationIgnored private let opener: any PrivacySettingsOpening
    @ObservationIgnored private let loginItems: any LoginItemControlling
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var activationObservation: NotificationObservation?

    init(runtime: RelayRuntime) {
        permissionService = runtime.permissionService
        microphone = runtime.microphonePermissions
        opener = runtime.privacySettingsOpener
        loginItems = runtime.loginItemService
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
        snapshot = runtime.permissionService.snapshot()
        microphoneGranted = runtime.microphonePermissions.isGranted()
        launchAtLoginEnabled = runtime.loginItemService.isEnabled
    }

    /// Runs `onActivate` every time Relay becomes active, for as long as this model lives.
    func observeActivation(center: NotificationCenter = .default, _ onActivate: @escaping @MainActor () -> Void) {
        activationObservation = NotificationObservation(
            center: center,
            name: NSApplication.didBecomeActiveNotification,
            handler: onActivate
        )
    }

    func recheck() {
        snapshot = permissionService.snapshot()
        microphoneGranted = microphone.isGranted()
        diagnostics.record(.permissionRechecked)
    }

    func requestAccessibility() {
        permissionService.requestPermissions()
        diagnostics.record(.permissionRequested)
        snapshot = permissionService.snapshot()
    }

    func requestMicrophone() async {
        _ = await microphone.requestPermission()
        microphoneGranted = microphone.isGranted()
        statusSink.post(microphoneGranted
            ? "Microphone permission granted"
            : "Allow Microphone permission in System Settings to dictate.")
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        opener.open(pane)
    }

    /// One-click fix for a stale post-rebuild microphone grant.
    func openMicrophoneSettings() {
        opener.open(.microphone)
    }

    /// On failure (e.g. a dev build outside /Applications) re-reads the real status instead of
    /// drifting, and posts a non-fatal message.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = loginItems.isEnabled
            statusSink.post("Could not change launch-at-login.")
        }
    }
}
```

- [ ] **Step 4: `AppModel`.** Delete `microphonePermissionGranted`, `launchAtLoginEnabled`, `permissionSnapshot`, `lastMicrophoneCaptureDiagnostics`, `activationObserver`, `requestPermissions`, `requestMicrophonePermission`, `openPrivacySettings`, `openMicrophoneSettings`, `setLaunchAtLogin`, `observeAppActivation`, the whole `deinit`, and the permission/mic/opener/login accessors. Add `@ObservationIgnored let permissions: PermissionsModel`, built first in `init` after `settingsController`: `permissions = PermissionsModel(runtime: runtime)`; replace `observeAppActivation()` with:
```swift
        permissions.observeActivation { [weak self] in self?.recheckDiagnostics() }
```
`recheckDiagnostics()` becomes:
```swift
    func recheckDiagnostics() {
        permissions.recheck()
        hotkeys.ensureTap()
        Task { [weak self] in await self?.sttBackendList.refresh() }
    }
```

- [ ] **Step 5: `ActivityOverlayWindowController`.** Replace `private nonisolated(unsafe) var screenParametersObserver: NSObjectProtocol?` with `private var screenParametersObservation: NotificationObservation?`, delete its `deinit`, and replace `observeScreenParameterChanges()` with:
```swift
    private func observeScreenParameterChanges() {
        screenParametersObservation = NotificationObservation(
            name: NSApplication.didChangeScreenParametersNotification
        ) { [weak self] in
            self?.relayoutForScreenChange()
        }
    }
```

- [ ] **Step 6: Views.**
```bash
sed -i '' \
  -e 's/model\.microphonePermissionGranted/model.permissions.microphoneGranted/g' \
  -e 's/model\.requestMicrophonePermission()/model.permissions.requestMicrophone()/g' \
  -e 's/model\.openPrivacySettings(/model.permissions.openPrivacySettings(/g' \
  -e 's/model\.permissionSnapshot/model.permissions.snapshot/g' \
  -e 's/model\.requestPermissions()/model.permissions.requestAccessibility()/g' \
  -e 's/model\.openMicrophoneSettings()/model.permissions.openMicrophoneSettings()/g' \
  -e 's/model\.lastMicrophoneCaptureDiagnostics/model.permissions.lastMicrophoneCaptureDiagnostics/g' \
  Relay/App/Settings/PermissionsSettingsView.swift Relay/App/DiagnosticsView.swift
sed -i '' -e 's/model\.launchAtLoginEnabled/model.permissions.launchAtLoginEnabled/' \
          -e 's/model\.setLaunchAtLogin(/model.permissions.setLaunchAtLogin(/' \
  Relay/App/Settings/GeneralSettingsView.swift
sed -i '' 's/model\.lastMicrophoneCaptureDiagnostics/model.permissions.lastMicrophoneCaptureDiagnostics/g' \
  RelayTests/App/SettingsViewsSmokeTests.swift
```

- [ ] **Step 7: Remove moved tests** from `AppModelTests.swift`: `testRecheckRefreshesObservableMicrophonePermissionAfterExternalChange`, `testRequestMicrophonePermissionRefreshesObservableState`, `testOpenPrivacySettingsDelegatesToInjectedOpener`, `testOpenMicrophoneSettingsDelegatesToInjectedOpenerExactlyOnce`, `testLastMicrophoneCaptureDiagnosticsIsNilBeforeAnyCapture`, `testLastMicrophoneCaptureDiagnosticsReflectsRecorderState`, the five `testLaunchAtLogin…`/`testSetLaunchAtLogin…` tests. In `testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot` change `model.permissionSnapshot` → `model.permissions.snapshot`.

- [ ] **Step 8: Verify the pattern is uniform**

Run: `grep -rn "nonisolated(unsafe)\|removeObserver\|deinit" Relay/App`
Expected: only `HotkeyController.deinit` (cancels a `Sendable` `Task`).

- [ ] **Step 9: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**
```bash
git add Relay/System/NotificationObservation.swift Relay/App/PermissionsModel.swift Relay/App/AppModel.swift \
  Relay/App/ActivityOverlayWindowController.swift Relay/App/Settings/PermissionsSettingsView.swift \
  Relay/App/Settings/GeneralSettingsView.swift Relay/App/DiagnosticsView.swift \
  RelayTests/System/NotificationObservationTests.swift RelayTests/App/PermissionsModelTests.swift \
  RelayTests/App/AppModelTests.swift RelayTests/App/SettingsViewsSmokeTests.swift \
  Relay.xcodeproj/project.pbxproj
git commit -m "refactor(app): extract PermissionsModel and use self-removing notification tokens"
```

---

## Task 10: `SpeechBackendsModel` (single refresh owner) + final facade

**Findings:** Backend readiness and model lists are refreshed from six places: two init tasks, `SettingsView.task` (STT list only), `DictationSettingsView.task` (models only), `TTSSettingsView.task` (list + models), `recheckDiagnostics` (STT list only), plus `SpeechModelController`'s post-init `configureHooks` callback into `AppModel`. Which call refreshes what is inconsistent (opening Dictation refreshes models but not readiness), and the hook is a second post-init wiring step.

**Fix:** `SpeechBackendsModel` owns the `SpeechModelController`, both `BackendListModel`s and the `SpeechVoiceCatalog`, and is the **only** thing anything calls to refresh: `refresh(_ domain:)` (readiness then models) and `refreshAll()`. `SpeechModelController` takes its two hooks as `init` parameters (closures over the already-built lists, never over `self`), so `configureHooks` is deleted. `selectVoice` moves here. `AppModel` is then rewritten as the final facade.

**Files:**
- Create: `Relay/App/SpeechBackendsModel.swift`, `RelayTests/App/SpeechBackendsModelTests.swift`
- Modify: `Relay/App/SpeechModelController.swift`, `Relay/App/AppModel.swift` (rewritten), `Relay/App/Settings/DictationSettingsView.swift`, `Relay/App/Settings/TTSSettingsView.swift`, `Relay/App/Settings/SettingsView.swift`
- Modify tests: `RelayTests/App/SpeechModelControllerTests.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1: Failing tests** — `RelayTests/App/SpeechBackendsModelTests.swift`:

```swift
import XCTest
@testable import Relay

@MainActor
final class SpeechBackendsModelTests: XCTestCase {
    private func makeModel(
        store: SpySettingsStore = SpySettingsStore(),
        speech: SpySpeechCoordinator = SpySpeechCoordinator(),
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:]
    ) -> SpeechBackendsModel {
        SpeechBackendsModel(runtime: .testing(
            settingsStore: store,
            speechCoordinator: speech,
            sttRegistry: sttRegistry,
            speechModelManagers: speechModelManagers,
            ttsModelManagers: ttsModelManagers
        ))
    }

    func testRefreshingADomainUpdatesReadinessAndModelsTogether() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])

        await model.refresh(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: "a")]?.map(\.id), ["tiny"])
        XCTAssertTrue(model.textToSpeech.rows.isEmpty)
    }

    func testRefreshAllCoversBothDomains() async {
        let manager = StubModelManager(backendID: "kokoro", modelIDs: ["v1"])
        let model = makeModel(
            sttRegistry: ["a": StubSTTBackend(id: "a")],
            ttsModelManagers: ["kokoro": manager]
        )

        await model.refreshAll()

        XCTAssertEqual(model.dictation.rows.map(\.id), ["a"])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")]?.map(\.id), ["v1"])
    }

    /// Selecting a model changes readiness; the controller's hook must refresh the owning list.
    func testSelectingAModelRefreshesThatDomainsReadiness() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])
        await model.refresh(.dictation)

        await backend.setAvailability(.available)
        await model.models.select("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: "a"))

        XCTAssertEqual(model.dictation.rows.map(\.state), [.ready])
    }

    /// The activation recheck only needs readiness; it must not re-list models.
    func testRefreshingReadinessLeavesModelListsAlone() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])

        await model.refreshReadiness(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertNil(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: "a")])
    }

    func testRemovingATTSModelStopsSpeechFirst() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: "kokoro", modelIDs: ["v1"])
        let model = makeModel(speech: speech, ttsModelManagers: ["kokoro": manager])

        await model.models.remove("v1", in: SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro"))

        XCTAssertEqual(speech.stopCount, 1)
    }

    func testRemovingADictationModelDoesNotStopSpeech() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(speech: speech, speechModelManagers: ["a": manager])

        await model.models.remove("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: "a"))

        XCTAssertEqual(speech.stopCount, 0)
    }

    func testBackendListsPersistOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, sttRegistry: ["a": StubSTTBackend(id: "a"), "b": StubSTTBackend(id: "b")])
        await model.refresh(.dictation)

        model.dictation.setEnabled("b", true)

        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
    }

    func testSelectVoicePersistsThroughTheCatalogMapping() {
        let store = SpySettingsStore()
        let model = makeModel(store: store)

        model.selectVoice(backendID: BackendID.appleTTS.rawValue, voiceID: "apple:default")

        // The default option maps to "no stored voice" — and it is still a persisted write.
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertNil(store.saved.last?.voiceByBackend[BackendID.appleTTS.rawValue])
    }
}

private actor StubSTTBackend: SpeechToTextBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    private var availabilityValue: BackendAvailability

    init(id: String, availability: BackendAvailability = .available) {
        self.id = id
        displayName = id
        availabilityValue = availability
    }

    func setAvailability(_ value: BackendAvailability) { availabilityValue = value }
    func availability() async -> BackendAvailability { availabilityValue }
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        throw SpeechBackendError.unavailable("stub")
    }
}

private actor StubModelManager: SpeechModelManaging {
    nonisolated let backendID: String
    private var statuses: [SpeechModelStatus]

    init(backendID: String, modelIDs: [String]) {
        self.backendID = backendID
        statuses = modelIDs.map {
            SpeechModelStatus(
                descriptor: .init(id: $0, displayName: $0, detail: nil),
                capabilities: [.download, .select, .remove],
                installState: .downloaded,
                isSelected: false
            )
        }
    }

    func models() async -> [SpeechModelStatus] { statuses }
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func removeModel(_ id: String) async throws {}
    func selectModel(_ id: String) async throws {
        for index in statuses.indices { statuses[index].isSelected = statuses[index].id == id }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/SpeechBackendsModelTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'SpeechBackendsModel' in scope`.

- [ ] **Step 3: Hooks become init parameters** in `SpeechModelController.swift`. Delete `configureHooks(...)`; make the two stored hooks `let`; replace `init` with:
```swift
    init(
        managers: Managers,
        diagnostics: DiagnosticsRecorder,
        refreshBackends: @escaping BackendRefresh = { _ in },
        beforeRemoval: @escaping PreRemoval = { _ in }
    ) {
        self.managers = managers
        self.diagnostics = diagnostics
        self.refreshBackends = refreshBackends
        self.beforeRemoval = beforeRemoval
    }
```
In `SpeechModelControllerTests`, the three tests that call `controller.configureHooks(refreshBackends: X, beforeRemoval: Y)` move those two closures into the constructor: `SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder(), refreshBackends: X, beforeRemoval: Y)`, and the `configureHooks` call is deleted. In `testSelectRefreshesModelsAndOwningBackend` and `testPartialRemovalFailureReconcilesModelsAndBackendReadiness`, the `var refreshedDomains` local and its `refreshBackends: { refreshedDomains.append($0) }` closure move into the constructor unchanged (this compiles today: the closure type is `@MainActor`).

- [ ] **Step 4: Implement** — `Relay/App/SpeechBackendsModel.swift`:

```swift
import Foundation

/// Everything Settings shows about speech backends: per-domain readiness lists, per-backend model
/// lists, and the voice catalog. The single owner of refreshing them — views, launch and the
/// activation recheck all go through `refresh(_:)` / `refreshAll()`.
@MainActor
final class SpeechBackendsModel {
    let dictation: BackendListModel
    let textToSpeech: BackendListModel
    let models: SpeechModelController
    let voices: SpeechVoiceCatalog

    private let settings: SettingsController

    init(runtime: RelayRuntime, voices: SpeechVoiceCatalog = SpeechVoiceCatalog()) {
        let settings = runtime.settingsController
        self.settings = settings
        self.voices = voices
        let dictation = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechIn.sttRegistry),
            order: { settings.current.sttBackendOrder },
            setOrder: { settings.setSTTBackendOrder($0) },
            refusalMessage: "At least one speech recognition backend must stay enabled.",
            statusSink: runtime.status
        )
        let textToSpeech = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechOut.ttsRegistry),
            order: { settings.current.ttsBackendOrder },
            setOrder: { settings.setTTSBackendOrder($0) },
            refusalMessage: "At least one TTS backend must stay enabled.",
            statusSink: runtime.status
        )
        let speechCoordinator = runtime.speechOut.speechCoordinator
        self.dictation = dictation
        self.textToSpeech = textToSpeech
        models = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers
            ),
            diagnostics: runtime.diagnostics,
            refreshBackends: { domain in
                switch domain {
                case .dictation: await dictation.refresh()
                case .textToSpeech: await textToSpeech.refresh()
                }
            },
            beforeRemoval: { key in
                // Never delete a TTS model out from under an utterance that is streaming from it.
                if key.domain == .textToSpeech { speechCoordinator.stop() }
            }
        )
    }

    func list(for domain: SpeechModelDomain) -> BackendListModel {
        switch domain {
        case .dictation: dictation
        case .textToSpeech: textToSpeech
        }
    }

    /// Readiness first (cheap, drives row state), then the model lists.
    func refresh(_ domain: SpeechModelDomain) async {
        await refreshReadiness(domain)
        await models.refresh(domain: domain)
    }

    /// Readiness rows only — for the app-activation recheck, where a permission change can flip
    /// a backend's readiness but cannot change which models are on disk.
    func refreshReadiness(_ domain: SpeechModelDomain) async {
        await list(for: domain).refresh()
    }

    /// Launch-time refresh. Sequential on purpose: dictation, then TTS. The old code ran the two
    /// domains as two concurrent tasks; on the main actor they interleaved anyway, and one
    /// ordered task is simpler to await in tests. Worst case the TTS rows appear after the
    /// dictation probes finish (a few hundred ms at launch, before Settings is usually open).
    func refreshAll() async {
        await refresh(.dictation)
        await refresh(.textToSpeech)
    }

    func selectVoice(backendID: String, voiceID: String) {
        guard let value = voices.storedValue(for: voiceID, backendID: backendID) else { return }
        settings.setVoice(value, for: backendID)
    }

    private static func modelManagers(
        dictation: [String: any SpeechModelManaging],
        textToSpeech: [String: any SpeechModelManaging]
    ) -> SpeechModelController.Managers {
        var result: SpeechModelController.Managers = [:]
        for (backendID, manager) in dictation {
            result[SpeechModelBackendKey(domain: .dictation, backendID: backendID)] = manager
        }
        for (backendID, manager) in textToSpeech {
            result[SpeechModelBackendKey(domain: .textToSpeech, backendID: backendID)] = manager
        }
        return result
    }
}
```
(`BackendRefresh`/`PreRemoval` stay `@MainActor @Sendable (…) async -> Void`. Capturing the two `BackendListModel`s (`@MainActor` classes, so `Sendable`) and the non-`Sendable` `any SpeechCoordinating` is legal in a `@MainActor` closure built on the main actor — `SpeechModelControllerTests` already captures a mutable local `var refreshedDomains` in these same closure types. No `nonisolated(unsafe)` or `weak` needed.)

- [ ] **Step 5: Rewrite `Relay/App/AppModel.swift`** as the final facade (replace the whole file). Keep plan 1's behavior anywhere this differs only by an extra line (e.g. an extra launch step in `init`):

```swift
@preconcurrency import AppKit
import Observation

/// The object every SwiftUI scene binds to. A thin facade: it builds the focused sub-models from
/// one `RelayRuntime`, retains that runtime for the app's lifetime, and exposes the sub-models
/// for views to call (`model.speechBackends.refresh(.dictation)`, `model.permissions.recheck()`).
/// Only values read almost everywhere (`settings`, `statusText`) and the diagnostics pass-throughs
/// live directly on it.
@MainActor
@Observable
final class AppModel {
    /// The graph this model was built from. Retained for the model's (= the app's) lifetime.
    @ObservationIgnored let runtime: RelayRuntime
    @ObservationIgnored let settingsController: SettingsController
    @ObservationIgnored let permissions: PermissionsModel
    @ObservationIgnored let integrationSetup: IntegrationSetupModel
    @ObservationIgnored let speechBackends: SpeechBackendsModel
    @ObservationIgnored let speechActions: SpeechActions
    @ObservationIgnored let hotkeys: HotkeyController
    /// Launch-time backend/model refresh; exposed so tests can await it.
    @ObservationIgnored private(set) var initialBackendRefresh: Task<Void, Never>?

    /// Read-only settings for views; writes go through `settingsController`.
    var settings: AppSettings { settingsController.current }
    /// The last transient status message (`StatusSink`).
    var statusText: String { runtime.status.message }
    var overlayModel: ActivityOverlayModel { runtime.speechOut.overlayModel }

    /// Menu-bar status: live activity (same source as the overlay pill), else the last message.
    /// Reads `overlayModel.state`, which is itself `@Observable`, so the menu updates live.
    var activityStatusText: String {
        switch overlayModel.state {
        case .listening: "Listening…"
        case .processing: "Transcribing…"
        case .preparingSpeech: "Processing…"
        case .speaking: "Speaking…"
        case let .error(_, _, message): message
        case .hidden: statusText
        }
    }

    // MARK: Diagnostics pass-throughs (DiagnosticsView)

    var diagnosticsEntries: [DiagnosticEntry] { runtime.diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { runtime.diagnostics.counters }
    var diagnosticsCopyText: String { runtime.diagnostics.copyText }
    func clearDiagnostics() { runtime.diagnostics.clear() }

    /// Integration-pipeline diagnostics, newest first. Structural only — never response text,
    /// cwd, paths, environment, raw error text, or `providerSessionID`.
    func integrationDiagnosticsEntries() -> [IntegrationDiagnosticsEntry] {
        runtime.integrationDiagnosticsLog.snapshot()
    }

    func clearIntegrationDiagnostics() { runtime.integrationDiagnosticsLog.clear() }

    // MARK: Lifecycle

    /// The only initializer. Production passes `RelayRuntime.makeProduction()`; tests pass
    /// `RelayRuntime.testing(...)`.
    init(runtime: RelayRuntime) {
        self.runtime = runtime
        settingsController = runtime.settingsController
        permissions = PermissionsModel(runtime: runtime)
        integrationSetup = IntegrationSetupModel(runtime: runtime)
        speechBackends = SpeechBackendsModel(runtime: runtime)
        speechActions = SpeechActions(runtime: runtime, voiceCatalog: speechBackends.voices)
        hotkeys = HotkeyController(runtime: runtime, speechActions: speechActions)

        settingsController.onHotkeysChanged = { [weak hotkeys] definitions in
            hotkeys?.definitionsChanged(definitions)
        }
        hotkeys.start()
        permissions.observeActivation { [weak self] in self?.recheckDiagnostics() }
        bindOverlayPresenter()
        initialBackendRefresh = Task { [speechBackends] in await speechBackends.refreshAll() }
    }

    /// Runs on every app activation and from the Diagnostics "Recheck" button: re-reads
    /// permissions, retries the event tap (without touching hotkey gesture state) and re-probes
    /// speech-recognition readiness (a granted mic can make Apple Speech ready).
    func recheckDiagnostics() {
        permissions.recheck()
        hotkeys.ensureTap()
        Task { [speechBackends] in await speechBackends.refreshReadiness(.dictation) }
    }

    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
        settingsController.setActivityOverlayStyle(style)
        runtime.speechOut.overlayPresenter.update(state: overlayModel.state, style: style)
    }

    private func bindOverlayPresenter() {
        let presenter = runtime.speechOut.overlayPresenter
        let settings = settingsController
        overlayModel.setStateHandler { state in
            presenter.update(state: state, style: settings.current.activityOverlayStyle)
        }
    }
}

/// Default presenter for tests and any composition that doesn't host the overlay panel.
@MainActor
final class NoOpActivityOverlayPresenter: ActivityOverlayPresenting {
    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {}
}

extension HotkeyAction {
    var title: String {
        switch self {
        case .dictate: "Dictate"
        case .readSelection: "Read Selection"
        case .stopSpeech: "Stop Speech"
        case .replayLast: "Replay Last"
        case .toggleAutoRead: "Toggle Auto-read"
        }
    }
}
```
The last two declarations are carried over verbatim from the bottom of the current `AppModel.swift` (`NoOpActivityOverlayPresenter` is used by `RelayRuntime+Testing.swift`; `HotkeyAction.title` by `SettingsController`, `KeybindsSettingsView` and `Diagnostics.swift`). The file keeps `@preconcurrency import AppKit` as its AppKit import, as today.

- [ ] **Step 6: Views.**
`DictationSettingsView.swift`:
```swift
            SpeechBackendSettingsSection(
                title: "Speech Recognition",
                backends: model.speechBackends.dictation.rows,
                domain: .dictation,
                controller: model.speechBackends.models,
                message: model.speechBackends.models.messages[.dictation] ?? model.speechBackends.dictation.message,
                setEnabled: model.speechBackends.dictation.setEnabled,
                move: model.speechBackends.dictation.move
            ) { _ in EmptyView() }
```
and `.task { await model.speechBackends.refresh(.dictation) }`.

`TTSSettingsView.swift`: `backends: model.speechBackends.textToSpeech.rows`, `controller: model.speechBackends.models`, `message: model.speechBackends.models.messages[.textToSpeech] ?? model.speechBackends.textToSpeech.message`, `setEnabled: model.speechBackends.textToSpeech.setEnabled`, `move: model.speechBackends.textToSpeech.move`; every `model.voiceCatalog` → `model.speechBackends.voices`; `model.selectVoice(` → `model.speechBackends.selectVoice(`; the `.task` body becomes `await model.speechBackends.refresh(.textToSpeech)`.

`SettingsView.swift`: delete the `.task { … }` modifier (each tab refreshes its own domain).

- [ ] **Step 7: Retarget tests.**
```bash
sed -i '' \
  -e 's/initialSpeechBackendRefresh/initialBackendRefresh/g' \
  -e 's/initialTTSBackendRefresh/initialBackendRefresh/g' \
  -e 's/model\.sttBackendList/model.speechBackends.dictation/g' \
  -e 's/model\.ttsBackendList/model.speechBackends.textToSpeech/g' \
  -e 's/model\.modelController/model.speechBackends.models/g' \
  -e 's/model\.voiceCatalog/model.speechBackends.voices/g' \
  -e 's/model\.selectVoice(/model.speechBackends.selectVoice(/g' \
  RelayTests/App/AppModelTests.swift RelayTests/App/SettingsViewsSmokeTests.swift
```
Delete `testBackendListsReadAndPersistOrderThroughSettings` from `AppModelTests.swift` (moved to `SpeechBackendsModelTests`). That test is the last `initialSpeechBackendRefresh` user in `AppModelTests` (Task 5 deleted the others; `ProjectSmokeTests`' back-to-back awaits went in Task 1, `TTSBackendCatalogTests` in Task 5), so the two `initial…Refresh` seds are a safety net and normally match nothing.

- [ ] **Step 8: Check the size and the hooks**

Run: `wc -l Relay/App/AppModel.swift && grep -rn "configureHooks\|refreshSpeechBackendStatuses\|refreshTTSBackendStatuses" Relay RelayTests`
Expected: fewer than 250 lines (≈150); grep prints nothing.

- [ ] **Step 9: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**
```bash
git add Relay/App/SpeechBackendsModel.swift Relay/App/SpeechModelController.swift Relay/App/AppModel.swift \
  Relay/App/Settings/DictationSettingsView.swift Relay/App/Settings/TTSSettingsView.swift \
  Relay/App/Settings/SettingsView.swift RelayTests/App/SpeechBackendsModelTests.swift \
  RelayTests/App/SpeechModelControllerTests.swift RelayTests/App/AppModelTests.swift \
  RelayTests/App/SettingsViewsSmokeTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(app): give speech backends one refresh owner and reduce AppModel to a facade"
```

**Post-implementation note (review follow-up):** `apple-tts` has no entry in `SpeechBackendGraph.ttsModelManagers` (`SpeechBackendGraphTests.testRegistersConcreteTextToSpeechBackendsAndOnlyModelBackedManagers` asserts `graph.ttsModelManagers["apple-tts"]` is `nil`), so `SpeechModelController` never holds a `SpeechModelBackendKey(domain: .textToSpeech, backendID: "apple-tts")` and its download/select/remove failure diagnostics (`speechModelDownloadFailed`, `speechModelSelectionFailed`, `speechModelRemovalFailed`, etc.) can never fire for it. `BackendID.appleTTS.displayName` is `"Apple System Voice"` (`Relay/Domain/BackendID.swift`), so if a model manager is ever added for `apple-tts`, those diagnostics strings would read "Apple System Voice model download failed" and so on — currently unreachable, not a bug, just worth knowing before relying on those strings appearing for Apple TTS.

---

## Task 11: Clipboard reentrancy, one key-command type, AX dedupe, selection permission error

**Findings:**
1. `ClipboardService.copyCurrentSelection()` waits via `RunLoopClipboardWaiter` — a **nested run loop** on the main thread. Hotkeys, timers and notifications run inside it, so a second Read Selection (or a paste-fallback insertion) can reenter mid-copy, snapshot Relay's temporary pasteboard content as the "original" and restore it last — permanently replacing the user's clipboard.
2. The `defer` restores **unconditionally**: if the user (or another app) writes the clipboard during the 200 ms window, Relay overwrites that newer content.
3. `SystemCopyCommand` / `SystemPasteCommand` are identical except the virtual key.
4. `focusedElementValue()` is implemented twice (`SystemAccessibilityElementAccessor`, `SystemAccessibilityTextInserter`), and the `CFGetTypeID … as! AXUIElement` cast twice (`AccessibilityService`, `TextInsertionService`).
5. Without Accessibility/post-event permission, Read Selection says *"No selected text found"*, sending the user to fix the wrong thing.

**Fix:** Selection reading becomes `async`: the waiter sleeps with `Task.sleep` (no nested run loop), an in-flight copy rejects a reentrant one (`ClipboardCopyError.busy`), and the restore runs only if the pasteboard's `changeCount` is still the one the copy produced (or unchanged). One `SystemKeyCommand` serves both protocols. One `SystemAccessibility.focusedElement()` helper. `SelectionReader` reports `.accessibilityPermissionDenied` when neither path can work.

**Files:**
- Modify: `Relay/System/ClipboardService.swift`, `Relay/System/SelectionReader.swift`, `Relay/System/AccessibilityService.swift`, `Relay/System/TextInsertionService.swift`, `Relay/App/SpeechActions.swift`, `Relay/App/RelayRuntime.swift`
- Modify tests: `RelayTests/System/ClipboardServiceTests.swift`, `RelayTests/System/SelectionReaderTests.swift`, `RelayTests/Support/RelayRuntime+Testing.swift`, `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1: Failing clipboard tests.** In `ClipboardServiceTests.swift`: make the three existing copy tests `async throws` and call `try await service.copyCurrentSelection()` (`XCTAssertThrowsError` → `do { _ = try await …; XCTFail() } catch {}`); make `FakeClipboardWaiter.wait` `async`. In `testCopiesAfterChangeAndRestoresOriginalClipboard` nothing else changes (the copy bumped the count to 5 and it is still 5 at restore). In `testWaitsAtMostTwoHundredMillisecondsWhenClipboardDoesNotChange` change the restore expectation to `XCTAssertEqual(pasteboard.restoredSnapshots, [])` — **fix**: nothing was copied, the clipboard is still the user's, so there is nothing to restore. Add:

```swift
    func testDoesNotRestoreOverContentWrittenAfterTheCopy() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 4, snapshot: original, copiedString: "selected")
        let waiter = FakeClipboardWaiter { pasteboard.changeCount = 5 }
        pasteboard.onString = { pasteboard.changeCount = 6 } // user copies something else meanwhile
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: FakeCopyCommand(), waiter: waiter)

        XCTAssertEqual(try await service.copyCurrentSelection(), "selected")
        XCTAssertEqual(pasteboard.restoredSnapshots, [], "newer clipboard content must not be overwritten")
    }

    func testRejectsAReentrantCopyWhileOneIsInFlight() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "selected")
        let gate = WaitGate()
        let waiter = FakeClipboardWaiter(gate: gate) { pasteboard.changeCount = 2 }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: FakeCopyCommand(), waiter: waiter)

        let first = Task { try await service.copyCurrentSelection() }
        while !gate.isWaiting { await Task.yield() }
        do {
            _ = try await service.copyCurrentSelection()
            XCTFail("reentrant copy must be rejected")
        } catch {
            XCTAssertEqual(error as? ClipboardCopyError, .busy)
        }
        gate.open()

        XCTAssertEqual(try await first.value, "selected")
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }
```
Update the fakes at the bottom of the file:
```swift
@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboard {
    var changeCount: Int
    let snapshotValue: ClipboardSnapshot
    let copiedString: String?
    var onString: () -> Void = {}
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []

    init(changeCount: Int, snapshot: ClipboardSnapshot, copiedString: String?) {
        self.changeCount = changeCount
        self.snapshotValue = snapshot
        self.copiedString = copiedString
    }

    func snapshot() -> ClipboardSnapshot { snapshotValue }
    func string() -> String? { onString(); return copiedString }
    func write(string: String, ownershipToken: Data) -> Bool { true }
    func restore(_ snapshot: ClipboardSnapshot) { restoredSnapshots.append(snapshot) }
    func restore(_ snapshot: ClipboardSnapshot, ifOwnedBy ownershipToken: Data) {}
}

@MainActor
private final class WaitGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeClipboardWaiter: ClipboardWaiting {
    private let gate: WaitGate?
    private let onWait: () -> Void
    private(set) var waitedMilliseconds: [Int] = []

    init(gate: WaitGate? = nil, onWait: @escaping () -> Void = {}) {
        self.gate = gate
        self.onWait = onWait
    }

    func wait(milliseconds: Int) async {
        waitedMilliseconds.append(milliseconds)
        if let gate, waitedMilliseconds.count == 1 { await gate.wait() }
        onWait()
    }
}
```

- [ ] **Step 2: Failing selection tests.** In `SelectionReaderTests.swift`: every test becomes `async throws`, `try reader.readSelection()` → `try await reader.readSelection()`, `XCTAssertThrowsError(try …) { error in … }` → `do { _ = try await …; XCTFail("expected error") } catch { … }`; `FakeClipboardSelection.copyCurrentSelection()` becomes `async throws`. Every `SelectionReader(accessibility:clipboard:)` call gains `canReadSelection: { true }`. Add:

```swift
    func testReportsMissingPermissionInsteadOfNoSelection() async {
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: FakeClipboardSelection(value: nil),
            canReadSelection: { false }
        )

        do {
            _ = try await reader.readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SelectionReadingError, .accessibilityPermissionDenied)
            XCTAssertEqual(
                error.localizedDescription,
                "Relay needs Accessibility permission to read selected text. Enable it in System Settings › Privacy & Security › Accessibility."
            )
        }
    }

    func testWithoutPermissionTheClipboardFallbackIsNotAttempted() async {
        let clipboard = FakeClipboardSelection(value: "fallback")
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: clipboard,
            canReadSelection: { false }
        )

        _ = try? await reader.readSelection()

        XCTAssertEqual(clipboard.copySelectionCallCount, 0)
    }

    func testABusyClipboardReportsNoSelectionRatherThanCrashingOrHanging() async {
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: FakeClipboardSelection(value: nil, error: ClipboardCopyError.busy),
            canReadSelection: { true }
        )

        do {
            _ = try await reader.readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SelectionReadingError, .noUsableSelection)
        }
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ClipboardServiceTests -only-testing:RelayTests/SelectionReaderTests 2>&1 | tail -30`
Expected: build FAILS — `cannot find 'ClipboardCopyError' in scope`.

- [ ] **Step 4: `ClipboardService.swift`.**
1. Protocols:
```swift
@MainActor
protocol ClipboardWaiting {
    /// Suspends (never blocks or pumps a nested run loop) for about `milliseconds`.
    func wait(milliseconds: Int) async
}
```
   and delete `CopyCommandSending`'s separate error enum usage (see 3).
2. `ClipboardService`:
```swift
enum ClipboardCopyError: Error, Equatable {
    /// Another copy is still waiting for the pasteboard; running a second one would snapshot
    /// Relay's own temporary content as the user's "original".
    case busy
}

@MainActor
final class ClipboardService: ClipboardReading {
    private let pasteboard: any ClipboardPasteboard
    private let copyCommand: any CopyCommandSending
    private let waiter: any ClipboardWaiting
    private var isCopying = false

    init(
        pasteboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        copyCommand: any CopyCommandSending = SystemKeyCommand.copy,
        waiter: any ClipboardWaiting = SleepingClipboardWaiter()
    ) {
        self.pasteboard = pasteboard
        self.copyCommand = copyCommand
        self.waiter = waiter
    }

    /// Sends ⌘C, waits up to 200 ms for the pasteboard to change, reads the string, then puts the
    /// user's clipboard back — but only if nothing else has written it since the copy landed.
    func copyCurrentSelection() async throws -> String? {
        guard !isCopying else { throw ClipboardCopyError.busy }
        isCopying = true
        defer { isCopying = false }

        let original = pasteboard.snapshot()
        let originalChangeCount = pasteboard.changeCount
        try copyCommand.sendCopy()

        for _ in 0..<10 {
            await waiter.wait(milliseconds: 20)
            let copiedChangeCount = pasteboard.changeCount
            guard copiedChangeCount != originalChangeCount else { continue }
            let copied = pasteboard.string()
            // A later write (the user copying, another app) wins over our restore.
            if pasteboard.changeCount == copiedChangeCount {
                pasteboard.restore(original)
            }
            return copied
        }
        // The copy never landed: the clipboard is still the user's; nothing to restore.
        return nil
    }
}
```
   (`defer` restore removed. If `sendCopy()` throws, the pasteboard was never touched, so the old "restore on throw" was a no-op rewrite of identical content; `testRestoresClipboardWhenSendingCopyThrows` changes its assertion to `XCTAssertEqual(pasteboard.restoredSnapshots, [])` and is renamed `testSendingCopyFailureLeavesTheClipboardUntouched`.)
3. Replace `CopyCommandError`, `SystemCopyCommand`, `SystemPasteCommand` with:
```swift
enum KeyCommandError: Error {
    case eventCreationFailed
}

/// Posts ⌘+`virtualKey` as genuine-looking user input. The combined session source attributes
/// these synthetic events like real keystrokes, so target apps accept them.
@MainActor
struct SystemKeyCommand: CopyCommandSending, PasteCommandSending {
    static let copy = SystemKeyCommand(virtualKey: 8)  // kVK_ANSI_C
    static let paste = SystemKeyCommand(virtualKey: 9) // kVK_ANSI_V

    let virtualKey: CGKeyCode

    func sendCopy() throws { try post() }
    func sendPaste() throws { try post() }

    private func post() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            throw KeyCommandError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
```
4. Replace `RunLoopClipboardWaiter` with:
```swift
@MainActor
struct SleepingClipboardWaiter: ClipboardWaiting {
    func wait(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
```
`TextInsertionService.swift`: default `pasteCommand: any PasteCommandSending = SystemKeyCommand.paste`.

- [ ] **Step 5: `SelectionReader.swift`.**
```swift
@MainActor
protocol SelectionReading {
    func readSelection() async throws -> SelectionResult
}

@MainActor
protocol ClipboardReading {
    func copyCurrentSelection() async throws -> String?
}

enum SelectionReadingError: Error, Equatable, LocalizedError {
    case noUsableSelection
    case accessibilityPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noUsableSelection:
            "No selected text found. Select text and try again."
        case .accessibilityPermissionDenied:
            "Relay needs Accessibility permission to read selected text. Enable it in System Settings › Privacy & Security › Accessibility."
        }
    }
}

@MainActor
final class SelectionReader: SelectionReading {
    private let accessibility: any AccessibilityReading
    private let clipboard: any ClipboardReading
    private let canReadSelection: () -> Bool

    /// - Parameter canReadSelection: whether Relay may read the AX tree or post ⌘C at all
    ///   (Accessibility trust). Checked only after the AX read came back empty.
    init(
        accessibility: any AccessibilityReading,
        clipboard: any ClipboardReading,
        canReadSelection: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.canReadSelection = canReadSelection
    }

    func readSelection() async throws -> SelectionResult {
        if let selection = usable(accessibility.selectedText()) {
            return .init(text: selection, source: .accessibility)
        }
        guard canReadSelection() else {
            throw SelectionReadingError.accessibilityPermissionDenied
        }
        do {
            if let selection = usable(try await clipboard.copyCurrentSelection()) {
                return .init(text: selection, source: .clipboard)
            }
        } catch {
            throw SelectionReadingError.noUsableSelection
        }
        throw SelectionReadingError.noUsableSelection
    }

    // usable(_:) unchanged
}
```
Add `import ApplicationServices` at the top (for `AXIsProcessTrusted`).

- [ ] **Step 6: AX dedupe** — in `AccessibilityService.swift` add, above `SystemAccessibilityElementAccessor`:
```swift
/// The one place Relay reads the system-wide focused UI element.
@MainActor
enum SystemAccessibility {
    static func focusedElementValue() -> CFTypeRef? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success else { return nil }
        return focusedValue
    }

    /// Narrows an AX attribute value to an element, or `nil` if it is some other CF type.
    static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
```
Then: `SystemAccessibilityElementAccessor.focusedElementValue()` body → `SystemAccessibility.focusedElementValue()`; `SystemAccessibilityTextInserter.focusedElementValue()` body → same; `AccessibilityService.selectedText()` →
```swift
    func selectedText() -> String? {
        guard let element = SystemAccessibility.element(from: accessor.focusedElementValue()) else { return nil }
        return accessor.selectedText(from: element)
    }
```
and in `TextInsertionService.insertViaAccessibility` replace the first `guard … as! AXUIElement` pair with `guard let focusedElement = SystemAccessibility.element(from: accessibility.focusedElementValue()) else { return false }`. Test fakes are unaffected (the protocols didn't change).

- [ ] **Step 7: Callers.** `SpeechActions.readSelection()`: `let selection = try selectionReader.readSelection()` → `let selection = try await selectionReader.readSelection()`. In `RelayTests/Support/RelayRuntime+Testing.swift`, `SpySelectionReader.readSelection()` becomes `func readSelection() async throws -> SelectionResult`. `SettingsViewsSmokeTests` constructs `SelectionReader(accessibility: AccessibilityService(), clipboard: ClipboardService())` — unchanged (default `canReadSelection`). `RelayRuntime.makeProduction()` is unchanged (defaults).

- [ ] **Step 8: Verify the old names are gone**

Run: `grep -rn "RunLoopClipboardWaiter\|SystemCopyCommand\|SystemPasteCommand\|CopyCommandError\|RunLoop.current.run" Relay RelayTests`
Expected: no output.

- [ ] **Step 9: Full suite** → `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**
```bash
git add Relay/System/ClipboardService.swift Relay/System/SelectionReader.swift Relay/System/AccessibilityService.swift \
  Relay/System/TextInsertionService.swift Relay/App/SpeechActions.swift \
  RelayTests/System/ClipboardServiceTests.swift RelayTests/System/SelectionReaderTests.swift \
  RelayTests/Support/RelayRuntime+Testing.swift
git commit -m "fix(selection): stop clipboard copy reentrancy and clobbering; report missing permission"
```

---

## Task 12: Small cleanups

Each sub-step is independent, has its own test run, and is committed on its own.

### 12.1 Menu status text is a pure function of the overlay state

**Finding:** `AppModel.activityStatusText`'s mapping is only testable through a whole `AppModel`.

- [ ] Add to `RelayTests/App/ActivityOverlayModelTests.swift`:
```swift
    func testMenuStatusTextMapsEveryState() {
        let id = UUID()
        let now = Date()
        let cases: [(ActivityOverlayState, String)] = [
            (.hidden, "Ready"),
            (.listening(sessionID: id, startedAt: now, level: 0), "Listening…"),
            (.processing(sessionID: id, startedAt: now), "Transcribing…"),
            (.preparingSpeech(sessionID: id, startedAt: now), "Processing…"),
            (.speaking(sessionID: id, startedAt: now, level: nil), "Speaking…"),
            (.error(sessionID: id, category: .microphone, message: "Mic unavailable"), "Mic unavailable"),
        ]
        for (state, expected) in cases {
            XCTAssertEqual(state.menuStatusText(idle: "Ready"), expected, "state: \(state)")
        }
    }
```
- [ ] Run `-only-testing:RelayTests/ActivityOverlayModelTests` → build FAILS (`has no member 'menuStatusText'`).
- [ ] In `ActivityOverlayModel.swift` add:
```swift
extension ActivityOverlayState {
    /// The menu-bar line for this state; `idle` is shown when nothing is happening.
    func menuStatusText(idle: String) -> String {
        switch self {
        case .listening: "Listening…"
        case .processing: "Transcribing…"
        case .preparingSpeech: "Processing…"
        case .speaking: "Speaking…"
        case let .error(_, _, message): message
        case .hidden: idle
        }
    }
}
```
  and in `AppModel` replace the body of `activityStatusText` with `overlayModel.state.menuStatusText(idle: statusText)` (keep the doc comment).
- [ ] Run the class → `** TEST SUCCEEDED **`. Commit:
```bash
git add Relay/App/ActivityOverlayModel.swift Relay/App/AppModel.swift RelayTests/App/ActivityOverlayModelTests.swift
git commit -m "refactor(overlay): make the menu status text a pure function of overlay state"
```

### 12.2 Overlay actions without a single-conformer protocol

**Finding:** `ActivityOverlayControlling` has one conformer, `ActivityOverlayActionDispatcher`, which holds `weak` references to objects the runtime already owns for the app's lifetime, and fires cancel in an unstructured `Task` even though the panel's `onAction` is already `async`.

- [ ] `git mv RelayTests/App/ActivityOverlayActionDispatcherTests.swift RelayTests/App/ActivityOverlayActionsTests.swift`; in it rename the class to `ActivityOverlayActionsTests` and replace the two `let dispatcher = …` / `dispatcher.perform(…)` pairs with a direct awaited call, dropping the `await Task.yield()`:
```swift
        await ActivityOverlayActions.perform(.cancelDictation(sessionID: sessionID), dictation: dictation, speech: speech)
```
  (second test: `.stopSpeech(sessionID: sessionID)`, and mark it `async`).
- [ ] Run `xcodegen generate` then `-only-testing:RelayTests/ActivityOverlayActionsTests` → build FAILS (`cannot find 'ActivityOverlayActions'`).
- [ ] `git rm Relay/App/ActivityOverlayActionDispatcher.swift`; create `Relay/App/ActivityOverlayActions.swift`:
```swift
import Foundation

/// Routes the overlay panel's Interactive-style buttons to the coordinator that owns the session.
/// Free of AppKit and backend logic; the panel awaits it directly.
@MainActor
enum ActivityOverlayActions {
    static func perform(
        _ action: ActivityOverlayAction,
        dictation: (any DictationCoordinating)?,
        speech: any SpeechCoordinating
    ) async {
        switch action {
        case let .cancelDictation(sessionID):
            await dictation?.cancel(sessionID: sessionID)
        case let .stopSpeech(sessionID):
            speech.stop(sessionID: sessionID)
        }
    }
}
```
  In `RelayRuntime.makeProduction()` delete the `actionDispatcher` line and pass
```swift
            onAction: { action in
                await ActivityOverlayActions.perform(action, dictation: dictation, speech: coordinator)
            }
```
  (`dictation` is the concrete `DictationCoordinator` local and `coordinator` the `SpeechCoordinator` local already in scope; the runtime owns all three for the app's life, so strong captures are correct.)
  In `RelayTests/App/AppModelTests.swift` (~107) the doc comment of `testActivityStatusTextReturnsToIdleAfterOverlayHidesFollowingPillStop` names `ActivityOverlayActionDispatcher`; change it to `ActivityOverlayActions.perform`. Then `grep -rn "ActivityOverlayActionDispatcher\|ActivityOverlayControlling" Relay RelayTests` prints nothing.
- [ ] Class run → `** TEST SUCCEEDED **`. Commit:
```bash
git add Relay/App/ActivityOverlayActions.swift Relay/App/ActivityOverlayActionDispatcher.swift Relay/App/RelayRuntime.swift \
  RelayTests/App/ActivityOverlayActionsTests.swift RelayTests/App/ActivityOverlayActionDispatcherTests.swift \
  RelayTests/App/AppModelTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(overlay): replace the single-conformer action dispatcher with a function"
```

### 12.3 Overlay seams in their own file

**Finding:** `ActivityOverlayWindowController.swift` opens with 60 lines of protocols/value types (`ActivityOverlayPresenting`, `ActivityOverlayScreen`, `ActivityOverlayScreenProviding`, `ActivityOverlayPanelHosting`, `ActivityOverlayPlacement`) that `ActivityOverlayPanelHost.swift` and tests use independently of the controller.

- [ ] Create `Relay/App/ActivityOverlayHosting.swift` starting with `import CoreGraphics` / `import Foundation` and **move** (cut, unchanged, with doc comments) those five declarations into it. Leave `NoOpActivityOverlayPresenter` wherever it currently is.
- [ ] `xcodegen generate && xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ActivityOverlayWindowControllerTests 2>&1 | tail -30` → `** TEST SUCCEEDED **` (pure move).
- [ ] Commit:
```bash
git add Relay/App/ActivityOverlayHosting.swift Relay/App/ActivityOverlayWindowController.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(overlay): move overlay hosting seams out of the window controller"
```

### 12.4 `PermissionService` on the main actor

**Finding:** `GlobalPermissionAuthorizing` is `@MainActor` but `PermissionService`, `NativePermissionChecking` and `SystemNativePermissions` are not; the conformance only compiles because the class is non-`Sendable` and never crosses actors. AX/TCC preflight calls belong on main.

- [ ] Mark `protocol NativePermissionChecking`, `final class PermissionService` and `final class SystemNativePermissions` `@MainActor`. Mark any fake conforming to `NativePermissionChecking` in `RelayTests` `@MainActor` too (`grep -rn "NativePermissionChecking" RelayTests`).
- [ ] Full suite → `** TEST SUCCEEDED **` with no new warnings. Commit:
```bash
git add Relay/System/PermissionService.swift $(grep -rln "NativePermissionChecking" RelayTests)
git commit -m "refactor(permissions): isolate PermissionService to the main actor"
```
  (The `$(grep …)` expands to explicit test paths; check `git status` shows nothing else staged.)

### 12.5 One default for the STT backend order

**Finding:** `AppSettings.init(from:)` already normalizes an empty/unknown `sttBackendOrder` to the default and `BackendListModel` refuses to disable the last backend, yet `makeProduction()`'s `STTRouter` closure re-filters and re-defaults (`configured.isEmpty ? [BackendID.appleSpeech.rawValue] : configured`). The TTS router reads its order directly. `STTRouter` already skips ids missing from its registry.

- [ ] Add to `RelayTests/SpeechIn/STTRouterTests.swift`:
```swift
    func testUnknownIDsInTheOrderAreSkipped() async throws {
        let known = FakeSTTBackend(id: "known")
        let router = STTRouter(backends: ["known": known], backendOrder: { ["ghost", "known"] })

        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(known.transcriptionCount, 1)
    }
```
  (`audio` is the class's existing `private let audio` fixture; `FakeSTTBackend` is the file's own.) Run the class → PASS (documents the router guarantee the simplification relies on).
- [ ] In `RelayRuntime.makeProduction()` replace the `STTRouter` `backendOrder:` closure with `backendOrder: { settings.value.sttBackendOrder }`.
- [ ] Full suite → `** TEST SUCCEEDED **`. Commit:
```bash
git add Relay/App/RelayRuntime.swift RelayTests/SpeechIn/STTRouterTests.swift
git commit -m "refactor(speech-in): read the STT order from settings like the TTS order"
```

### 12.6 `DiagnosticsBuffer` as a ring buffer

**Finding:** `DiagnosticsBuffer.append` calls `removeFirst` on every append once the buffer is full — O(capacity) per event. Plan 1 Task 2 stopped recording every keystroke (and left the buffer as is), so appends are now rarer, but every matched hotkey, dispatch and speech event still pays the shift once 250 entries exist.

- [ ] Add to `RelayTests/System/DiagnosticsTests.swift`:
```swift
    func testBufferKeepsTheNewestEntriesInOrderAcrossManyWraps() {
        var buffer = DiagnosticsBuffer(capacity: 3)
        for index in 0..<10 {
            buffer.append(.settingsDecodeFailed(byteCount: index))
        }
        XCTAssertEqual(buffer.entries.map(\.event), [
            .settingsDecodeFailed(byteCount: 7),
            .settingsDecodeFailed(byteCount: 8),
            .settingsDecodeFailed(byteCount: 9),
        ])

        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
        buffer.append(.permissionRechecked)
        XCTAssertEqual(buffer.entries.map(\.event), [.permissionRechecked])
    }
```
  Run the class → PASS on the old implementation too (it pins behavior before the rewrite).
- [ ] Replace `DiagnosticsBuffer` with:
```swift
struct DiagnosticsBuffer: Sendable {
    private var storage: [DiagnosticEntry] = []
    /// Index of the oldest entry once `storage` is full.
    private var head = 0
    private let capacity: Int

    init(capacity: Int = 250) { self.capacity = max(1, capacity) }

    /// Oldest first.
    var entries: [DiagnosticEntry] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    mutating func append(_ event: DiagnosticsEvent) {
        let entry = DiagnosticEntry(event: event)
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[head] = entry
            head = (head + 1) % capacity
        }
    }

    mutating func clear() {
        storage.removeAll()
        head = 0
    }

    var copyText: String { entries.map { $0.event.message }.joined(separator: "\n") }
}
```
- [ ] `-only-testing:RelayTests/DiagnosticsTests` → `** TEST SUCCEEDED **`. Commit:
```bash
git add Relay/System/Diagnostics.swift RelayTests/System/DiagnosticsTests.swift
git commit -m "perf(diagnostics): make DiagnosticsBuffer a ring buffer"
```

---

## Task 13: Final verification

- [ ] **Step 1: Size target**

Run: `wc -l Relay/App/AppModel.swift`
Expected: under 250.

- [ ] **Step 2: Structural greps** (each should print nothing)
```bash
grep -rn "makeProduction" RelayTests
grep -rn "setStatusHandler\|configureHooks\|SettingsBox\|WhisperSelectionCache\|BackendCatalog" Relay RelayTests
grep -rn "nonisolated(unsafe)" Relay/App
grep -rn "RunLoop.current.run" Relay
grep -rn "convenience init" Relay/App/AppModel.swift
```

- [ ] **Step 3: Full clean build and suite**
```bash
xcodegen generate
xcodebuild clean build -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "warning:|error:|BUILD" | sort -u | tail -20
xcodebuild test -scheme Relay -derivedDataPath /tmp/relay-dd-cleanup5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` with no warnings that aren't also on `main` (compare against the Task 0 baseline), then `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual smoke** (signed Debug build from Xcode; see memory notes on stale Accessibility/mic grants after a rebuild):
  1. Launch — the menu shows "Ready"; Settings → Dictation and TTS show backend rows with readiness and models.
  2. Hold the dictation hotkey, speak, release → text inserts; the overlay shows Listening → Transcribing.
  3. Select text in another app, press Read Selection → it is spoken; the clipboard afterwards still holds what it held before.
  4. Press Read Selection twice quickly → no clipboard corruption (paste afterwards gives the original clipboard).
  5. Start a chord (press the first key of a two-key chord), switch to Relay and back, finish the chord → the action fires (Task 8 fix).
  6. Drag the speech-rate slider → `defaults read dev.relaymac.Relay.debug` is written once after release, not per tick.
  7. Pick a Kokoro voice, quit and relaunch → the voice is still selected (schema v2 round-trip); a pre-upgrade settings blob keeps its voices (Task 6 migration).
  8. Replay Last in a focused agent terminal → that session's reply; in a non-agent app → the last spoken text.

- [ ] **Step 5: Branch state**

Run: `git status --short && git log --oneline main..HEAD`
Expected: a clean tree; one commit per task/sub-step, conventional messages, none containing `Co-Authored-By`, `Claude-Session` or "Generated with Claude Code":
```bash
git log --format=%B main..HEAD | grep -Ei "co-authored-by|claude-session|generated with" && echo "FOUND ATTRIBUTION — reword those commits" || echo "clean"
```
Expected: `clean`.

- [ ] **Step 6: Hand off** — push the branch and open the PR only when the user asks; the PR body ends at its last bullet with no generated-by footer.
