# Unified Speech Model Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Dictation- and TTS-specific model settings code with one shared controller and one shared UI, add safe Kokoro/PocketTTS deletion, and colocate selectable/testable voices with their providers.

**Architecture:** A main-actor `SpeechModelController` owns all model lifecycle state and operations for both speech domains, keyed by domain plus backend/model IDs. Reusable SwiftUI provider/model/voice rows consume provider-neutral presentation values; provider-specific voice catalogs and TTS filesystem deletion remain behind adapters. `AppModel` wires domain-specific backend refresh and stop-before-remove hooks without reimplementing lifecycle algorithms.

**Tech Stack:** Swift 6, SwiftUI Observation, XCTest, AVFoundation, FluidAudio 0.15.7, XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-21-unified-speech-model-settings-design.md`

## Global Constraints

- Downloads remain explicit; selection must never trigger a download.
- Model and voice selection remain separate concepts.
- Persisted keys `ttsVoiceIdentifier`, `kokoroVoice`, and `pocketVoice` remain unchanged.
- Backend enablement, ordering, fallback, and global speech rate remain unchanged.
- Removal may delete only the exact provider-owned model directories described in the spec.
- User-facing errors and diagnostics must not contain raw filesystem paths, provider errors, transcript text, or preview text.
- Apple-owned assets and Parakeet remain non-removable.

## Review Focus

- A stale refresh completing after a download/remove must not resurrect an older state; Task 2 adds generation-race tests for both domains.
- Removing while a TTS model is loaded or downloading must release/cancel before deleting; Task 3 adds actor ordering tests.
- Testing an inactive voice must use that exact provider/voice without persisting it or falling back; Task 4 adds router/coordinator/AppModel tests.
- Default `nil` voice settings must map to exactly one visible Active voice; Task 4 adds default-selection catalog tests.
- Disabled actions must remain visible for unsupported or invalid states; Task 5 adds exhaustive presentation-state tests and both-tab construction tests.

---

### Task 1: Make model operation capabilities explicit

**Files:**
- Modify: `Relay/Domain/SpeechModelManaging.swift`
- Modify: `Relay/Backends/AppleSpeechModelManager.swift`
- Modify: `Relay/Backends/ParakeetModelManager.swift`
- Modify: `Relay/Backends/Whisper/WhisperModelManager.swift`
- Modify: `Relay/Backends/KokoroModelManager.swift`
- Modify: `Relay/Backends/PocketTTSModelManager.swift`
- Modify: every test helper constructing `SpeechModelStatus`
- Test: `RelayTests/Domain/SpeechModelManagingTests.swift`
- Test: manager tests under `RelayTests/Backends/`

**Interfaces:**
- Produces: `SpeechModelCapabilities`, stored on every `SpeechModelStatus`.
- Produces: `SpeechModelManaging.models()` as the sole source of per-model operation support.

- [ ] **Step 1: Write failing capability contract tests**

Add assertions in each manager's existing test file, reusing that file's local fake engine. Keep the expectations explicit:

```swift
XCTAssertEqual(appleRows.first?.capabilities, [.select])
XCTAssertEqual(parakeetRows.first?.capabilities, [.download, .select])
XCTAssertEqual(kokoroRows.first?.capabilities, [.download, .select, .remove])
XCTAssertEqual(pocketRows.first?.capabilities, [.download, .select, .remove])
XCTAssertTrue(whisperRows.allSatisfy {
    $0.capabilities == [.download, .select, .remove]
})
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SpeechModelManagingTests -only-testing:RelayTests/AppleSpeechModelManagerTests -only-testing:RelayTests/ParakeetModelManagerTests -only-testing:RelayTests/WhisperModelManagerTests -only-testing:RelayTests/KokoroModelManagerTests -only-testing:RelayTests/PocketTTSModelManagerTests test
```

Expected: compilation fails because `SpeechModelCapabilities` and `SpeechModelStatus.capabilities` do not exist.

- [ ] **Step 3: Add the capability value and populate every adapter**

Implement:

```swift
struct SpeechModelCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let download = Self(rawValue: 1 << 0)
    static let select = Self(rawValue: 1 << 1)
    static let remove = Self(rawValue: 1 << 2)
}

