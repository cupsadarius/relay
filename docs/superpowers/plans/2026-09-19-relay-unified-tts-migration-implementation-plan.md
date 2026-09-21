# Relay Unified TTS Migration Implementation Plan

> The completed TTS model-management and Settings steps in this historical plan are superseded by
> [Unified Speech Model Settings Implementation Plan](2026-09-21-unified-speech-model-settings-implementation-plan.md)
> and its [design](../specs/2026-09-21-unified-speech-model-settings-design.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Relay's post-Whisper speech unification by moving Kokoro and PocketTTS onto `SpeechModelManaging`, introducing one provider-neutral PCM source/player pipeline, adding production-grade long-form Kokoro phoneme chunking, migrating Apple TTS to generated PCM, and deleting the legacy TTS download/playback paths.

**Architecture:** Keep `SpeechCoordinator` behavior unchanged. First converge TTS model lifecycle on the already-shipped `SpeechModelManaging` pattern. Then introduce `TTSAudioSource`, `TTSAudioPipe`, `PCMFramer`, and a demand-bounded `StreamingAudioPlayer`; prepare Pocket, Kokoro, and Apple source adapters while the legacy backend contract still compiles; finally switch `TextToSpeechBackend` and `TTSRouter` to source production plus one shared player and delete the compatibility code.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, AVFoundation, FluidAudio 0.15.7, WhisperKit 1.1.0, XcodeGen, XCTest, macOS 26.0+, Apple Silicon arm64.

**Spec:** `docs/superpowers/specs/2026-09-19-relay-unified-tts-migration-design.md`

## Global Constraints

- Preserve `SpeechCoordinator` queue, replay, interruption, overlay, watchdog, and session-aware stop semantics.
- Keep the current TTS backend order and ids: `pocket-tts`, `apple-tts`, `kokoro`.
- Reuse `SpeechModelManaging`; do not add a TTS-specific model-management protocol.
- Voice selection remains independent from model selection.
- Kokoro and PocketTTS remain explicit-download only; the speak path must never pass `allowDownload: true`.
- Apple TTS remains a zero-download backend.
- TTS Settings stay backend-level for Kokoro and Pocket because each exposes exactly one model.
- TTS backends produce speech audio; the target architecture gives speaker playback to one shared `StreamingAudioPlayer`.
- Fallback is allowed only before audible `.started`; once `.started` fires, later source/playback failure terminates that session.
- `.scheduled` is emitted exactly once per Relay speech session, not once per backend attempt.
- Kokoro phonemizes the complete input before normal segmentation.
- Kokoro's preferred chunk target starts around 480 phoneme characters; no chunk may exceed FluidAudio's `KokoroAneConstants.maxPhonemeLength` hard limit.
- Kokoro inference remains sequential; concurrency is synthesis versus playback, never parallel Kokoro inference.
- Known acoustic-frame overflow may cause bounded further splitting; ordinary inference failures may not.
- The shared player must use bounded demand so upstream backpressure reflects actual audio ahead of playback instead of greedily scheduling the whole response.
- Stop cancels generation, discards queued PCM, stops playback immediately, and emits one `.cancelled` terminal event.
- Speech text, phonemes, and PCM remain ephemeral and must not be logged or persisted.
- Generate the Xcode project with `xcodegen generate`; never hand-edit `Relay.xcodeproj/project.pbxproj`.
- Run commands from repository root with `.derived-data` as the test derived-data path.

## Review Focus

1. **Very long Kokoro input with no punctuation or whitespace:** hard splitting must terminate, preserve phoneme order, and never emit a chunk over FluidAudio's hard cap. Task 9 pins this.
2. **Pause during a long Kokoro response:** player demand must stop growing, the pipe must eventually reach its high watermark, and synthesis must suspend instead of filling memory or scheduling the whole answer. Tasks 5, 6, and 10 pin this.
3. **Source failure after audible speech has begun:** already-valid audio drains, exactly one `.failed` follows, and the router never falls back to another voice mid-answer. Tasks 5, 6, and 12 pin this.
4. **Rapid Stop/replacement while generation is blocked or callbacks are late:** old PCM/callbacks/events must not leak into the replacement session. Tasks 5, 6, 10, 11, and 12 pin this.
5. **Model-download races and stale progress callbacks:** TTS's move to `SpeechModelManaging` must retain today's monotonic progress, single-flight, retry, and refresh race safety while speech itself remains download-free. Task 3 pins this.

---

## End-state file map

### Create

```text
Relay/Backends/KokoroModelManager.swift
Relay/Backends/PocketTTSModelManager.swift
Relay/SpeechOut/TTSAudioSource.swift
Relay/SpeechOut/TTSAudioPipe.swift
Relay/SpeechOut/PCMFramer.swift
Relay/SpeechOut/PocketTTSAudioSource.swift
Relay/SpeechOut/KokoroPhonemeChunker.swift
Relay/SpeechOut/KokoroTTSAudioSource.swift
Relay/SpeechOut/AppleTTSAudioSource.swift
RelayTests/Backends/KokoroModelManagerTests.swift
RelayTests/Backends/PocketTTSModelManagerTests.swift
RelayTests/SpeechOut/TTSAudioSourceTests.swift
RelayTests/SpeechOut/TTSAudioPipeTests.swift
RelayTests/SpeechOut/PCMFramerTests.swift
RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift
RelayTests/SpeechOut/KokoroPhonemeChunkerTests.swift
RelayTests/SpeechOut/KokoroTTSAudioSourceTests.swift
RelayTests/SpeechOut/AppleTTSAudioSourceTests.swift
```

### Modify

```text
Relay/App/BackendCatalog.swift
Relay/App/TTSBackendCatalog.swift
Relay/App/AppModel.swift
Relay/App/RelayRuntime.swift
Relay/App/Settings/TTSSettingsView.swift
Relay/Backends/KokoroTTSBackend.swift
Relay/Backends/PocketTTSBackend.swift
Relay/Backends/FluidAudioKokoroEngine.swift
Relay/Backends/FluidAudioPocketTTSEngine.swift
Relay/SpeechOut/TextToSpeechBackend.swift
Relay/SpeechOut/TTSRouter.swift
Relay/SpeechOut/StreamingAudioPlayer.swift
Relay/SpeechOut/SpeechCoordinator.swift        # characterization/comments only unless tests expose a regression
Relay/Domain/SpeechModels.swift
RelayTests/App/TTSBackendCatalogTests.swift
RelayTests/App/AppModelTests.swift
RelayTests/ProjectSmokeTests.swift
RelayTests/Backends/KokoroTTSBackendTests.swift
RelayTests/Backends/PocketTTSBackendTests.swift
RelayTests/Backends/FluidAudioKokoroEngineTests.swift
RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
RelayTests/SpeechOut/TTSRouterTests.swift
RelayTests/SpeechOut/SpeechCoordinatorTests.swift
RelayTests/SpeechOut/AppleTTSBackendTests.swift
RelayTests/Domain/SpeechBackendContractsTests.swift
README.md
```

### Delete after the final cutover

```text
Relay/SpeechOut/SynthesizedAudioPlayer.swift
RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift
```

---

# Phase 1 - TTS model lifecycle convergence

## Task 1: Add the one-model Kokoro model manager

**Files:**
- Create: `Relay/Backends/KokoroModelManager.swift`
- Create: `RelayTests/Backends/KokoroModelManagerTests.swift`

**Interfaces:**
- Consumes: `SpeechModelManaging`, `SpeechModelDescriptor`, `SpeechModelStatus`, `KokoroEngine`.
- Produces: `KokoroModelManager: SpeechModelManaging`, `KokoroModelManager.modelID`, `KokoroModelManagerError`.

- [ ] **Step 1: Write failing tests for the one-model contract**

Create tests covering these exact cases:

```swift
@MainActor
final class KokoroModelManagerTests: XCTestCase {
    func testModelsReportsOneAlwaysSelectedModelAndPresence() async {
        let engine = FakeKokoroEngine(modelsPresent: false)
        let manager = KokoroModelManager(engine: engine)

        var models = await manager.models()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, KokoroModelManager.modelID)
        XCTAssertEqual(models[0].installState, .notDownloaded)
        XCTAssertTrue(models[0].isSelected)

        await engine.setModelsPresent(true)
        models = await manager.models()
        XCTAssertEqual(models[0].installState, .downloaded)
    }

    func testDownloadValidatesIDAndUsesExplicitDownloadPath() async throws {
        let engine = FakeKokoroEngine(modelsPresent: false)
        let manager = KokoroModelManager(engine: engine)
        let progress = ProgressBox()

        try await manager.downloadModel(KokoroModelManager.modelID) {
            progress.append($0)
        }

        XCTAssertEqual(await engine.downloadLoadCount, 1)
        XCTAssertEqual(await engine.localLoadCount, 0)
        XCTAssertEqual(progress.snapshot(), [1.0])
    }

    func testSelectOnlyValidatesBecauseThereIsOneModel() async throws {
        let manager = KokoroModelManager(engine: FakeKokoroEngine())
        try await manager.selectModel(KokoroModelManager.modelID)
    }

    func testRemoveIsExplicitlyUnsupported() async {
        let manager = KokoroModelManager(engine: FakeKokoroEngine())
        do {
            try await manager.removeModel(KokoroModelManager.modelID)
            XCTFail("Expected removeNotSupported")
        } catch {
            XCTAssertEqual(error as? KokoroModelManagerError, .removeNotSupported)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor FakeKokoroEngine: KokoroEngine {
    private var present: Bool
    private(set) var localLoadCount = 0
    private(set) var downloadLoadCount = 0

    init(modelsPresent: Bool = false) {
        present = modelsPresent
    }

    func setModelsPresent(_ value: Bool) { present = value }
    func modelsArePresent() async -> Bool { present }

    func load(
        allowDownload: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if allowDownload {
            downloadLoadCount += 1
            present = true
            progress(1.0)
        } else {
            localLoadCount += 1
        }
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        Data()
    }
}
```

The fake satisfies the current pre-Task-8 `KokoroEngine` exactly and never constructs FluidAudio models.

- [ ] **Step 2: Run the new tests and verify RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroModelManagerTests test
```

Expected: compile failure because `KokoroModelManager` does not exist.

- [ ] **Step 3: Implement `KokoroModelManager`**

Use the Parakeet manager as the exact structural precedent:

```swift
import Foundation

enum KokoroModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

struct KokoroModelManager: SpeechModelManaging {
    static let modelID = "kokoro-82m-ane-en"
    let backendID = "kokoro"

    private let engine: any KokoroEngine

    init(engine: any KokoroEngine = FluidAudioKokoroEngine()) {
        self.engine = engine
    }

    func models() async -> [SpeechModelStatus] {
        let present = await engine.modelsArePresent()
        return [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                installState: present ? .downloaded : .notDownloaded,
                isSelected: true,
                isLoaded: false
            )
        ]
    }

    func downloadModel(
        _ id: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validate(id)
        try await engine.load(allowDownload: true, progress: progress)
    }

    func selectModel(_ id: String) async throws {
        try Self.validate(id)
    }

    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw KokoroModelManagerError.removeNotSupported
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "Kokoro 82M ANE",
        detail: "English",
        approximateDownloadBytes: nil
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw KokoroModelManagerError.unknownModel(id)
        }
    }
}
```

`isLoaded` stays `false`, matching Parakeet: the existing Kokoro engine does not expose a side-effect-free loaded-state query and this UI does not need one.

- [ ] **Step 4: Regenerate and run tests GREEN**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroModelManagerTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Relay/Backends/KokoroModelManager.swift RelayTests/Backends/KokoroModelManagerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add Kokoro model manager"
```

