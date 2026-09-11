# Relay Phase 1: Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a useful standalone macOS Relay app that can read selected text aloud, stop/replay speech, capture dictation, transcribe through pluggable local STT backends, and insert text into the focused app.

**Architecture:** Relay is a menu-bar SwiftUI app. Speech input and speech output are core services behind backend protocols and routers; macOS-specific selection, clipboard, accessibility, microphone, and hotkey services live behind their own protocols. The phase deliberately excludes Claude/Codex integrations and session-focus intelligence.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, AVFoundation, Speech, ApplicationServices Accessibility APIs, CoreGraphics event taps, XcodeGen 2.46.0, FluidAudio 0.12.4, Argmax OSS Swift 1.0.0 (`WhisperKit` product), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-11-relay-design.md`

## Global Constraints

- macOS-only, Apple Silicon (`arm64`).
- Minimum app deployment target: macOS 14.0.
- `AppleSpeechBackend` is runtime-gated to macOS 26.0+; older supported systems report `.unsupportedOS` and fall back.
- Bundle identifier: `dev.relaymac.Relay`.
- Menu-bar app: `LSUIElement = true`; no Dock icon in v1.
- App Sandbox is disabled because Relay needs global hotkeys, Accessibility APIs, and cross-app text insertion.
- No paid Apple Developer Program requirement for local development; use local/ad-hoc signing during development.
- Audio, raw transcripts, processed transcripts, selected text, and spoken response text are ephemeral by default.
- No cloud STT/TTS providers in this phase.
- Local neural TTS is deferred from Phase 1; `AppleTTSBackend` is the sole initial TTS implementation, while `TTSRouter` preserves the provider/fallback abstraction for later backends.
- No dynamic plugin loading in this phase.
- Every user-facing hotkey is persisted and configurable.
- Starting dictation immediately stops active speech.
- Manual selected-text speech has higher priority than automatic speech sources added in later phases.
- Pin FluidAudio exactly to `0.12.4` and Argmax OSS Swift exactly to `1.0.0` for reproducible implementation; use its `WhisperKit` product for the Whisper backend.
- Project generation is controlled by `project.yml`; do not hand-edit `Relay.xcodeproj`.

---

## File Structure

```text
project.yml
Relay/
  App/
    RelayApp.swift
    AppModel.swift
    MenuBarContentView.swift
    SettingsView.swift
  Domain/
    BackendAvailability.swift
    SpeechBackendError.swift
    SpeechModels.swift
    HotkeyDefinition.swift
    AppSettings.swift
  SpeechOut/
    TextToSpeechBackend.swift
    TTSRouter.swift
    AppleTTSBackend.swift
    SpeechCoordinator.swift
    RulesSpeechPreprocessor.swift
  SpeechIn/
    SpeechToTextBackend.swift
    STTRouter.swift
    MicrophoneCapture.swift
    RulesTranscriptProcessor.swift
    DictationCoordinator.swift
  Backends/
    ParakeetBackend.swift
    AppleSpeechBackend.swift
    WhisperKitBackend.swift
  System/
    AccessibilityService.swift
    ClipboardService.swift
    SelectionReader.swift
    TextInsertionService.swift
    GlobalHotkeyManager.swift
    PermissionService.swift
RelayTests/
  Domain/
  SpeechOut/
  SpeechIn/
  System/
  Backends/
```

## Task 1: Scaffold the macOS menu-bar project

**Files:**
- Create: `project.yml`
- Create: `Relay/App/RelayApp.swift`
- Create: `Relay/App/AppModel.swift`
- Create: `Relay/App/MenuBarContentView.swift`
- Create: `Relay/App/SettingsView.swift`
- Create: `RelayTests/ProjectSmokeTests.swift`

**Interfaces:**
- Produces: buildable `Relay` app target and `RelayTests` unit-test target.

- [ ] **Step 1: Create `project.yml`**

```yaml
name: Relay
options:
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio.git
    exactVersion: 0.12.4
  ArgmaxOSS:
    url: https://github.com/argmaxinc/argmax-oss-swift.git
    exactVersion: 1.0.0