struct SpeechModelStatus: Identifiable, Equatable, Sendable {
    let descriptor: SpeechModelDescriptor
    let capabilities: SpeechModelCapabilities
    var installState: SpeechModelInstallState
    var isSelected: Bool
    var isLoaded: Bool
    var id: String { descriptor.id }
}
```

Populate the production values from the table in the spec. Update test helpers to pass deliberate capabilities rather than relying on a default, so tests remain explicit about supported operations.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Relay/Domain/SpeechModelManaging.swift Relay/Backends RelayTests
git commit -m "refactor(models): make lifecycle capabilities explicit"
```

### Task 2: Introduce the shared model lifecycle controller

**Files:**
- Create: `Relay/App/SpeechModelController.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/SpeechBackendCatalog.swift`
- Modify: `Relay/App/TTSBackendCatalog.swift`
- Modify: `Relay/System/Diagnostics.swift`
- Create: `RelayTests/App/SpeechModelControllerTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`
- Modify: `RelayTests/App/TTSBackendCatalogTests.swift`

**Interfaces:**
- Consumes: `SpeechModelStatus.capabilities` from Task 1.
- Produces: `SpeechModelDomain`, `SpeechModelBackendKey`, and `SpeechModelController`.
- Produces: `AppModel.modelController` as the only Settings-facing model state/action interface.

- [ ] **Step 1: Write failing controller tests with a two-domain fake registry**

Define the wished-for interface in tests:

```swift
enum SpeechModelDomain: Hashable, Sendable { case dictation, textToSpeech }

struct SpeechModelBackendKey: Hashable, Sendable {
    let domain: SpeechModelDomain
    let backendID: String
}

@MainActor
@Observable
final class SpeechModelController {
    private(set) var models: [SpeechModelBackendKey: [SpeechModelStatus]]
    private(set) var messages: [SpeechModelDomain: String]

    func refresh(domain: SpeechModelDomain) async
    func download(_ modelID: String, in backend: SpeechModelBackendKey) async
    func select(_ modelID: String, in backend: SpeechModelBackendKey) async
    func remove(_ modelID: String, in backend: SpeechModelBackendKey) async
}
```

Tests must cover:

```swift
func testSameBackendIDInDifferentDomainsDoesNotCollide() async
func testStaleRefreshCannotOverwriteNewerRefresh() async
func testDownloadProgressIsMonotonicAndDuplicateDownloadIsIgnored() async
func testDownloadDoesNotSelectModel() async
func testSelectRefreshesModelsAndOwningBackend() async
func testRemoveRunsPreRemovalThenManagerThenRefreshes() async
func testFailedSelectAndRemovePreserveRowsAndPublishStableMessages() async
```

Use event arrays to assert the removal ordering is exactly `pre-remove`, `manager-remove`, `model-refresh`, `backend-refresh`.

- [ ] **Step 2: Run the controller tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SpeechModelControllerTests test
```

Expected: compilation fails because the shared controller types do not exist.

- [ ] **Step 3: Implement the controller as the deep lifecycle module**

Use this initializer so domain variation is supplied once:

```swift
@MainActor
@Observable
final class SpeechModelController {
    typealias Managers = [SpeechModelBackendKey: any SpeechModelManaging]
    typealias BackendRefresh = @MainActor @Sendable (SpeechModelDomain) async -> Void
    typealias PreRemoval = @MainActor @Sendable (SpeechModelBackendKey) async -> Void

    private(set) var models: [SpeechModelBackendKey: [SpeechModelStatus]] = [:]
    private(set) var messages: [SpeechModelDomain: String] = [:]

    init(managers: Managers, diagnostics: DiagnosticsRecorder)
    func configureHooks(
        refreshBackends: @escaping BackendRefresh,
        beforeRemoval: @escaping PreRemoval
    )

    func refresh(domain: SpeechModelDomain) async
    func download(_ modelID: String, in backend: SpeechModelBackendKey) async
    func select(_ modelID: String, in backend: SpeechModelBackendKey) async
    func remove(_ modelID: String, in backend: SpeechModelBackendKey) async
}
```

Internally key in-flight downloads by a typed `(SpeechModelBackendKey, modelID)` value, retain generation counters per domain, merge only in-flight/failed live rows, clamp progress to monotonic `[0, 1]`, and emit stable messages such as `"Kokoro model removal failed. Try again."` without raw errors.

Add diagnostics cases for select/remove success and failure using only backend IDs. Do not duplicate separate STT and TTS branches inside the controller.

- [ ] **Step 4: Wire AppModel to one controller and remove lifecycle implementations from both catalogs**

Construct typed manager keys from `speechModelManagers` and `ttsModelManagers`. Initialize the controller without capturing a partially initialized `AppModel`, then configure its hooks after all stored properties are initialized:

```swift
modelController = SpeechModelController(
    managers: modelManagers,
    diagnostics: diagnostics
)