---

## Task 2: Add the one-model PocketTTS model manager

**Files:**
- Create: `Relay/Backends/PocketTTSModelManager.swift`
- Create: `RelayTests/Backends/PocketTTSModelManagerTests.swift`

**Interfaces:**
- Consumes: `SpeechModelManaging`, `PocketTTSEngine`.
- Produces: `PocketTTSModelManager: SpeechModelManaging`, `PocketTTSModelManager.modelID`, `PocketTTSModelManagerError`.

- [ ] **Step 1: Write the Pocket one-model tests**

Mirror the behavioral contract, not the implementation, from Task 1:

```swift
func testModelsReportsPocketV21EnglishAsAlwaysSelected() async {
    let engine = FakePocketTTSEngine(modelsPresent: true)
    let manager = PocketTTSModelManager(engine: engine)

    let models = await manager.models()

    XCTAssertEqual(models.count, 1)
    XCTAssertEqual(models[0].id, PocketTTSModelManager.modelID)
    XCTAssertEqual(models[0].installState, .downloaded)
    XCTAssertTrue(models[0].isSelected)
}

func testDownloadUsesDownloadEnabledEngineLoad() async throws {
    let engine = FakePocketTTSEngine(modelsPresent: false)
    let manager = PocketTTSModelManager(engine: engine)

    try await manager.downloadModel(PocketTTSModelManager.modelID) { _ in }

    XCTAssertEqual(await engine.downloadLoadCount, 1)
    XCTAssertEqual(await engine.localLoadCount, 0)
}
```

Also pin unknown-id validation and unsupported removal. Define the task-local fake explicitly so this task is self-contained:

```swift
private actor FakePocketTTSEngine: PocketTTSEngine {
    private var present: Bool
    private(set) var localLoadCount = 0
    private(set) var downloadLoadCount = 0

    init(modelsPresent: Bool = false) {
        present = modelsPresent
    }

    func modelsArePresent() async -> Bool { present }

    func load(
        allowDownload: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if allowDownload {
            downloadLoadCount += 1
            present = true
            progress(1.0)
        } else {
            localLoadCount += 1
        }
    }

    func synthesize(text: String, voice: String) async throws -> Data { Data() }

    func synthesizeStream(
        text: String,
        voice: String
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
```

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/PocketTTSModelManagerTests test
```

- [ ] **Step 3: Implement the manager**

```swift
import Foundation

enum PocketTTSModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

struct PocketTTSModelManager: SpeechModelManaging {
    static let modelID = "pocket-tts-v2.1-en"
    let backendID = "pocket-tts"

    private let engine: any PocketTTSEngine

    init(engine: any PocketTTSEngine = FluidAudioPocketTTSEngine()) {
        self.engine = engine
    }

    func models() async -> [SpeechModelStatus] {
        let present = await engine.modelsArePresent()
        return [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                installState: present ? .downloaded : .notDownloaded,
                isSelected: true,
                isLoaded: false
            )
        ]
    }

    func downloadModel(
        _ id: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validate(id)
        try await engine.load(allowDownload: true, progress: progress)
    }

    func selectModel(_ id: String) async throws { try Self.validate(id) }

    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw PocketTTSModelManagerError.removeNotSupported
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "PocketTTS v2.1",
        detail: "English",
        approximateDownloadBytes: nil
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw PocketTTSModelManagerError.unknownModel(id)
        }
    }
}
```

- [ ] **Step 4: Run GREEN**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/PocketTTSModelManagerTests test
```

- [ ] **Step 5: Commit**

```bash
git add Relay/Backends/PocketTTSModelManager.swift RelayTests/Backends/PocketTTSModelManagerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add PocketTTS model manager"
```

---

## Task 3: Move TTS download/catalog wiring to `SpeechModelManaging` and delete `SpeechModelDownloading`