targets:
  Relay:
    type: application
    platform: macOS
    sources:
      - path: Relay
    dependencies:
      - package: FluidAudio
        product: FluidAudio
      - package: ArgmaxOSS
        product: WhisperKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.relaymac.Relay
        PRODUCT_NAME: Relay
        SWIFT_VERSION: 6.0
        ARCHS: arm64
        ONLY_ACTIVE_ARCH: YES
        CODE_SIGN_IDENTITY: "-"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Relay uses the microphone only while you dictate."
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Relay uses on-device speech recognition when the Apple Speech backend is selected."
  RelayTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: RelayTests
    dependencies:
      - target: Relay
schemes:
  Relay:
    build:
      targets:
        Relay: all
        RelayTests: [test]
    test:
      targets:
        - RelayTests
```

- [ ] **Step 2: Add a minimal app shell**

```swift
// Relay/App/RelayApp.swift
import SwiftUI

@main
struct RelayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Relay", systemImage: "waveform") {
            MenuBarContentView(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
```

```swift
// Relay/App/AppModel.swift
import Observation

@MainActor
@Observable
final class AppModel {
    var statusText = "Ready"
}
```

```swift
// Relay/App/MenuBarContentView.swift
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
            Divider()
            SettingsLink { Text("Settings...") }
            Button("Quit Relay") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}
```

```swift
// Relay/App/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Text("Relay settings")
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}
```

- [ ] **Step 3: Add a smoke test**

```swift
// RelayTests/ProjectSmokeTests.swift
import XCTest
@testable import Relay

final class ProjectSmokeTests: XCTestCase {
    func testAppModelStartsReady() async {
        let model = await MainActor.run { AppModel() }
        let status = await MainActor.run { model.statusText }
        XCTAssertEqual(status, "Ready")
    }
}
```

- [ ] **Step 4: Generate and test**

Run:

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add project.yml Relay RelayTests
git commit -m "chore: scaffold Relay macOS app"
```

## Task 2: Define speech backend contracts and shared models

**Files:**
- Create: `Relay/Domain/BackendAvailability.swift`
- Create: `Relay/Domain/SpeechBackendError.swift`
- Create: `Relay/Domain/SpeechModels.swift`
- Create: `Relay/SpeechIn/SpeechToTextBackend.swift`
- Create: `Relay/SpeechOut/TextToSpeechBackend.swift`
- Test: `RelayTests/Domain/SpeechBackendContractsTests.swift`

**Interfaces:**
- Produces: `BackendAvailability`, `SpeechBackendError`, `AudioInput`, `Transcript`, `STTOptions`, `TTSOptions`, `SpeechRequest`, `SpeechSource`, `SpeechMode`, `SpeechToTextBackend`, `TextToSpeechBackend`.

- [ ] **Step 1: Write failing contract tests**

```swift
import XCTest
@testable import Relay

final class SpeechBackendContractsTests: XCTestCase {
    func testBackendErrorFallbackClassification() {
        XCTAssertTrue(SpeechBackendError.modelNotDownloaded.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.initializationFailed("x").isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.permissionDenied.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.noUsableAudio.isFallbackWorthy)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/SpeechBackendContractsTests test
```

Expected: compile failure because the domain types do not exist.

- [ ] **Step 3: Implement the shared models**

```swift
// Relay/Domain/BackendAvailability.swift
import Foundation

enum BackendAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    case modelNotDownloaded
    case permissionDenied
    case unsupportedOS
    case unsupportedHardware
    case initializing
    case failed(String)
}
```

```swift
// Relay/Domain/SpeechBackendError.swift
import Foundation

enum SpeechBackendError: Error, Equatable, Sendable {
    case unavailable(String)
    case modelNotDownloaded
    case initializationFailed(String)
    case unsupportedOS
    case unsupportedHardware
    case inferenceFailed(String)
    case resourceExhausted
    case permissionDenied
    case noUsableAudio
    case invalidInput

    var isFallbackWorthy: Bool {
        switch self {
        case .unavailable, .modelNotDownloaded, .initializationFailed,
             .unsupportedOS, .unsupportedHardware, .inferenceFailed,
             .resourceExhausted:
            true
        case .permissionDenied, .noUsableAudio, .invalidInput:
            false
        }
    }
}
```