modelController.configureHooks(
    refreshBackends: { [weak self] domain in
        switch domain {
        case .dictation: await self?.refreshSpeechBackendStatuses()
        case .textToSpeech: await self?.refreshTTSBackendStatuses()
        }
    },
    beforeRemoval: { [weak self] key in
        if key.domain == .textToSpeech { self?.speechCoordinator.stop() }
    }
)
```

Delete `speechModels`, `downloadingModelKeys`, `speechModelsRefreshGeneration`, both backend-level `downloadSpeechModel(_:)`/`downloadTTSModel(_:)` methods, and the per-model methods in `SpeechBackendCatalog.swift`. Keep the backend availability/order catalogs focused only on backend concerns.

- [ ] **Step 5: Run controller and migrated AppModel tests**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SpeechModelControllerTests -only-testing:RelayTests/AppModelTests -only-testing:RelayTests/TTSBackendCatalogTests test
```

Expected: all selected tests pass, and no test calls the removed domain-specific model lifecycle methods.

- [ ] **Step 6: Commit**

```bash
git add Relay/App/SpeechModelController.swift Relay/App/AppModel.swift Relay/App/SpeechBackendCatalog.swift Relay/App/TTSBackendCatalog.swift Relay/System/Diagnostics.swift RelayTests/App
git commit -m "refactor(models): unify speech model lifecycle state"
```

### Task 3: Implement safe Kokoro and PocketTTS model deletion

**Files:**
- Modify: `Relay/Backends/FluidAudioKokoroEngine.swift`
- Modify: `Relay/Backends/FluidAudioPocketTTSEngine.swift`
- Modify: `Relay/Backends/KokoroModelManager.swift`
- Modify: `Relay/Backends/PocketTTSModelManager.swift`
- Modify: `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`
- Modify: `RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift`
- Modify: `RelayTests/Backends/KokoroModelManagerTests.swift`
- Modify: `RelayTests/Backends/PocketTTSModelManagerTests.swift`

**Interfaces:**
- Consumes: `.remove` capability from Task 1 and controller removal from Task 2.
- Produces: `removeModels() async throws` on both TTS engine and loader seams.

- [ ] **Step 1: Write failing loader deletion tests against temporary directories**

For Kokoro, create the English ANE and G2P directories plus an unrelated sibling. Assert:

```swift
try await loader.removeModels()
XCTAssertFalse(FileManager.default.fileExists(atPath: englishANE.path))
XCTAssertFalse(FileManager.default.fileExists(atPath: g2p.path))
XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSibling.path))
```

For PocketTTS, create `Models/pocket-tts/v2.1/english`, a sibling language, and an unrelated provider. Assert only the English directory is removed. Repeat each call with already-absent targets and expect success.

- [ ] **Step 2: Write failing engine ordering tests**

Extend fake loaders/sessions to record events and assert:

```swift
func testRemoveCancelsInFlightLoadReleasesSessionThenDeletes() async throws
func testRemoveInvalidatesPositivePresenceCache() async throws
func testRemovalFailureDoesNotReportModelsAbsent() async
```

The fake loader's `removeModels()` must assert that its session lifetime probe has been released before recording `delete`.