**Files:**
- Modify: `Relay/App/BackendCatalog.swift`
- Modify: `Relay/App/TTSBackendCatalog.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/RelayRuntime.swift`
- Modify: `Relay/Backends/KokoroTTSBackend.swift`
- Modify: `Relay/Backends/PocketTTSBackend.swift`
- Modify: `RelayTests/App/TTSBackendCatalogTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`
- Modify: `RelayTests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: `KokoroModelManager`, `PocketTTSModelManager`, existing `SpeechModelManaging`.
- Produces: `SpeechOutputServices.ttsModelManagers`, `AppModel.ttsModelManagers`; removes all production references to `SpeechModelDownloading`.

- [ ] **Step 1: Replace TTS downloader fakes with one-model manager fakes in catalog tests**

The fake must expose one model id and preserve existing blocking/progress behavior:

```swift
private actor FakeTTSModelManager: SpeechModelManaging {
    let backendID: String
    let modelID: String
    private var present = false
    private var shouldBlock = false
    private var gate: CheckedContinuation<Void, Never>?
    private var progressToReport: [Double] = []
    private var errorToThrow: TestCatalogError?
    private var retainedProgress: (@Sendable (Double) -> Void)?
    private(set) var callCount = 0
    private(set) var receivedModelIDs: [String] = []

    init(backendID: String, modelID: String = "model") {
        self.backendID = backendID
        self.modelID = modelID
    }

    func models() async -> [SpeechModelStatus] {
        [SpeechModelStatus(
            descriptor: .init(id: modelID, displayName: modelID, detail: nil, approximateDownloadBytes: nil),
            installState: present ? .downloaded : .notDownloaded,
            isSelected: true,
            isLoaded: false
        )]
    }

    func setPresent(_ value: Bool) { present = value }
    func setShouldBlock(_ value: Bool) { shouldBlock = value }
    func setProgressToReport(_ values: [Double]) { progressToReport = values }
    func setErrorToThrow(_ error: TestCatalogError?) { errorToThrow = error }

    func reportProgress(_ value: Double) { retainedProgress?(value) }

    func resume() {
        gate?.resume()
        gate = nil
    }

    func downloadModel(
        _ id: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        receivedModelIDs.append(id)
        callCount += 1
        retainedProgress = progress
        for value in progressToReport { progress(value) }

        if shouldBlock {
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        if let errorToThrow { throw errorToThrow }
        present = true
    }

    func removeModel(_ id: String) async throws {}
    func selectModel(_ id: String) async throws {}
}
```

Port every current TTS download assertion: progress, retry, duplicate-click suppression, refresh races, missing-row insertion, late ticks, out-of-order ticks, diagnostics, and Apple having no manager.

- [ ] **Step 2: Run targeted tests RED after renaming constructor arguments**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSBackendCatalogTests -only-testing:RelayTests/ProjectSmokeTests test
```

Expected: compile failures on `ttsModelDownloaders` / `SpeechModelDownloading`.

- [ ] **Step 3: Change the TTS catalog to resolve the manager's single model**

Add a private error in `TTSBackendCatalog.swift`:

```swift
private enum TTSModelCatalogError: Error, Sendable {
    case noModelRegistered
}
```

Change the download entry point to:

```swift
func downloadTTSModel(_ id: String) async {
    guard let manager = ttsModelManagers[id] else { return }
    guard !downloadingTTSBackendIDs.contains(id) else { return }

    beginTTSDownload(id)
    setTTSBackendMessage(nil)
    recordDiagnostic(.speechModelDownloadStarted(backendID: id))

    do {
        guard let modelID = await manager.models().first?.id else {
            throw TTSModelCatalogError.noModelRegistered
        }
        try await manager.downloadModel(modelID) { [weak self] progress in
            Task { @MainActor in
                self?.applyTTSDownloadProgress(id: id, progress: progress)
            }
        }
        recordDiagnostic(.speechModelDownloadFinished(backendID: id))
        let availability = await ttsRegistry[id]?.availability()
        let finalState = availability.map(Catalog.mapAvailability) ?? .unavailable
        endTTSDownload(id, finalState: finalState)
    } catch {
        recordDiagnostic(.speechModelDownloadFailed(backendID: id))
        endTTSDownload(id, finalState: .downloadFailed)
        let displayName = ttsRegistry[id]?.displayName ?? id
        setTTSBackendMessage("\(displayName) model download failed. Check your connection and try again.")
    }
}
```

`canDownloadTTSModel(_:)` becomes `ttsModelManagers[id] != nil`.

- [ ] **Step 4: Rename runtime/model storage**

Use these exact names everywhere:

```swift
struct SpeechOutputServices {
    let ttsRegistry: [String: any TextToSpeechBackend]
    let ttsModelManagers: [String: any SpeechModelManaging]
    let speechCoordinator: any SpeechCoordinating
    let overlayModel: ActivityOverlayModel
    let overlayPresenter: any ActivityOverlayPresenting
}
```

and in `AppModel`:

```swift
@ObservationIgnored let ttsModelManagers: [String: any SpeechModelManaging]
```

Update both `AppModel` initializers and all test factory arguments.

- [ ] **Step 5: Share each FluidAudio engine between its backend and model manager in `RelayRuntime.makeProduction()`**

Replace independent default construction with:

```swift
let kokoroEngine: any KokoroEngine = FluidAudioKokoroEngine()
let kokoroTTS = KokoroTTSBackend(engine: kokoroEngine)
let kokoroModelManager = KokoroModelManager(engine: kokoroEngine)

let pocketEngine: any PocketTTSEngine = FluidAudioPocketTTSEngine()
let pocketTTS = PocketTTSBackend(engine: pocketEngine)
let pocketModelManager = PocketTTSModelManager(engine: pocketEngine)
```

Register:

```swift
let ttsModelManagers: [String: any SpeechModelManaging] = [
    kokoroModelManager.backendID: kokoroModelManager,
    pocketModelManager.backendID: pocketModelManager,
]
```

Apple intentionally has no manager.

- [ ] **Step 6: Remove the old backend conformances and protocol**

Delete both complete `SpeechModelDownloading` conformance extensions from `KokoroTTSBackend.swift` and `PocketTTSBackend.swift`; model downloads now enter through the manager instances created in Task 1 and Task 2. Then delete the `SpeechModelDownloading` protocol declaration from `BackendCatalog.swift` entirely.

- [ ] **Step 7: Strengthen smoke tests**

Add direct production-graph assertions:

```swift
@MainActor
func testMakeProductionRegistersTTSModelManagers() {
    let runtime = RelayRuntime.makeProduction()

    XCTAssertTrue(runtime.speechOut.ttsModelManagers["kokoro"] is KokoroModelManager)
    XCTAssertTrue(runtime.speechOut.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
    XCTAssertNil(runtime.speechOut.ttsModelManagers["apple-tts"])
}
```

Keep the existing `canDownloadTTSModel` assertions unchanged from the user's perspective.

- [ ] **Step 8: Run the catalog + smoke + full suite**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSBackendCatalogTests -only-testing:RelayTests/ProjectSmokeTests test
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Expected: all green and `rg 'SpeechModelDownloading|ttsModelDownloaders' Relay RelayTests` returns no matches.

- [ ] **Step 9: Commit**

```bash
git add Relay RelayTests Relay.xcodeproj/project.pbxproj
git commit -m "refactor(tts): unify model management"
```

---

# Phase 2 - Common PCM source and bounded playback primitives

## Task 4: Add the provider-neutral PCM types and framer

**Files:**
- Create: `Relay/SpeechOut/TTSAudioSource.swift`
- Create: `Relay/SpeechOut/PCMFramer.swift`
- Create: `RelayTests/SpeechOut/TTSAudioSourceTests.swift`
- Create: `RelayTests/SpeechOut/PCMFramerTests.swift`

**Interfaces:**
- Produces: `TTSAudioFormat`, `TTSAudioFrame`, `TTSAudioSource`, `PCMFramer.frames(samples:format:frameDuration:)`.

- [ ] **Step 1: Write frame-duration and framing tests**

```swift
func testFrameDurationUsesSamplesChannelsAndRate() {
    let frame = TTSAudioFrame(
        samples: Array(repeating: 0, count: 4_800),
        format: .init(sampleRate: 24_000, channelCount: 2)
    )
    XCTAssertEqual(frame.durationSeconds, 0.1, accuracy: 0.000_001)
}

func testPCMFramerProducesEightyMillisecondFramesAndShortTail() throws {
    let format = TTSAudioFormat(sampleRate: 24_000, channelCount: 1)
    let samples = Array(repeating: Float.zero, count: 4_000)

    let frames = try PCMFramer.frames(samples: samples, format: format, frameDuration: 0.08)

    XCTAssertEqual(frames.map(\.samples.count), [1_920, 1_920, 160])
}

func testPCMFramerRejectsSamplesNotAlignedToChannelCount() {
    XCTAssertThrowsError(try PCMFramer.frames(
        samples: [0, 0, 0],
        format: .init(sampleRate: 24_000, channelCount: 2),
        frameDuration: 0.08
    ))
}
```

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSAudioSourceTests -only-testing:RelayTests/PCMFramerTests test
```

- [ ] **Step 3: Implement the shared audio types**

```swift
import Foundation

struct TTSAudioFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
}

struct TTSAudioFrame: Sendable, Equatable {
    /// Interleaved Float32 PCM.
    let samples: [Float]
    let format: TTSAudioFormat

    var durationSeconds: TimeInterval {
        guard format.sampleRate > 0, format.channelCount > 0 else { return 0 }
        return Double(samples.count) / Double(format.channelCount) / format.sampleRate
    }
}

protocol TTSAudioSource: Sendable {
    func next() async throws -> TTSAudioFrame?
    func cancel() async
}
```

- [ ] **Step 4: Implement a pure `PCMFramer`**

```swift
import Foundation

enum PCMFramerError: Error, Equatable, Sendable {
    case invalidFormat
    case channelAlignment
}

enum PCMFramer {
    static func frames(
        samples: [Float],
        format: TTSAudioFormat,
        frameDuration: TimeInterval = 0.08
    ) throws -> [TTSAudioFrame] {
        guard format.sampleRate > 0, format.channelCount > 0, frameDuration > 0 else {
            throw PCMFramerError.invalidFormat
        }
        guard samples.count.isMultiple(of: format.channelCount) else {
            throw PCMFramerError.channelAlignment
        }

        let framesPerChannel = max(1, Int((format.sampleRate * frameDuration).rounded()))
        let samplesPerOutputFrame = framesPerChannel * format.channelCount
        var output: [TTSAudioFrame] = []
        var start = 0
        while start < samples.count {
            let end = min(start + samplesPerOutputFrame, samples.count)
            output.append(TTSAudioFrame(samples: Array(samples[start..<end]), format: format))
            start = end
        }
        return output
    }
}
```

- [ ] **Step 5: Run GREEN and commit**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSAudioSourceTests -only-testing:RelayTests/PCMFramerTests test
git add Relay/SpeechOut/TTSAudioSource.swift Relay/SpeechOut/PCMFramer.swift RelayTests/SpeechOut/TTSAudioSourceTests.swift RelayTests/SpeechOut/PCMFramerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add shared PCM source types"
```

---

## Task 5: Add `TTSAudioPipe` with duration-based hysteresis and terminal semantics

**Files:**
- Create: `Relay/SpeechOut/TTSAudioPipe.swift`
- Create: `RelayTests/SpeechOut/TTSAudioPipeTests.swift`

**Interfaces:**
- Consumes: `TTSAudioFrame`, `TTSAudioSource`, `SpeechBackendError`.
- Produces: `TTSAudioPipe.make(highWatermark:lowWatermark:) -> (sink: TTSAudioPipeSink, source: TTSAudioPipeSource)`.