```swift
// Relay/Domain/SpeechModels.swift
import Foundation

struct AudioInput: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

struct Transcript: Sendable, Equatable {
    let text: String
    let backendID: String
}

struct STTOptions: Sendable, Equatable {
    var localeIdentifier = Locale.current.identifier
}

struct TTSOptions: Sendable, Equatable {
    var voiceIdentifier: String?
    var rate: Float = 0.5
}

enum SpeechSource: String, Sendable, Codable {
    case selection
    case manualReplay
    case futureIntegration
}

enum SpeechMode: String, Sendable, Codable {
    case automatic
    case userRequested
}

struct SpeechRequest: Sendable, Equatable {
    let text: String
    let source: SpeechSource
    let mode: SpeechMode
    let sessionID: String?
}
```

```swift
// Relay/SpeechIn/SpeechToTextBackend.swift
protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    func availability() async -> BackendAvailability
    func prepare() async throws
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript
}
```

```swift
// Relay/SpeechOut/TextToSpeechBackend.swift
@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func availability() async -> BackendAvailability
    func speak(text: String, options: TTSOptions) async throws
    func stop()
    func pause()
    func resume()
}
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/SpeechBackendContractsTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Relay/Domain Relay/SpeechIn/SpeechToTextBackend.swift Relay/SpeechOut/TextToSpeechBackend.swift RelayTests/Domain
git commit -m "feat: define speech backend contracts"
```

## Task 3: Persist settings and configurable hotkey definitions

**Files:**
- Create: `Relay/Domain/HotkeyDefinition.swift`
- Create: `Relay/Domain/AppSettings.swift`
- Create: `Relay/System/SettingsStore.swift`
- Test: `RelayTests/Domain/AppSettingsTests.swift`

**Interfaces:**
- Produces: `HotkeyDefinition`, `HotkeyAction`, `DictationMode`, `AppSettings`, `SettingsStore`.

- [ ] **Step 1: Write serialization tests**

```swift
import XCTest
@testable import Relay

final class AppSettingsTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        var value = AppSettings.defaults
        value.dictationMode = .toggle
        value.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), value)
    }
}
```

- [ ] **Step 2: Verify failure**

Run the single test target. Expected: compile failure for missing settings types.

- [ ] **Step 3: Implement exact settings types**

```swift
// Relay/Domain/HotkeyDefinition.swift
import Foundation

enum HotkeyModifier: String, Codable, Hashable, Sendable {
    case command, option, control, shift, function
}

enum HotkeyDefinition: Codable, Equatable, Sendable {
    case modifierOnly(HotkeyModifier)
    case chord(keyCode: UInt16, modifiers: Set<HotkeyModifier>)
}

enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case dictate
    case readSelection
    case stopSpeech
    case replayLast
    case toggleAutoRead
}

enum DictationMode: String, Codable, Sendable {
    case holdToTalk
    case toggle
}
```

```swift
// Relay/Domain/AppSettings.swift
import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsVoiceIdentifier: String?
    var ttsRate: Float
    var autoReadEnabled: Bool

    static let defaults = AppSettings(
        dictationMode: .holdToTalk,
        hotkeys: [
            .dictate: .modifierOnly(.function),
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .stopSpeech: .chord(keyCode: 53, modifiers: []),
            .replayLast: .chord(keyCode: 15, modifiers: [.option, .shift]),
            .toggleAutoRead: .chord(keyCode: 0, modifiers: [.option, .shift])
        ],
        sttBackendOrder: ["parakeet", "apple-speech", "whisperkit"],
        ttsBackendOrder: ["apple-tts"],
        ttsVoiceIdentifier: nil,
        ttsRate: 0.5,
        autoReadEnabled: true
    )
}
```

```swift
// Relay/System/SettingsStore.swift
import Foundation

@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "relay.settings.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .defaults }
        return value
    }

    func save(_ value: AppSettings) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
```

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/AppSettingsTests test
git add Relay/Domain Relay/System/SettingsStore.swift RelayTests/Domain
git commit -m "feat: add Relay settings model"
```

## Task 4: Implement TTS routing, Apple TTS, and speech arbitration

**Files:**
- Create: `Relay/SpeechOut/TTSRouter.swift`
- Create: `Relay/SpeechOut/AppleTTSBackend.swift`
- Create: `Relay/SpeechOut/SpeechCoordinator.swift`
- Test: `RelayTests/SpeechOut/TTSRouterTests.swift`
- Test: `RelayTests/SpeechOut/SpeechCoordinatorTests.swift`

**Interfaces:**
- Produces: `TTSRouter.speak(text:options:)`, `SpeechCoordinator.speak(_:)`, `stop()`, `replayLast()`.

- [ ] **Step 1: Write fallback and replay tests using a fake backend**

```swift
@MainActor
final class FakeTTSBackend: TextToSpeechBackend {
    let id: String
    let displayName: String
    var availabilityValue: BackendAvailability = .available
    var error: Error?
    var spoken: [String] = []
    var stopCount = 0