- [ ] **Step 3: Run focused removal tests and verify RED**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/FluidAudioKokoroEngineTests -only-testing:RelayTests/FluidAudioPocketTTSEngineTests -only-testing:RelayTests/KokoroModelManagerTests -only-testing:RelayTests/PocketTTSModelManagerTests test
```

Expected: compilation fails because the removal operations do not exist and managers still throw `removeNotSupported`.

- [ ] **Step 4: Implement exact-path deletion and engine teardown**

Add to each loader and engine seam:

```swift
func removeModels() async throws
```

In each engine actor:

```swift
func removeModels() async throws {
    if let inFlightLoad {
        inFlightLoad.task.cancel()
        _ = try? await inFlightLoad.task.value
        clearIfCurrent(inFlightLoad.task)
    }
    session = nil
    validatedModelsPresent = false
    try await modelLoader.removeModels()
    guard await !modelLoader.modelsArePresent() else {
        throw ModelRemovalError.assetsRemain
    }
}
```

Loader deletion treats missing targets as success and uses only its existing computed model directories. Do not remove `cacheDirectory` itself. Update both model managers to delegate `removeModel` to their engine after validating the model ID.

Use an exact-target helper in each loader:

```swift
private func removeIfPresent(_ url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
}
```

Manager delegation remains deliberately thin:

```swift
func removeModel(id: String) async throws {
    guard id == modelID else { throw SpeechModelManagerError.unknownModel(id) }
    try await engine.removeModels()
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 3 command. Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Relay/Backends/FluidAudioKokoroEngine.swift Relay/Backends/FluidAudioPocketTTSEngine.swift Relay/Backends/KokoroModelManager.swift Relay/Backends/PocketTTSModelManager.swift RelayTests/Backends
git commit -m "feat(tts): safely remove local speech models"
```

### Task 4: Add provider-owned voice catalogs and exact-provider previews

**Files:**
- Create: `Relay/App/SpeechVoiceCatalog.swift`
- Modify: `Relay/Domain/SpeechModels.swift`
- Modify: `Relay/SpeechOut/SpeechCoordinator.swift`
- Modify: `Relay/SpeechOut/TTSRouter.swift`
- Modify: `Relay/App/AppModel.swift`
- Create: `RelayTests/App/SpeechVoiceCatalogTests.swift`
- Modify: `RelayTests/SpeechOut/TTSRouterTests.swift`
- Modify: `RelayTests/SpeechOut/SpeechCoordinatorTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`

**Interfaces:**
- Produces: `SpeechVoiceOption` provider-neutral descriptors.
- Produces: exact-backend preview from AppModel through coordinator/router.
- Consumes: existing persisted voice fields and global `ttsRate`.

- [ ] **Step 1: Write failing catalog tests**

Define and test:

```swift
struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let detail: String?
    let storedValue: String?
}

@MainActor
protocol SpeechVoiceCataloging {
    func voices(for backendID: String) -> [SpeechVoiceOption]
    func activeVoiceID(for backendID: String, settings: AppSettings) -> String?
    func storedValue(for voiceID: String, backendID: String) -> String??
    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions?
}
```

Assert that Apple, Kokoro, and PocketTTS each expose exactly one Active option when their stored setting is `nil`, and that selecting a non-default option maps to the existing persisted field without changing other providers.

- [ ] **Step 2: Write failing exact-preview routing tests**

Add tests proving:

```swift
func testPreferredBackendUsesOnlyThatBackendWithoutFallback() async
func testVoicePreviewInterruptsCurrentSpeechAndUsesOptionsOverride() async
func testAppModelPreviewDoesNotPersistClickedVoice() async
func testAppModelPreviewUsesCurrentRateAndClickedProviderVoice() async
```

Use a first backend that would succeed to prove a preview targeting the second backend never consults it.

- [ ] **Step 3: Run focused voice tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SpeechVoiceCatalogTests -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests -only-testing:RelayTests/AppModelTests test
```

Expected: compilation fails because the catalog and preview interfaces do not exist.

- [ ] **Step 4: Implement the voice catalog adapters**

`SpeechVoiceCatalog` owns provider-specific imports and produces plain descriptors:

- Apple: `System Default` plus sorted `AVSpeechSynthesisVoice.speechVoices()` rows.
- Kokoro: `Recommended — <voice>` plus supported `af_`/`am_` voices, avoiding a duplicate row if the recommendation is already in the list.
- PocketTTS: `Recommended — alba`, represented once.

Use stable synthetic IDs for default rows while preserving `storedValue == nil`.

Map a row back to its persisted representation inside the catalog so the view never branches on provider IDs. The double optional distinguishes an unknown voice from a known default voice whose stored value is `nil`:

```swift
func storedValue(for voiceID: String, backendID: String) -> String?? {
    voices(for: backendID)
        .first(where: { $0.id == voiceID })
        .map(\.storedValue)
}
```

- [ ] **Step 5: Implement exact-provider preview without persistence**

Add a preferred-backend parameter to the router's internal route selection:

```swift
func speak(
    text: String,
    options: TTSOptions,
    sessionID: UUID,
    preferredBackendID: String? = nil
) async throws
```