- [ ] **Step 1: Write ordering, hysteresis, completion, failure, and cancellation tests**

The test suite must include:

```swift
func testFramesAreReadFIFO() async throws
func testProducerSuspendsAtHighWatermarkAndResumesOnlyBelowLowWatermark() async throws
func testFinishDrainsBufferedFramesThenReturnsNil() async throws
func testFailureDrainsBufferedFramesThenThrowsStoredError() async throws
func testCancelDiscardsBufferedFrames() async throws
func testCancelWakesBlockedProducer() async throws
func testCancelWakesBlockedConsumer() async throws
```

For hysteresis, use 1-second synthetic frames with `highWatermark: 3`, `lowWatermark: 1` so timing is deterministic and no real clock is needed.

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSAudioPipeTests test
```

- [ ] **Step 3: Implement the public pipe surface**

Use one actor-backed state object; `Sink` and `Source` are light wrappers over it:

```swift
struct TTSAudioPipeSink: Sendable {
    fileprivate let state: TTSAudioPipeState

    func yield(_ frame: TTSAudioFrame) async throws {
        try await state.yield(frame)
    }

    func finish() async { await state.finish() }
    func fail(_ error: SpeechBackendError) async { await state.fail(error) }
}

struct TTSAudioPipeSource: TTSAudioSource {
    fileprivate let state: TTSAudioPipeState

    func next() async throws -> TTSAudioFrame? { try await state.next() }
    func cancel() async { await state.cancel() }
}

enum TTSAudioPipe {
    static func make(
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) -> (sink: TTSAudioPipeSink, source: TTSAudioPipeSource) {
        precondition(highWatermark > 0)
        precondition(lowWatermark >= 0 && lowWatermark < highWatermark)
        let state = TTSAudioPipeState(highWatermark: highWatermark, lowWatermark: lowWatermark)
        return (.init(state: state), .init(state: state))
    }
}
```

- [ ] **Step 4: Implement the actor state machine**

The state machine must obey these rules exactly:

```text
OPEN:
  yield -> append frame and increase bufferedSeconds
  next  -> pop oldest frame and decrease bufferedSeconds
  finish -> mark successful terminal
  fail   -> remember SpeechBackendError but do not discard frames
  cancel -> discard frames and wake everyone with CancellationError

FAILED WITH BUFFER:
  next -> continue draining frames

FAILED EMPTY:
  next -> throw stored SpeechBackendError

FINISHED WITH BUFFER:
  next -> continue draining frames

FINISHED EMPTY:
  next -> nil
```

When `bufferedSeconds >= highWatermark`, future `yield` calls suspend. They resume only after a consumer drains the queue below `lowWatermark`, not merely below high.

Use continuations stored inside the actor and resume every outstanding waiter on finish/fail/cancel. Never resume a continuation twice.

- [ ] **Step 5: Add the pause/backpressure regression test from Review Focus**

Simulate a consumer that stops calling `next()` after one frame. Verify the producer reaches the high watermark and its following `yield` remains suspended until enough frames are consumed to cross the low watermark.

- [ ] **Step 6: Run GREEN and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSAudioPipeTests test
git add Relay/SpeechOut/TTSAudioPipe.swift RelayTests/SpeechOut/TTSAudioPipeTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add bounded audio pipe"
```

---

## Task 6: Generalize `StreamingAudioPlayer` to `TTSAudioSource` and bounded demand

**Files:**
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift`
- Modify: `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`

**Interfaces:**
- Consumes: `TTSAudioSource`, `TTSAudioFrame`.
- Produces: new `startPlayback(_ source:any TTSAudioSource, sessionID:UUID)` API while temporarily retaining the old Pocket stream overload as a compatibility wrapper.

- [ ] **Step 1: Add source-based player tests before changing implementation**

Add tests for:

```swift
func testSourceFailureBeforeStartThrowsAndEmitsNoTerminalEvent() async
func testShortSourceStartsEvenWhenItEndsBeforePrebufferTarget() async throws
func testSourceFailureAfterStartDrainsScheduledAudioThenEmitsFailedOnce() async throws
func testStopCancelsActiveSourceAndEmitsCancelledOnce() async throws
func testVariableFrameSizesUseActualDuration() async throws
func testStereoInterleavedFramesUseChannelCountInDuration() async throws
func testPlayerStopsPullingWhenScheduledAheadWindowIsFull() async throws
func testPausedPlayerEventuallyBackpressuresSource() async throws
func testReplacementIgnoresLateCompletionFromPriorSession() async throws
```

Use fake `TTSAudioSource` actors. Do not use real speakers for source semantics; preserve the existing injectable/fake AVAudio seams already in the test file.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/StreamingAudioPlayerTests test
```

- [ ] **Step 3: Add the source-based entry point and active-source ownership**

Keep the current protocol name for this transition but add:

```swift
func startPlayback(
    _ source: any TTSAudioSource,
    sessionID: UUID
) async throws
```

`StreamingAudioPlayer` stores the active source for Stop:

```swift
private var activeSource: (any TTSAudioSource)?
```

`stop()` cancels the pump task, calls `await source.cancel()` from a main-actor task, tears down scheduled audio, and emits `.cancelled` once.

- [ ] **Step 4: Make conversion frame-driven instead of Pocket-driven**

Replace the fixed source rate and fixed 1920-sample assumptions. For every `TTSAudioFrame`:

1. Validate `sampleRate > 0`, `channelCount > 0`, and sample count aligned to channels.
2. Build a Float32 source format from the frame's format.
3. Deinterleave the shared interleaved samples into the source `AVAudioPCMBuffer` when `channelCount > 1`.
4. Cache/rebuild `AVAudioConverter` only when source format changes.
5. Convert to the mixer/output format before scheduling.
6. Compute levels from that frame's PCM, not from a fixed cadence.

- [ ] **Step 5: Add demand-bounded scheduling**

Add constants:

```swift
private static let prebufferSeconds: TimeInterval = 0.6
private static let maxScheduledAheadSeconds: TimeInterval = 1.5
```

Track scheduled-but-not-yet-played duration:

```swift
private var scheduledAheadSeconds: TimeInterval = 0
private var demandWaiter: CheckedContinuation<Void, Never>?
```

Before asking the source for another frame after playback has started:

```swift
while started && scheduledAheadSeconds >= Self.maxScheduledAheadSeconds {
    await waitForPlaybackDemand()
}
```

When a scheduled buffer completes, subtract that buffer's duration and resume the waiter. This is the load-bearing change that prevents the player from greedily draining a 30-second upstream pipe into `AVAudioPlayerNode`.

- [ ] **Step 6: Change post-start source failure semantics**

Do not call `tearDownPlayback()` immediately when `next()` throws after `.started`.

Instead:

```swift
private var sourceTerminalError: Error?
private var sourceFinished = false
```

After a post-start throw:

```text
store error
mark source finished
stop pulling
wait for scheduledCount == playedCount
emit .failed
```

Before `.started`, preserve the current throw-to-router behavior with no terminal event.

- [ ] **Step 7: Keep the old Pocket stream call compiling through a compatibility adapter**

The old overload becomes a tiny adapter only:

```swift
func startPlayback(
    _ frames: AsyncThrowingStream<[Float], Error>,
    sampleRate: Double,
    sessionID: UUID
) async throws {
    let source = LegacyFloatStreamAudioSource(frames: frames, sampleRate: sampleRate)
    try await startPlayback(source, sessionID: sessionID)
}
```

No playback logic may remain in that overload.

- [ ] **Step 8: Run targeted and full tests**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/StreamingAudioPlayerTests test
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

- [ ] **Step 9: Commit**

```bash
git add Relay/SpeechOut/StreamingAudioPlayer.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
git commit -m "refactor(tts): make streaming player source driven"
```

---

# Phase 3 - PocketTTS source migration

## Task 7: Wrap PocketTTS streaming in `PocketTTSAudioSource`

**Files:**
- Create: `Relay/SpeechOut/PocketTTSAudioSource.swift`
- Create: `RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift`
- Modify: `Relay/Backends/PocketTTSBackend.swift`
- Modify: `RelayTests/Backends/PocketTTSBackendTests.swift`

**Interfaces:**
- Consumes: `PocketTTSEngine.synthesizeStream(text:voice:)`, `TTSAudioSource`.
- Produces: `PocketTTSAudioSource`, `PocketTTSBackend.makeAudioSource(text:options:)` as a concrete method ahead of the final protocol cutover.

- [ ] **Step 1: Write source-adapter tests**

```swift
func testFramesPreservePocketOrderAndUse24kMonoMetadata() async throws
func testStreamFinishReturnsNil() async throws
func testStreamFailureIsMappedToSpeechBackendError() async throws
func testCancellationStopsFurtherIteration() async throws
```

Use a fake `AsyncThrowingStream<[Float], Error>`; assert each emitted frame has:

```swift
TTSAudioFormat(sampleRate: Double(PocketTtsConstants.audioSampleRate), channelCount: 1)
```

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/PocketTTSAudioSourceTests test
```

- [ ] **Step 3: Implement the source as an actor**

```swift
actor PocketTTSAudioSource: TTSAudioSource {
    private var iterator: AsyncThrowingStream<[Float], Error>.Iterator?
    private let format = TTSAudioFormat(
        sampleRate: Double(PocketTtsConstants.audioSampleRate),
        channelCount: 1
    )
    private var cancelled = false

    init(stream: AsyncThrowingStream<[Float], Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> TTSAudioFrame? {
        guard !cancelled, var iterator else { return nil }
        do {
            guard let samples = try await iterator.next() else {
                self.iterator = nil
                return nil
            }
            self.iterator = iterator
            return TTSAudioFrame(samples: samples, format: format)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechBackendError.inferenceFailed("PocketTTS synthesis failed")
        }
    }

    func cancel() async {
        cancelled = true
        iterator = nil
    }
}
```

The player's pump task is also cancelled on Stop, so a currently suspended stream iteration receives task cancellation and FluidAudio's existing `onTermination` cancels its forwarding task.

- [ ] **Step 4: Add a concrete source factory to `PocketTTSBackend`**

Keep the current protocol conformance compiling for now. Add:

```swift
func makeAudioSource(
    text: String,
    options: TTSOptions
) async throws -> any TTSAudioSource {
    do {
        try await engine.load(allowDownload: false)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw Self.mapEngineError(error)
    }

    let voice = options.pocketVoice ?? PocketTtsConstants.defaultVoice
    do {
        return PocketTTSAudioSource(
            stream: try await engine.synthesizeStream(text: text, voice: voice)
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw SpeechBackendError.inferenceFailed("PocketTTS synthesis failed")
    }
}
```

Refactor the temporary legacy `speak(text:options:sessionID:)` implementation to call `makeAudioSource(text:options:)` and then `player.startPlayback(source, sessionID:)`. There must be only one synthesis path.

- [ ] **Step 5: Pin no-download-on-speak**

Add a backend test that starts `makeAudioSource` with a fake engine and asserts `load(allowDownload:false)` was used and the download count stayed zero.

- [ ] **Step 6: Run GREEN and commit**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/PocketTTSAudioSourceTests -only-testing:RelayTests/PocketTTSBackendTests test
git add Relay/SpeechOut/PocketTTSAudioSource.swift Relay/Backends/PocketTTSBackend.swift RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift RelayTests/Backends/PocketTTSBackendTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(tts): adapt PocketTTS to shared audio source"
```

---

# Phase 4 - Kokoro PCM and long-form migration

## Task 8: Expose Kokoro full-text phonemes and direct PCM synthesis

**Files:**
- Modify: `Relay/Backends/FluidAudioKokoroEngine.swift`
- Modify: `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`

**Interfaces:**
- Produces: `KokoroPCM`, `KokoroEngine.phonemes(for:)`, `KokoroEngine.synthesize(phonemes:voice:speed:)`.
- Preserves temporarily: the old text-to-WAV method only until Task 10 switches the backend; delete it there.

- [ ] **Step 1: Write failing seam tests**

Add fake-session tests proving:

```swift
func testPhonemesDelegatesToLoadedSession() async throws
func testSynthesizePhonemesReturnsRawSamplesAndSampleRate() async throws
func testPhonemeLimitMapsToSpecificEngineError() async throws
func testAcousticFrameLimitMapsToSpecificEngineError() async throws
func testGenericPCMFailureMapsToSynthesisFailed() async throws
```

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/FluidAudioKokoroEngineTests test
```

- [ ] **Step 3: Extend the provider-neutral engine seam**

```swift
struct KokoroPCM: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

enum KokoroEngineError: Error, Equatable, Sendable {
    case modelsNotDownloaded
    case loadFailed
    case synthesisFailed
    case phonemeSequenceTooLong
    case acousticFramesTooLong
}

protocol KokoroEngine: Sendable {
    func modelsArePresent() async -> Bool
    func load(
        allowDownload: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func phonemes(for text: String) async throws -> String
    func synthesize(
        phonemes: String,
        voice: String,
        speed: Float
    ) async throws -> KokoroPCM
}
```

During this task only, if the current backend still needs the old WAV API to compile, keep it as a temporary additional method and mark its deletion explicitly in Task 10. Do not build new behavior on it.

- [ ] **Step 4: Widen `KokoroModelSession` to the FluidAudio primitives**

The live wrapper uses the pinned 0.15.7 APIs:

```swift
private struct KokoroAneManagerSession: KokoroModelSession {
    let manager: KokoroAneManager

    func phonemes(for text: String) async throws -> String {
        try await manager.phonemes(for: text)
    }

    func synthesize(
        phonemes: String,
        voice: String,
        speed: Float
    ) async throws -> KokoroPCM {
        let result = try await manager.synthesizeFromPhonemesDetailed(
            phonemes,
            voice: voice,
            speed: speed
        )
        return KokoroPCM(
            samples: result.samples,
            sampleRate: Double(result.sampleRate)
        )
    }
}
```

`FluidAudioKokoroEngine` maps:

```text
KokoroAneError.phonemeSequenceTooLong -> .phonemeSequenceTooLong
KokoroAneError.acousticFramesExceedCap -> .acousticFramesTooLong
CancellationError -> CancellationError
everything else -> .synthesisFailed
```

- [ ] **Step 5: Run GREEN and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/FluidAudioKokoroEngineTests test
git add Relay/Backends/FluidAudioKokoroEngine.swift RelayTests/Backends/FluidAudioKokoroEngineTests.swift
git commit -m "refactor(tts): expose Kokoro phoneme PCM seam"
```

---

## Task 9: Implement the pure `KokoroPhonemeChunker`

**Files:**
- Create: `Relay/SpeechOut/KokoroPhonemeChunker.swift`
- Create: `RelayTests/SpeechOut/KokoroPhonemeChunkerTests.swift`

**Interfaces:**
- Produces: `KokoroPhonemeChunker.chunks(from:)`, `KokoroPhonemeChunker.splitForRetry(_:)`.

- [ ] **Step 1: Write the boundary-priority and preservation tests**

Required cases:

```swift
func testBlankInputReturnsNoChunks()
func testInputBelowTargetReturnsOneChunk()
func testNoChunkExceedsHardLimit()
func testSentenceBoundaryPreferredNearTarget()
func testClauseBoundaryPreferredWhenNoSentenceBoundary()
func testWhitespacePreferredBeforeHardSplit()
func testLongUnbrokenInputHardSplitsAndTerminates()
func testPunctuationStaysAttachedToPrecedingChunk()
func testConcatenationPreservesPhonemeSequenceModuloBoundaryWhitespace()
func testRetrySplitStrictlyReducesChunkSize()
```

Use a hard limit of 20 and preferred target of 16 in tests so inputs stay readable.

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroPhonemeChunkerTests test
```

- [ ] **Step 3: Implement deterministic character-based splitting**

Public shape:

```swift
struct KokoroPhonemeChunker: Sendable {
    let preferredTarget: Int
    let hardLimit: Int

    init(
        preferredTarget: Int = 480,
        hardLimit: Int = KokoroAneConstants.maxPhonemeLength
    ) {
        precondition(preferredTarget > 0)
        precondition(preferredTarget <= hardLimit)
        self.preferredTarget = preferredTarget
        self.hardLimit = hardLimit
    }

    func chunks(from phonemes: String) -> [String] {
        let characters = Array(phonemes)
        guard !characters.isEmpty else { return [] }

        var output: [String] = []
        var start = 0

        while start < characters.count {
            let remaining = characters.count - start
            if remaining <= hardLimit {
                output.append(String(characters[start..<characters.count]))
                break
            }

            let preferredEnd = min(start + preferredTarget, characters.count)
            let hardEnd = min(start + hardLimit, characters.count)
            let backward = bestBoundary(
                in: characters,
                range: start..<preferredEnd,
                target: preferredEnd
            )
            let forward = backward == nil
                ? bestBoundary(
                    in: characters,
                    range: preferredEnd..<hardEnd,
                    target: preferredEnd
                )
                : nil
            let split = backward ?? forward ?? preferredEnd

            precondition(split > start && split <= hardEnd)
            output.append(String(characters[start..<split]))
            start = split
        }

        return output
    }

    func splitForRetry(_ phonemes: String) -> [String] {
        guard phonemes.count > 1 else { return [phonemes] }
        let retryTarget = max(1, phonemes.count / 2)
        return KokoroPhonemeChunker(
            preferredTarget: min(retryTarget, hardLimit),
            hardLimit: hardLimit
        ).chunks(from: phonemes)
    }

    private func bestBoundary(
        in characters: [Character],
        range: Range<Int>,
        target: Int
    ) -> Int? {
        var best: (split: Int, strength: BoundaryStrength)?
        for index in range {
            guard let strength = Self.boundaryStrength(of: characters[index]) else { continue }
            let split = index + 1 // keep punctuation/whitespace with the preceding chunk
            if let current = best {
                let stronger = strength.rawValue > current.strength.rawValue
                let equallyStrongAndCloser = strength == current.strength
                    && abs(split - target) < abs(current.split - target)
                if stronger || equallyStrongAndCloser {
                    best = (split, strength)
                }
            } else {
                best = (split, strength)
            }
        }
        return best?.split
    }

    private static func boundaryStrength(of character: Character) -> BoundaryStrength? {
        if ".!?…".contains(character) { return .sentence }
        if ";:,—–".contains(character) { return .clause }
        if character.isWhitespace { return .whitespace }
        return nil
    }
}

private enum BoundaryStrength: Int {
    case whitespace = 1
    case clause = 2
    case sentence = 3
}
```

The algorithm preserves every input character exactly: it never trims phonemes, punctuation, or whitespace. It first searches backward from the preferred target for the strongest boundary; only when none exists does it search forward up to the hard limit. With no natural boundary, it hard-splits at `preferredTarget`.

- [ ] **Step 4: Add the Review Focus no-boundary regression**

Use more than 10x the hard limit of one repeated phoneme character. Assert:

```swift
XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= hardLimit })
XCTAssertEqual(chunks.joined(), original)
```

- [ ] **Step 5: Run GREEN and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroPhonemeChunkerTests test
git add Relay/SpeechOut/KokoroPhonemeChunker.swift RelayTests/SpeechOut/KokoroPhonemeChunkerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add Kokoro phoneme chunker"
```

---

## Task 10: Build the long-form Kokoro audio source and move Kokoro off whole-WAV playback

**Files:**
- Create: `Relay/SpeechOut/KokoroTTSAudioSource.swift`
- Create: `RelayTests/SpeechOut/KokoroTTSAudioSourceTests.swift`
- Modify: `Relay/Backends/KokoroTTSBackend.swift`
- Modify: `Relay/Backends/FluidAudioKokoroEngine.swift`
- Modify: `RelayTests/Backends/KokoroTTSBackendTests.swift`
- Modify: `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`

**Interfaces:**
- Consumes: `KokoroEngine.phonemes`, phoneme PCM synthesis, `KokoroPhonemeChunker`, `PCMFramer`, `TTSAudioPipe`.
- Produces: `KokoroTTSAudioSource`, concrete `KokoroTTSBackend.makeAudioSource(text:options:)`.

- [ ] **Step 1: Write source tests before implementation**

Required tests:

```swift
func testWholeInputIsPhonemizedOnceBeforeNormalChunking() async throws
func testSegmentsAreSynthesizedSequentiallyInOrder() async throws
func testPCMIsReframedBeforeLeavingSource() async throws
func testSynthesisContinuesAheadOfPlaybackUntilBackpressure() async throws
func testThirdSegmentStartsBeforeSecondSegmentIsConsumed() async throws
func testCancellationPreventsLaterSegments() async throws
func testAcousticFrameOverflowSplitsOnlyTheOffendingChunkAndRetries() async throws
func testAdaptiveSplitDepthIsBounded() async
func testGenericSynthesisFailureDoesNotTriggerSizeRetry() async
func testValidPCMBeforeLaterFailureDrainsThenThrows() async throws
```

For the concurrency regression, configure a large pipe watermark, consume only enough PCM to start the first segment, and assert the fake engine has already begun the third synthesis call after the second call completes.

- [ ] **Step 2: Run RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroTTSAudioSourceTests test
```

- [ ] **Step 3: Implement a producer-backed source**

Use a small wrapper that owns both the pipe source and producer task:

```swift
final class KokoroTTSAudioSource: TTSAudioSource, @unchecked Sendable {
    private let source: TTSAudioPipeSource
    private let producer: Task<Void, Never>

    init(source: TTSAudioPipeSource, producer: Task<Void, Never>) {
        self.source = source
        self.producer = producer
    }

    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }

    func cancel() async {
        producer.cancel()
        await source.cancel()
    }
}
```

The only reason for `@unchecked Sendable` is the immutable references to a Sendable pipe source and `Task`; document that invariant in the file.

- [ ] **Step 4: Implement the factory/producer algorithm**

The backend-side factory sequence is exactly:

```text
load locally only
resolve voice + speed
phonemes = engine.phonemes(full text)     # once
chunks = chunker.chunks(phonemes)
make 30s/15s pipe
launch one producer task
return KokoroTTSAudioSource
```

Producer pseudocode must be implemented directly:

```swift
var queue = chunks.map { WorkItem(phonemes: $0, splitDepth: 0) }
while !queue.isEmpty {
    try Task.checkCancellation()
    let item = queue.removeFirst()

    do {
        let pcm = try await engine.synthesize(
            phonemes: item.phonemes,
            voice: voice,
            speed: speed
        )
        let format = TTSAudioFormat(sampleRate: pcm.sampleRate, channelCount: 1)
        for frame in try PCMFramer.frames(samples: pcm.samples, format: format) {
            try Task.checkCancellation()
            try await sink.yield(frame)
        }
    } catch KokoroEngineError.acousticFramesTooLong {
        guard item.splitDepth < 8 else {
            await sink.fail(.inferenceFailed("Kokoro synthesis failed"))
            return
        }
        let pieces = chunker.splitForRetry(item.phonemes)
        guard pieces.count > 1, pieces.allSatisfy({ $0.count < item.phonemes.count }) else {
            await sink.fail(.inferenceFailed("Kokoro synthesis failed"))
            return
        }
        queue.insert(
            contentsOf: pieces.map { WorkItem(phonemes: $0, splitDepth: item.splitDepth + 1) },
            at: 0
        )
    } catch is CancellationError {
        await source.cancel()
        return
    } catch {
        await sink.fail(.inferenceFailed("Kokoro synthesis failed"))
        return
    }
}
await sink.finish()
```

Do not retry `.synthesisFailed` or model/load failures as if they were size failures.

- [ ] **Step 5: Add `KokoroTTSBackend.makeAudioSource` and reuse it from the temporary legacy `speak`**

The backend still conforms to the old protocol until the final cutover, but its `speak` body becomes only:

```swift
let source = try await makeAudioSource(text: text, options: options)
try await player.startPlayback(source, sessionID: sessionID)
```

Change Kokoro's injected player from `SynthesizedAudioPlaying` to the shared source-based `StreamingAudioPlaying`/`StreamingAudioPlayer` seam. Kokoro must no longer create or decode WAV data.

- [ ] **Step 6: Pin Kokoro's no-download-on-speak invariant**

Add a backend/source-factory test that calls `makeAudioSource(text:options:)` with a fake engine and asserts the backend invoked only the local load path:

```swift
XCTAssertEqual(await engine.localLoadCount, 1)
XCTAssertEqual(await engine.downloadLoadCount, 0)
```

This is the Kokoro counterpart to Task 7's PocketTTS regression.

- [ ] **Step 7: Delete the now-unused old text-to-WAV Kokoro engine method**

Once `KokoroTTSBackend` has no caller for it, remove the temporary `synthesize(text:voice:speed:) -> Data` seam and update its tests/fakes.

`rg 'synthesize\(text:.*Kokoro|SynthesizedAudio' Relay/Backends/KokoroTTSBackend.swift Relay/Backends/FluidAudioKokoroEngine.swift` should show no production whole-WAV path.

- [ ] **Step 8: Run targeted and full tests**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/KokoroTTSAudioSourceTests -only-testing:RelayTests/KokoroTTSBackendTests -only-testing:RelayTests/FluidAudioKokoroEngineTests test
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

- [ ] **Step 9: Commit**

```bash
git add Relay/SpeechOut/KokoroTTSAudioSource.swift Relay/Backends/KokoroTTSBackend.swift Relay/Backends/FluidAudioKokoroEngine.swift RelayTests/SpeechOut/KokoroTTSAudioSourceTests.swift RelayTests/Backends/KokoroTTSBackendTests.swift RelayTests/Backends/FluidAudioKokoroEngineTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add long-form Kokoro streaming source"
```

---

# Phase 5 - Apple generated-audio adapter

## Task 11: Build and validate `AppleTTSAudioSource`

**Files:**
- Create: `Relay/SpeechOut/AppleTTSAudioSource.swift`
- Create: `RelayTests/SpeechOut/AppleTTSAudioSourceTests.swift`
- Modify: `Relay/SpeechOut/AppleTTSBackend.swift`
- Modify: `RelayTests/SpeechOut/AppleTTSBackendTests.swift`

**Interfaces:**
- Consumes: `AVSpeechSynthesizer.write(_:toBufferCallback:)`.
- Produces: `AppleTTSAudioSource`, concrete `AppleTTSBackend.makeAudioSource(text:options:)` ahead of final protocol cutover.

- [ ] **Step 1: Extend the test synthesizer seam with generated-buffer output**

Replace the old speak-only seam with one that can test both the legacy path and source path during this task:

```swift
@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    func speak(_ utterance: AVSpeechUtterance)
    func write(
        _ utterance: AVSpeechUtterance,
        toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback
    )
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}
```

Production `AVSpeechSynthesizer` already provides both methods.

- [ ] **Step 2: Write source tests**

Pin:

```swift
func testVoiceAndRateAreAppliedBeforeWriteStarts() async throws
func testCallbackBuffersRemainInOrder() async throws
func testZeroLengthCallbackFinishesTheSource() async throws
func testCancelStopsGenerationAndRejectsLateCallbacks() async throws
func testRapidReplacementCannotLeakOldPCM() async throws
func testLongCallbackSequenceStaysBounded() async throws
```

The zero-length-buffer end signal is treated as an AVFoundation adapter detail and is part of the manual reliability gate below, not assumed to be a general `TTSAudioSource` rule.

- [ ] **Step 3: Implement a synchronous bounded callback bridge**

The `write` callback cannot `await`, so do **not** launch an unbounded `Task` per buffer.

Create a private `AppleSpeechBufferBridge` with a fixed capacity of 8 copied PCM frames. Use `NSCondition` only for the synchronous producer-side capacity wait and one stored checked continuation for an async consumer:

```swift
private final class AppleSpeechBufferBridge: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var queue: [TTSAudioFrame] = []
    private var waiter: CheckedContinuation<TTSAudioFrame?, Error>?
    private var finished = false
    private var cancelled = false
    private var failure: SpeechBackendError?

    init(capacity: Int = 8) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func push(_ frame: TTSAudioFrame) {
        condition.lock()
        while queue.count >= capacity && !cancelled && !finished && failure == nil {
            condition.wait()
        }
        guard !cancelled, !finished, failure == nil else {
            condition.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: frame)
        } else {
            queue.append(frame)
            condition.unlock()
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            if !queue.isEmpty {
                let frame = queue.removeFirst()
                condition.signal()
                condition.unlock()
                continuation.resume(returning: frame)
            } else if let failure {
                condition.unlock()
                continuation.resume(throwing: failure)
            } else if finished {
                condition.unlock()
                continuation.resume(returning: nil)
            } else if cancelled {
                condition.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                waiter = continuation
                condition.unlock()
            }
        }
    }

    func finish() { /* lock, mark finished, resume waiter with nil, broadcast */ }
    func fail(_ error: SpeechBackendError) { /* lock, store error, resume waiter throwing, broadcast */ }
    func cancel() { /* lock, clear queue, mark cancelled, resume waiter throwing CancellationError, broadcast */ }
}
```

Implement the three terminal methods exactly according to their comments: each takes the condition lock, becomes a no-op if a terminal state already won, captures and clears `waiter`, broadcasts to wake a blocked producer, unlocks, then resumes the captured waiter outside the lock. Never resume a waiter twice.

The `write` callback converts and deep-copies the `AVAudioPCMBuffer`, then calls `bridge.push(frame)`. A zero-length callback calls `bridge.finish()`. Cancellation calls both `bridge.cancel()` and `synthesizer.stopSpeaking(at: .immediate)`. No callback creates a `Task`.

The bridge is intentionally Apple-specific. `TTSAudioPipe` remains the reusable async producer pipe for Kokoro.

- [ ] **Step 4: Add a synchronous PCM buffer converter**

Do not let `AVAudioBuffer` escape the callback. Deep-copy it before returning from the callback.

Normalize to interleaved Float32 with:

```swift
protocol AppleSpeechBufferConverting: Sendable {
    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame
}
```

The production converter uses `AVAudioConverter` when the callback format is not already Float32, then interleaves channels into `[Float]`. Tests inject a fake converter so unit tests do not depend on Apple's live voices.

- [ ] **Step 5: Build `AppleTTSAudioSource` with a dedicated synthesizer per source**

Use a synthesizer factory in `AppleTTSBackend`:

```swift
private let makeSynthesizer: @MainActor () -> any AppleSpeechSynthesizing
```

Each `makeAudioSource` call gets a fresh synthesizer owned by that source. This isolates Apple callback lifetime per Relay speech attempt and makes stale callback rejection simpler than sharing one synthesizer queue across sessions.

- [ ] **Step 6: Keep native Apple playback as a temporary compatibility path**

Do not delete current `speak`/delegate behavior yet. Add `makeAudioSource` and test it independently. The final router cutover happens only after the source passes the quality gate.

- [ ] **Step 7: Run automated tests GREEN**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/AppleTTSAudioSourceTests -only-testing:RelayTests/AppleTTSBackendTests test
```