    init(id: String) { self.id = id; self.displayName = id }
    func availability() async -> BackendAvailability { availabilityValue }
    func speak(text: String, options: TTSOptions) async throws {
        if let error { throw error }
        spoken.append(text)
    }
    func stop() { stopCount += 1 }
    func pause() {}
    func resume() {}
}

@MainActor
func testRouterFallsBackOnBackendFailure() async throws {
    let first = FakeTTSBackend(id: "first")
    first.error = SpeechBackendError.inferenceFailed("boom")
    let second = FakeTTSBackend(id: "second")
    let router = TTSRouter(backends: [first, second])
    try await router.speak(text: "hello", options: .init(voiceIdentifier: nil, rate: 0.5))
    XCTAssertEqual(second.spoken, ["hello"])
}
```

- [ ] **Step 2: Verify tests fail**

Expected: missing router/coordinator types.

- [ ] **Step 3: Implement the router and Apple backend**

```swift
// Relay/SpeechOut/TTSRouter.swift
@MainActor
final class TTSRouter {
    private var backends: [any TextToSpeechBackend]
    private var active: (any TextToSpeechBackend)?

    init(backends: [any TextToSpeechBackend]) { self.backends = backends }

    func speak(text: String, options: TTSOptions) async throws {
        var lastError: Error = SpeechBackendError.unavailable("No TTS backend")
        for backend in backends {
            guard case .available = await backend.availability() else { continue }
            do {
                try await backend.speak(text: text, options: options)
                active = backend
                return
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                throw error
            }
        }
        throw lastError
    }

    func stop() { active?.stop(); active = nil }
    func pause() { active?.pause() }
    func resume() { active?.resume() }
}
```

```swift
// Relay/SpeechOut/AppleTTSBackend.swift
import AVFoundation

@MainActor
final class AppleTTSBackend: TextToSpeechBackend {
    let id = "apple-tts"
    let displayName = "Apple System Voice"
    private let synthesizer = AVSpeechSynthesizer()

    func availability() async -> BackendAvailability { .available }

    func speak(text: String, options: TTSOptions) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = options.rate
        if let id = options.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
    func pause() { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() { synthesizer.continueSpeaking() }
}
```

- [ ] **Step 4: Implement `SpeechCoordinator` with user-requested replacement semantics**

```swift
// Relay/SpeechOut/SpeechCoordinator.swift
@MainActor
final class SpeechCoordinator {
    private let router: TTSRouter
    private var lastRequest: SpeechRequest?
    private let options: () -> TTSOptions

    init(router: TTSRouter, options: @escaping () -> TTSOptions) {
        self.router = router
        self.options = options
    }

    func speak(_ request: SpeechRequest) async throws {
        if request.mode == .userRequested { router.stop() }
        try await router.speak(text: request.text, options: options())
        lastRequest = request
    }

    func stop() { router.stop() }

    func replayLast() async throws {
        guard let lastRequest else { return }
        router.stop()
        try await router.speak(text: lastRequest.text, options: options())
    }
}
```

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests test
git add Relay/SpeechOut RelayTests/SpeechOut
git commit -m "feat: add speech output core"
```

## Task 5: Add rules-only speech preprocessing

**Files:**
- Create: `Relay/SpeechOut/RulesSpeechPreprocessor.swift`
- Test: `RelayTests/SpeechOut/RulesSpeechPreprocessorTests.swift`

**Interfaces:**
- Produces: `RulesSpeechPreprocessor.prepare(text:mode:) -> String`.

- [ ] **Step 1: Write tests for Markdown and code behavior**

```swift
func testAutomaticModeReplacesLargeCodeBlock() {
    let source = """
    Fix this:\n```swift\nlet a = 1\nlet b = 2\nlet c = a + b\n```\nThen run tests.
    """
    let output = RulesSpeechPreprocessor().prepare(text: source, mode: .automatic)
    XCTAssertTrue(output.contains("code example on screen"))
    XCTAssertFalse(output.contains("```"))
}