When non-nil, the router iterates only that backend and never falls back. Add:

```swift
func previewVoice(text: String, backendID: String, options: TTSOptions) async throws
```

to `SpeechCoordinating`/`SpeechCoordinator`, reusing the user-requested interruption and overlay lifecycle. Replace `AppModel.testVoice()` with:

```swift
func selectVoice(backendID: String, voiceID: String)
func previewVoice(backendID: String, voiceID: String) async
```

`selectVoice` asks the catalog for the stored value and centralizes the existing provider-specific settings writes in AppModel. `previewVoice` asks the catalog for a temporary `TTSOptions` copy using current settings/rate, calls `speechCoordinator.previewVoice`, and never calls a settings setter.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 3 command. Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Relay/App/SpeechVoiceCatalog.swift Relay/Domain/SpeechModels.swift Relay/SpeechOut/SpeechCoordinator.swift Relay/SpeechOut/TTSRouter.swift Relay/App/AppModel.swift RelayTests
git commit -m "feat(tts): add selectable provider voice previews"
```

### Task 5: Replace both settings implementations with shared provider/model/voice rows

**Files:**
- Create: `Relay/App/Settings/SpeechBackendSettingsSection.swift`
- Create: `Relay/App/Settings/SpeechModelRow.swift`
- Create: `Relay/App/Settings/SpeechVoiceRow.swift`
- Modify: `Relay/App/Settings/DictationSettingsView.swift`
- Modify: `Relay/App/Settings/TTSSettingsView.swift`
- Modify: `RelayTests/App/SettingsViewsSmokeTests.swift`

**Interfaces:**
- Consumes: `SpeechModelController` from Task 2 and `SpeechVoiceOption`/preview from Task 4.
- Produces: one provider/model rendering module used by both settings tabs.

- [ ] **Step 1: Replace old presentation tests with failing shared-row tests**

Define a pure presentation value:

```swift
struct SpeechModelRowPresentation: Equatable {
    let title: String
    let detail: String
    let stateLabel: String
    let isActive: Bool
    let downloadTitle: String
    let canDownload: Bool
    let canSelect: Bool
    let canRemove: Bool
    let downloadHelp: String?
    let selectHelp: String?
    let removeHelp: String?
}
```

Add table-driven tests for not-downloaded, downloading, failed, downloaded-active, downloaded-inactive, unsupported Download/Select/Remove, and backend-not-ready. Assert all three action labels exist in every presentation and only enablement/help changes.

Add voice-row tests proving Select and Test are always present, Select disables for Active, and Test remains enabled.

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SettingsViewsSmokeTests test
```

Expected: tests fail because the old Dictation-only presentation hides actions and no shared voice presentation exists.

- [ ] **Step 3: Implement reusable rows and section**

`SpeechBackendSettingsSection` receives provider-neutral values and closures:

```swift
struct SpeechBackendSettingsSection<ExpandedContent: View>: View {
    let title: String
    let backends: [BackendStatus]
    let domain: SpeechModelDomain
    let controller: SpeechModelController
    let message: String?
    let setEnabled: (String, Bool) -> Void
    let move: (String, Bool) -> Void
    let expandedContent: (String) -> ExpandedContent

    init(
        title: String,
        backends: [BackendStatus],
        domain: SpeechModelDomain,
        controller: SpeechModelController,
        message: String?,
        setEnabled: @escaping (String, Bool) -> Void,
        move: @escaping (String, Bool) -> Void,
        @ViewBuilder expandedContent: @escaping (String) -> ExpandedContent
    ) {
        self.title = title
        self.backends = backends
        self.domain = domain
        self.controller = controller
        self.message = message
        self.setEnabled = setEnabled
        self.move = move
        self.expandedContent = expandedContent
    }
}
```

It owns the expanded-ID state and composes `SpeechModelRow` for every controller row. `SpeechModelRow` owns confirmation state and calls controller actions. `SpeechVoiceRow` renders Active, Select, and Test without knowing how values persist or play.

- [ ] **Step 4: Migrate Dictation and TTS to the shared section**

Dictation keeps only its mode picker and supplies `EmptyView` as extra expanded content.

TTS supplies voice rows from `SpeechVoiceCatalog`, with closures calling `AppModel.selectVoice(backendID:voiceID:)` for Select and `previewVoice` for Test. Remove the three standalone voice sections and the global Test Voice button. Keep the global rate slider.