- [ ] **Step 8: Perform the owner-Mac Apple quality gate before allowing Task 12**

Build and manually verify through a temporary test harness or focused debug branch that uses `makeAudioSource` + `StreamingAudioPlayer`:

```text
1. Short sentence speaks completely.
2. Multi-paragraph text speaks completely.
3. Stop before audible start produces no later stale audio.
4. Stop during generation is immediate.
5. Pause/resume affects playback correctly.
6. Rapid replacement A -> B never leaks A PCM into B.
7. Voice choice matches the configured Apple voice.
8. Rate matches the configured slider.
9. 100 sequential requests do not show unbounded resident-memory growth.
10. Startup latency is acceptable relative to native Apple playback.
```

Record the result in the implementation PR/commit message or a short `docs/superpowers/spikes/` result note if any workaround is needed. If this gate fails, do not perform the final all-backend cutover; Pocket/Kokoro may remain on the shared path while Apple stays as the documented compatibility exception.

- [ ] **Step 9: Commit**

```bash
git add Relay/SpeechOut/AppleTTSAudioSource.swift Relay/SpeechOut/AppleTTSBackend.swift RelayTests/SpeechOut/AppleTTSAudioSourceTests.swift RelayTests/SpeechOut/AppleTTSBackendTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(tts): add Apple generated-audio source"
```