func testUserRequestedModeKeepsCodeTextButRemovesFences() {
    let output = RulesSpeechPreprocessor().prepare(text: "```swift\nprint(1)\n```", mode: .userRequested)
    XCTAssertTrue(output.contains("print(1)"))
    XCTAssertFalse(output.contains("```"))
}
```

- [ ] **Step 2: Implement deterministic rules**

Implement these exact v1 rules:

```text
1. Strip Markdown heading markers, emphasis markers, blockquote markers, and link destinations while keeping visible link labels.
2. Convert bullets to sentence breaks.
3. For automatic mode, code blocks with >120 characters become: "There is a code example on screen.".
4. For user-requested mode, remove fences but retain code content.
5. Collapse 3+ whitespace characters/newlines into normal sentence spacing.
6. Do not summarize prose with an LLM in Phase 1.
```

- [ ] **Step 3: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/RulesSpeechPreprocessorTests test
git add Relay/SpeechOut/RulesSpeechPreprocessor.swift RelayTests/SpeechOut/RulesSpeechPreprocessorTests.swift
git commit -m "feat: preprocess text for speech"
```

## Task 6: Read selected text with Accessibility and clipboard fallback

**Files:**
- Create: `Relay/System/AccessibilityService.swift`
- Create: `Relay/System/ClipboardService.swift`
- Create: `Relay/System/SelectionReader.swift`
- Test: `RelayTests/System/SelectionReaderTests.swift`

**Interfaces:**
- Produces: `SelectionReading`, `AccessibilityReading`, `ClipboardReading`, `SelectionReader.readSelection()`.

- [ ] **Step 1: Write fallback-order tests with fakes**

```swift
func testUsesAccessibilityBeforeClipboard() throws {
    let ax = FakeAccessibilitySelection(value: "from ax")
    let clipboard = FakeClipboardSelection(value: "from clipboard")
    let reader = SelectionReader(accessibility: ax, clipboard: clipboard)
    XCTAssertEqual(try reader.readSelection(), "from ax")
    XCTAssertEqual(clipboard.copySelectionCallCount, 0)
}

func testFallsBackToClipboardWhenAXHasNoSelection() throws {
    let ax = FakeAccessibilitySelection(value: nil)
    let clipboard = FakeClipboardSelection(value: "fallback")
    XCTAssertEqual(try SelectionReader(accessibility: ax, clipboard: clipboard).readSelection(), "fallback")
}
```

- [ ] **Step 2: Implement Accessibility selected-text lookup**

Use `AXUIElementCreateSystemWide()`, read `kAXFocusedUIElementAttribute`, then read `kAXSelectedTextAttribute`. Return `nil` for unsupported attributes instead of throwing a backend error.

- [ ] **Step 3: Implement clipboard fallback**

`ClipboardService.copyCurrentSelection()` must:

```text
- Snapshot `NSPasteboard.general.pasteboardItems` into in-memory Data/property-list representations.
- Synthesize Command-C through `CGEvent`.
- Wait up to 200 ms in 20 ms increments for `changeCount` to change.
- Read `NSPasteboard.PasteboardType.string`.
- Restore the prior clipboard contents after the string is captured.
```

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/SelectionReaderTests test
git add Relay/System RelayTests/System/SelectionReaderTests.swift
git commit -m "feat: read selected text system wide"
```

## Task 7: Implement configurable global hotkeys and wire selected-text speech

**Files:**
- Create: `Relay/System/GlobalHotkeyManager.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/SettingsView.swift`
- Test: `RelayTests/System/GlobalHotkeyManagerTests.swift`

**Interfaces:**
- Produces: `GlobalHotkeyManager.register(settings:handler:)` and hotkey action callbacks.

- [ ] **Step 1: Unit-test event matching separately from the real event tap**

Create a pure `HotkeyMatcher` inside `GlobalHotkeyManager.swift` and test modifier-only Fn press/release plus chord matching. Do not make XCTest depend on live keyboard events.

- [ ] **Step 2: Implement a `CGEventTap`**

Use a session event tap listening for `.keyDown`, `.keyUp`, and `.flagsChanged`. Track the `.maskSecondaryFn` flag for modifier-only Fn. Convert key events to `HotkeyDefinition` and dispatch `HotkeyAction` on the main actor.

- [ ] **Step 3: Wire read-selection, stop, and replay**

`AppModel` owns `SelectionReader`, `RulesSpeechPreprocessor`, `SpeechCoordinator`, and `GlobalHotkeyManager`. For `.readSelection`, read text, preprocess with `.userRequested`, then submit a `SpeechRequest(source: .selection, mode: .userRequested)`.

- [ ] **Step 4: Add editable settings controls**

Settings must expose each `HotkeyAction`, dictation mode, Apple TTS voice picker from `AVSpeechSynthesisVoice.speechVoices()`, and speech rate. Save changes through `SettingsStore` and re-register hotkeys immediately.

- [ ] **Step 5: Run tests and manually verify**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

Manual acceptance: select text in Safari/TextEdit/Ghostty, press the configured read-selection hotkey, hear speech; press the configured stop key, speech stops; press replay, the same prepared text is spoken again.

- [ ] **Step 6: Commit**

```bash
git add Relay/App Relay/System RelayTests/System
git commit -m "feat: add configurable Relay hotkeys"
```

## Task 8: Capture microphone audio into a backend-neutral format

**Files:**
- Create: `Relay/SpeechIn/MicrophoneCapture.swift`
- Create: `Relay/System/PermissionService.swift`
- Test: `RelayTests/SpeechIn/MicrophoneCaptureStateTests.swift`

**Interfaces:**
- Produces: `MicrophoneCapturing.start()`, `stop() async throws -> AudioInput`; output is mono Float32 at 16 kHz.

- [ ] **Step 1: Test the capture state machine with a fake audio source**

Test exact transitions: `idle -> recording -> idle`, reject double-start, reject stop while idle, and treat zero samples as `SpeechBackendError.noUsableAudio`.

- [ ] **Step 2: Implement microphone permission**

Use `AVCaptureDevice.authorizationStatus(for: .audio)` and `AVCaptureDevice.requestAccess(for: .audio)`.

- [ ] **Step 3: Implement `AVAudioEngine` capture**

Install an input-node tap, convert each buffer with `AVAudioConverter` to mono Float32 16,000 Hz, append samples in an actor-protected buffer, and remove the tap on stop. Do not write temporary audio files.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/MicrophoneCaptureStateTests test
git add Relay/SpeechIn/MicrophoneCapture.swift Relay/System/PermissionService.swift RelayTests/SpeechIn
git commit -m "feat: capture dictation audio"
```

## Task 9: Implement STT fallback routing

**Files:**
- Create: `Relay/SpeechIn/STTRouter.swift`
- Test: `RelayTests/SpeechIn/STTRouterTests.swift`

**Interfaces:**
- Produces: `STTRouter.transcribe(audio:options:)`.

- [ ] **Step 1: Write tests for exact fallback policy**

Cover:

```text
- unavailable primary -> secondary runs
- modelNotDownloaded primary -> secondary runs
- initializationFailed primary -> secondary runs
- resourceExhausted primary -> secondary runs
- permissionDenied -> stop immediately, no fallback
- noUsableAudio -> stop immediately, no fallback
- all backends fail -> last fallback-worthy error is returned
```

- [ ] **Step 2: Implement router using ordered backend IDs from settings**

The router must never know Parakeet/Apple/WhisperKit concrete types. It receives a `[String: any SpeechToTextBackend]` registry plus a closure returning current ordered IDs.

- [ ] **Step 3: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/STTRouterTests test
git add Relay/SpeechIn/STTRouter.swift RelayTests/SpeechIn/STTRouterTests.swift
git commit -m "feat: add STT fallback router"
```

## Task 10: Implement the Parakeet backend with FluidAudio

**Files:**
- Create: `Relay/Backends/ParakeetBackend.swift`
- Test: `RelayTests/Backends/ParakeetBackendTests.swift`

**Interfaces:**
- Produces backend ID `parakeet` implementing `SpeechToTextBackend`.

- [ ] **Step 1: Write non-network unit tests around a FluidAudio adapter protocol**

Define an internal `ParakeetEngine` protocol so tests can verify that 16 kHz samples are forwarded and the returned text is wrapped in `Transcript(backendID: "parakeet")` without downloading a model.

- [ ] **Step 2: Implement the production engine pinned to FluidAudio 0.12.4**

Use `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager(config: .default)`, `loadModels`, and `transcribe(samples)`. Map model-download/load failures to `modelNotDownloaded` or `initializationFailed`; inference failures map to `inferenceFailed`.

- [ ] **Step 3: Add a manual backend smoke test**

Record one five-second sample through `MicrophoneCapture`, call the backend, and confirm a non-empty transcript without network access after the first model download.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/ParakeetBackendTests test
git add Relay/Backends/ParakeetBackend.swift RelayTests/Backends/ParakeetBackendTests.swift
git commit -m "feat: add Parakeet speech backend"
```