Apple TTS expands for voices even though it has no model manager. All other providers expand when either models or voices exist.

- [ ] **Step 5: Run settings and model controller tests**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/SettingsViewsSmokeTests -only-testing:RelayTests/SpeechModelControllerTests -only-testing:RelayTests/SpeechVoiceCatalogTests test
```

Expected: all selected tests pass and both tab views construct through the shared module.

- [ ] **Step 6: Commit**

```bash
git add Relay/App/Settings RelayTests/App/SettingsViewsSmokeTests.swift
git commit -m "refactor(settings): share speech model and voice rows"
```

### Task 6: Remove legacy paths, update documentation, and verify integration

**Files:**
- Modify: `RelayTests/App/TTSBackendCatalogTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`
- Modify: `RelayTests/ProjectSmokeTests.swift`
- Modify: `RelayTests/App/TTSMigrationProductionWiringTests.swift`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-19-relay-unified-tts-migration-design.md`
- Modify: `docs/superpowers/plans/2026-09-19-relay-unified-tts-migration-implementation-plan.md`

**Interfaces:**
- Consumes: all shared modules from Tasks 1–5.
- Produces: no compatibility wrappers or duplicate model lifecycle path.

- [ ] **Step 1: Add failing structural and production-wiring tests**

Add tests asserting the production AppModel controller contains Dictation and TTS manager keys, TTS models can be removed and return to not-downloaded, and every TTS provider exposes the expected voice rows.

Keep `ProjectSmokeTests` focused on production wiring rather than source-text shape. Legacy symbol absence is checked explicitly in Step 4.

- [ ] **Step 2: Run integration tests and verify RED**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES -only-testing:RelayTests/ProjectSmokeTests -only-testing:RelayTests/TTSMigrationProductionWiringTests -only-testing:RelayTests/TTSBackendCatalogTests -only-testing:RelayTests/AppModelTests test
```

Expected: at least one production-wiring assertion fails until the shared controller and voice catalog are wired through AppModel.

- [ ] **Step 3: Delete remaining legacy tests/code and update documentation**

Remove backend-level TTS download tests that exercise deleted helpers and replace them with controller contract coverage. Remove duplicate AppModel fake-manager helpers that are now owned by `SpeechModelControllerTests`.

Update README Settings documentation to describe expandable providers, explicit model actions, colocated voice rows, and voice preview behavior. Amend the prior TTS migration spec/plan with a short supersession note linking to the 2026-09-21 unified settings spec instead of leaving the old “visually unchanged” statement as current guidance.

- [ ] **Step 4: Regenerate the Xcode project and check the worktree**

Run:

```bash
xcodegen generate
if rg -n 'func downloadTTSModel\(|func downloadSpeechModel\(backendID:|private func speechModelRow\(|private func ttsBackendActionView\(' Relay; then
  exit 1
fi
git diff --check
git status --short
```

Expected: the generated project contains the new Swift files, no legacy lifecycle/view symbol remains, `git diff --check` is clean, and only intended source/test/doc/project changes remain.

- [ ] **Step 5: Run the complete test suite**

Run:

```bash
xcodebuild -scheme Relay -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings ONLY_ACTIVE_ARCH=YES test
```

Expected: `** TEST SUCCEEDED **`, zero unexpected failures, and only intentionally skipped tests.

- [ ] **Step 6: Build the Release app without installing it**

Run:

```bash
xcodebuild -scheme Relay -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/relay-unified-settings-release ONLY_ACTIVE_ARCH=YES build
```

Expected: `** BUILD SUCCEEDED **` and `/tmp/relay-unified-settings-release/Build/Products/Release/Relay.app` exists.

- [ ] **Step 7: Commit**

```bash
git add README.md Relay.xcodeproj Relay RelayTests docs/superpowers
git commit -m "feat(settings): unify speech models and provider voices"
```

## Final verification

- [ ] Run `git status --short --branch` and confirm no unintended changes.
- [ ] Run `git log --oneline --decorate -8` and confirm every task commit is present.
- [ ] Re-run the complete XCTest command from Task 6 if any file changed after its successful run.
- [ ] Inspect the TTS and Dictation settings in a development build: expand each provider, verify stable action positions, test a non-active voice without changing selection, remove and re-download both local TTS models, and confirm backend order/enablement remains intact.