---

# Phase 6 - Contract cutover and legacy deletion

## Task 12: Switch `TextToSpeechBackend` and `TTSRouter` to source production plus one shared player

**Files:**
- Modify: `Relay/SpeechOut/TextToSpeechBackend.swift`
- Modify: `Relay/SpeechOut/TTSRouter.swift`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift`
- Modify: `Relay/Backends/PocketTTSBackend.swift`
- Modify: `Relay/Backends/KokoroTTSBackend.swift`
- Modify: `Relay/SpeechOut/AppleTTSBackend.swift`
- Modify: `Relay/App/RelayRuntime.swift`
- Modify: `RelayTests/SpeechOut/TTSRouterTests.swift`
- Modify: `RelayTests/SpeechOut/SpeechCoordinatorTests.swift`
- Modify: backend tests for all three providers.

**Interfaces:**
- Produces final `TextToSpeechBackend.makeAudioSource(text:options:)` contract.
- Produces final `TTSRouter(backends:backendOrder:player:)` ownership model.

- [ ] **Step 1: Rewrite router fakes/tests for source production**

The fake backend records source requests and either returns a fake source or throws. The fake player controls whether `.started` occurs and whether failure is pre-start or post-start.

Pin these exact router cases:

```swift
func testScheduledEmittedExactlyOnceAcrossFallbackAttempts() async throws
func testMakeAudioSourceFailureFallsThrough() async throws
func testPreStartPlayerFailureFallsThrough() async throws
func testFirstStartedCommitsBackend() async throws
func testPostStartFailureDoesNotFallThrough() async throws
func testStartedEventReportsCommittedBackendIdentity() async throws
func testStopCancelsPlayer() async throws
func testSessionSpecificStopIgnoresStaleID() async throws
```

- [ ] **Step 2: Run router tests RED**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSRouterTests test
```

- [ ] **Step 3: Replace the backend protocol**

Final shape:

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

Delete from every backend:

```text
setPlaybackEventHandler
speak
stop
pause
resume
player property
playbackEventHandler property
```

- [ ] **Step 4: Give `TTSRouter` one shared player**

Constructor:

```swift
init(
    backends: [String: any TextToSpeechBackend],
    backendOrder: @escaping () -> [String],
    player: any StreamingAudioPlaying
)
```

The router installs one player event handler.

Store candidate state before `startPlayback`, because `.started` may arrive while `startPlayback` is suspended:

```swift
private struct CandidatePlayback {
    let backend: any TextToSpeechBackend
    let source: any TTSAudioSource
    let sessionID: UUID
    var committed: Bool
}
```

- [ ] **Step 5: Implement one-session `.scheduled` and fallback-before-start**

Algorithm:

```swift
func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
    eventHandler?(.scheduled(sessionID: sessionID), nil)
    var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

    for id in backendOrder() {
        guard let backend = backends[id] else { continue }
        guard case .available = await backend.availability() else { continue }

        let source: any TTSAudioSource
        do {
            source = try await backend.makeAudioSource(text: text, options: options)
        } catch let error as SpeechBackendError where error.isFallbackWorthy {
            lastError = error
            continue
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            eventHandler?(.failed(sessionID: sessionID), nil)
            throw error
        }

        candidate = CandidatePlayback(
            backend: backend,
            source: source,
            sessionID: sessionID,
            committed: false
        )

        do {
            try await player.startPlayback(source, sessionID: sessionID)
            return
        } catch is CancellationError {
            await source.cancel()
            candidate = nil
            throw CancellationError()
        } catch {
            // `startPlayback` only throws before `.started`; after `.started` the
            // player reports terminal failure asynchronously. A pre-start player
            // failure is therefore safe to classify as fallback-worthy.
            await source.cancel()
            candidate = nil
            lastError = .inferenceFailed("TTS playback failed")
            continue
        }
    }

    eventHandler?(.failed(sessionID: sessionID), nil)
    throw lastError
}
```