## Task 11: Implement the Apple Speech backend for macOS 26+

**Files:**
- Create: `Relay/Backends/AppleSpeechBackend.swift`
- Test: `RelayTests/Backends/AppleSpeechBackendTests.swift`

**Interfaces:**
- Produces backend ID `apple-speech`.

- [ ] **Step 1: Test runtime availability behavior**

On the test double for OS support, verify macOS <26 returns `.unsupportedOS`; supported hardware but unavailable `SpeechTranscriber` returns `.unsupportedHardware`.

- [ ] **Step 2: Implement the backend behind `@available(macOS 26.0, *)`**

Use `SpeechTranscriber.supportedLocale(equivalentTo:)`, `SpeechTranscriber(locale:preset: .transcription)`, `AssetInventory.status(forModules:)`, `AssetInventory.assetInstallationRequest(supporting:)`, and `downloadAndInstall()` for the selected locale. Build an `AVAudioPCMBuffer` from `AudioInput`, then use `SpeechAnalyzer` and reduce finalized `transcriber.results` to text.

- [ ] **Step 3: Keep the wrapper callable on macOS 14-25**

The public `AppleSpeechBackend` type must compile for the app minimum and dispatch into the macOS 26 implementation only inside `if #available(macOS 26.0, *)`.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/AppleSpeechBackendTests test
git add Relay/Backends/AppleSpeechBackend.swift RelayTests/Backends/AppleSpeechBackendTests.swift
git commit -m "feat: add Apple Speech backend"
```

## Task 12: Implement the WhisperKit backend

**Files:**
- Create: `Relay/Backends/WhisperKitBackend.swift`
- Test: `RelayTests/Backends/WhisperKitBackendTests.swift`

**Interfaces:**
- Produces backend ID `whisperkit`.

- [ ] **Step 1: Test through an internal Whisper adapter**

Verify availability, preparation, text wrapping, and error classification without downloading model weights in unit tests.

- [ ] **Step 2: Implement the production adapter against Argmax OSS Swift 1.0.0**

Import the `WhisperKit` product from Argmax OSS Swift 1.0.0. Initialize `WhisperKit` lazily using the v1.0 API, use its recommended device model, and transcribe the normalized sample array. Keep the top-level `WhisperKit` instance isolated inside the backend because the v1.0 release notes state that the kit class itself is not `Sendable`. The backend may download model assets during `prepare()`; preparation/inference failures are fallback-worthy.

- [ ] **Step 3: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/WhisperKitBackendTests test
git add Relay/Backends/WhisperKitBackend.swift RelayTests/Backends/WhisperKitBackendTests.swift
git commit -m "feat: add WhisperKit backend"
```

## Task 13: Process transcripts and insert text at the focused cursor

**Files:**
- Create: `Relay/SpeechIn/RulesTranscriptProcessor.swift`
- Create: `Relay/System/TextInsertionService.swift`
- Test: `RelayTests/SpeechIn/RulesTranscriptProcessorTests.swift`
- Test: `RelayTests/System/TextInsertionServiceTests.swift`

**Interfaces:**
- Produces: `RulesTranscriptProcessor.process(_:)`, `TextInsertionService.insert(_:)`.

- [ ] **Step 1: Test minimal deterministic transcript cleanup**

Rules for Phase 1:

```text
- trim leading/trailing whitespace
- collapse repeated spaces
- collapse three-or-more blank lines to one newline
- do not delete semantic filler words automatically yet
- do not invoke an LLM
```

- [ ] **Step 2: Implement focused-element insertion**

Try Accessibility first: obtain focused UI element and set/replace `kAXSelectedTextAttribute` where supported. If unsupported, use clipboard paste fallback: preserve clipboard, write transcript string, synthesize Command-V, wait 100 ms, then restore prior clipboard.