Do not emit an additional `.scheduled` per attempt.

- [ ] **Step 6: Commit on `.started`; clear only on terminal event**

The player's `.started` handler:

```text
verify session matches candidate
mark candidate committed
forward .started with candidate.backend
```

For `.level`, `.finished`, `.cancelled`, `.failed`, forward only matching-session events. After `.started`, `.failed` is terminal; the router must never loop back into backend selection.

- [ ] **Step 7: Move Stop/pause/resume entirely to the shared player**

`TTSRouter.stop()` calls only `player.stop()` and clears candidate/active state in response to the player's terminal event. `pause()` and `resume()` call only the player.

Preserve the stale-session guard in `stop(sessionID:)`.

- [ ] **Step 8: Construct one player in `RelayRuntime.makeProduction()`**

```swift
let ttsPlayer = StreamingAudioPlayer()
let router = TTSRouter(
    backends: ttsRegistry,
    backendOrder: { settingsBox.value.ttsBackendOrder },
    player: ttsPlayer
)
```

Backends receive engines/factories only, never players.

- [ ] **Step 9: Re-run `SpeechCoordinator` characterization tests unchanged**

Its observable event contract must remain identical. Only update comments that name backend-owned players.

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests -only-testing:RelayTests/KokoroTTSBackendTests -only-testing:RelayTests/PocketTTSBackendTests -only-testing:RelayTests/AppleTTSBackendTests test
```

- [ ] **Step 10: Run the full suite and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
git add Relay RelayTests Relay.xcodeproj/project.pbxproj
git commit -m "refactor(tts): route all backends through shared player"
```

---

## Task 13: Delete legacy playback paths and playback-only backend capabilities

**Files:**
- Delete: `Relay/SpeechOut/SynthesizedAudioPlayer.swift`
- Delete: `RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift`
- Modify: `Relay/Domain/SpeechModels.swift`
- Modify: `RelayTests/Domain/SpeechBackendContractsTests.swift`
- Modify: provider backend tests.

**Interfaces:**
- Produces final `TTSCapability` surface with synthesis/provider capabilities only.

- [ ] **Step 1: Write/adjust capability tests for the final meaning**

Final enum:

```swift
enum TTSCapability: Sendable {
    case voiceSelection
    case fullyOffline
}
```

Pin:

```text
Apple: voiceSelection + fullyOffline
Pocket: voiceSelection + fullyOffline
Kokoro: voiceSelection + fullyOffline
```

Pause/resume, output levels, and streaming are now guaranteed by the Relay playback pipeline rather than advertised per provider.

- [ ] **Step 2: Remove the old Pocket stream compatibility overload**

Delete from `StreamingAudioPlayer`:

```text
startPlayback(AsyncThrowingStream<[Float], Error>, sampleRate:, sessionID:)
LegacyFloatStreamAudioSource
fixed Pocket frame-size constants
```

Only `TTSAudioSource` remains.

- [ ] **Step 3: Delete `SynthesizedAudioPlayer` and its tests**

Then verify:

```bash
rg 'SynthesizedAudio(Player|Playing)|pauseResume|outputLevel|\.streaming' Relay RelayTests
```

Expected: no production TTS playback-capability or synthesized-WAV-player references. STT's `.streaming` capability is unrelated and remains.

- [ ] **Step 4: Regenerate and run full tests**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

- [ ] **Step 5: Commit**

```bash
git add -A Relay RelayTests Relay.xcodeproj/project.pbxproj
git commit -m "refactor(tts): remove legacy playback paths"
```

---

## Task 14: Final integration verification, long-form regression, and documentation

**Files:**
- Modify: `RelayTests/ProjectSmokeTests.swift`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-19-relay-unified-tts-migration-design.md` only if implementation discovered a factual API detail that must be recorded; do not silently change requirements.

**Interfaces:**
- Produces: final production-graph assertions and human-verifiable release checklist.

- [ ] **Step 1: Add final graph smoke assertions**

At minimum:

```swift
@MainActor
func testProductionTTSGraphUsesUnifiedModelManagersAndSharedSourceBackends() {
    let runtime = RelayRuntime.makeProduction()

    XCTAssertTrue(runtime.speechOut.ttsRegistry["pocket-tts"] is PocketTTSBackend)
    XCTAssertTrue(runtime.speechOut.ttsRegistry["kokoro"] is KokoroTTSBackend)
    XCTAssertTrue(runtime.speechOut.ttsRegistry["apple-tts"] is AppleTTSBackend)
    XCTAssertTrue(runtime.speechOut.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
    XCTAssertTrue(runtime.speechOut.ttsModelManagers["kokoro"] is KokoroModelManager)
    XCTAssertNil(runtime.speechOut.ttsModelManagers["apple-tts"])
}
```

The absence of backend-owned players is primarily a compile-time structural invariant from the final backend protocol and constructors.

- [ ] **Step 2: Add a 100-run Kokoro source stress regression using fakes**

This test does not load CoreML. It repeatedly creates a long-form Kokoro source with a fake engine, drains it completely, cancels/tears it down, and verifies:

```text
all runs finish
no source leaves a blocked producer
one synthesis call at a time
segment order stays stable
```

The manual owner-Mac check below covers real model memory.

- [ ] **Step 3: Run static deletion checks**

```bash
rg 'SpeechModelDownloading|ttsModelDownloaders|SynthesizedAudio(Player|Playing)' Relay RelayTests
```

Expected: no matches.

Check backend playback ownership:

```bash
rg 'setPlaybackEventHandler|func speak\(text:.*TTSOptions|func pause\(\)|func resume\(\)' Relay/Backends Relay/SpeechOut/AppleTTSBackend.swift
```

Expected: no TTS backend implementations; only router/player/coordinator playback APIs remain.

- [ ] **Step 4: Run the full clean generated-project suite**

```bash
rm -rf .derived-data
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Run owner-Mac acceptance with real backends**

Use a long prepared response of several paragraphs plus punctuation and a short code block after normal `RulesSpeechPreprocessor` handling.

Verify:

```text
PocketTTS
- starts with comparable latency to before
- pause/resume works
- Stop is immediate

Kokoro
- no textTooLong fallback for ordinary long response
- first segment starts before whole response synthesis completes
- speech crosses multiple chunk boundaries naturally
- no dropped/repeated sentence around boundaries
- pause for at least 20 seconds; memory stays bounded and synthesis eventually stops running ahead
- resume continues in order
- Stop during later-segment synthesis produces no stale audio

Apple
- only if Task 11 quality gate passed: shared-player path remains reliable for short/long/stop/pause/replacement

Routing
- missing Kokoro/Pocket model falls through before playback
- failure after audible start does not restart the answer in another voice
- overlay backend name matches the provider that actually started
- Replay Last and automatic queue behavior are unchanged
```

For Kokoro, repeat at least 20 long real-model runs and inspect Activity Monitor for obvious monotonically growing resident memory. Do not claim a leak-free result from unit tests alone.

- [ ] **Step 6: Update README architecture text**

Replace the old implication that each backend owns its speech path with a concise source/player description:

```text
TTS Router
   ↓
Apple / PocketTTS / Kokoro
   ↓
TTSAudioSource
   ↓
StreamingAudioPlayer
```

Mention that Kokoro supports long responses through phoneme-safe sequential chunking.

- [ ] **Step 7: Commit final verification/docs**

```bash
git add README.md RelayTests/ProjectSmokeTests.swift docs/superpowers/specs/2026-09-19-relay-unified-tts-migration-design.md Relay.xcodeproj/project.pbxproj
git commit -m "docs(tts): finalize unified TTS migration"
```

---

# Execution order and review gates

Run tasks strictly in order:

```text
1 Kokoro model manager
2 Pocket model manager
3 TTS model-management cutover
4 PCM/source primitives
5 bounded audio pipe
6 demand-bounded shared player
7 Pocket source adapter
8 Kokoro phoneme/PCM engine seam
9 Kokoro chunker
10 Kokoro long-form source
11 Apple generated-audio source + owner-Mac gate
12 backend/router contract cutover
13 legacy deletion
14 final verification/docs
```

The two highest-risk reviewer gates are:

1. **After Task 6:** confirm player demand is truly bounded. If `StreamingAudioPlayer` still greedily pulls the source and merely schedules later, stop and fix that before Kokoro work.
2. **After Task 11:** do not cut Apple over merely because unit tests are green. The real `AVSpeechSynthesizer.write` behavior must pass the owner-Mac quality gate first.

If Apple fails its quality gate, stop before Task 12 and revise the design/plan for the documented temporary Apple-native compatibility exception rather than forcing Apple through an unreliable adapter.