- [ ] **Step 3: Test fallback decisions through injected AX/clipboard fakes**

Do not use live Accessibility state in unit tests.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/RulesTranscriptProcessorTests -only-testing:RelayTests/TextInsertionServiceTests test
git add Relay/SpeechIn/RulesTranscriptProcessor.swift Relay/System/TextInsertionService.swift RelayTests
git commit -m "feat: insert processed dictation text"
```

## Task 14: Wire dictation end-to-end and finish Phase 1 UX

**Files:**
- Create: `Relay/SpeechIn/DictationCoordinator.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/MenuBarContentView.swift`
- Modify: `Relay/App/SettingsView.swift`
- Test: `RelayTests/SpeechIn/DictationCoordinatorTests.swift`

**Interfaces:**
- Produces complete Phase 1 app behavior.

- [ ] **Step 1: Test orchestration with fakes**

Exact test sequence:

```text
start dictation -> SpeechCoordinator.stop() called -> microphone starts
finish dictation -> microphone returns AudioInput -> STTRouter transcribes -> RulesTranscriptProcessor runs -> TextInsertionService inserts
STT failure -> no insertion and app status receives actionable error
```

- [ ] **Step 2: Implement `DictationCoordinator`**

Coordinator dependencies are `MicrophoneCapturing`, `STTRouter`, `RulesTranscriptProcessor`, `TextInsertionService`, and a closure that stops TTS. It must contain no concrete backend types.

- [ ] **Step 3: Register the three backends in `AppModel`**

Construct `ParakeetBackend`, `AppleSpeechBackend`, and `WhisperKitBackend`; construct `STTRouter` from the registry and current settings order; construct Apple TTS/router/coordinator; wire all hotkey actions.

- [ ] **Step 4: Complete settings UI**

Add reorderable/selectable STT preference controls, TTS voice/rate, hold-to-talk vs toggle, hotkey editing, and permission state/action rows for Microphone and Accessibility.

- [ ] **Step 5: Run the full automated suite**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Run Phase 1 manual acceptance matrix**

```text
[ ] Select text in Safari -> Read Selection speaks it.
[ ] Select text in Claude Desktop -> Read Selection speaks it when selection is accessible/copyable.
[ ] Select text in Ghostty -> Read Selection uses AX or clipboard fallback.
[ ] Stop hotkey halts speech immediately.
[ ] Replay hotkey replays the last spoken item.
[ ] Hold-to-talk dictation inserts text into TextEdit.
[ ] Hold-to-talk dictation inserts text at a Ghostty shell prompt.
[ ] Toggle dictation mode starts/stops correctly.
[ ] Starting dictation interrupts active TTS.
[ ] Removing the preferred STT model causes configured fallback rather than app failure.
[ ] Denying microphone permission does not cycle through STT backends.
[ ] Relaunch preserves hotkeys, backend order, voice, rate, and dictation mode.
[ ] Relaunch does not restore prior audio/transcripts/selected text.
```

- [ ] **Step 7: Commit Phase 1 completion**

```bash
git add Relay RelayTests project.yml
git commit -m "feat: complete Relay core voice loop"
```

## Phase 1 Exit Criteria

Phase 1 is complete only when a locally built Relay app can perform both directions without any agent integration:

```text
speech -> local STT -> focused app
selected text -> local Apple TTS -> speakers
```

The user can configure hotkeys and backend order, backend failure falls back only when appropriate, dictation interrupts TTS, and no speech/transcript history is persisted.

## Verified implementation references (2026-09-11)

- FluidAudio `0.12.4`: `https://github.com/FluidInference/FluidAudio`
- Argmax OSS Swift / WhisperKit product: `https://github.com/argmaxinc/argmax-oss-swift` (v1.0.0+)
- Apple SpeechAnalyzer/SpeechTranscriber: `https://developer.apple.com/videos/play/wwdc2025/277/`
- Apple `SpeechTranscriber`: `https://developer.apple.com/documentation/speech/speechtranscriber`
- Apple `AssetInventory`: `https://developer.apple.com/documentation/speech/assetinventory`
- Apple `AVSpeechSynthesizer`: `https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer`
- XcodeGen `2.46.0`: `https://github.com/yonaskolb/XcodeGen`
