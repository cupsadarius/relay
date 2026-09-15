# Relay Phase 1.5: Activity Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local, non-activating bottom-center activity overlay that reports Relay's listening, processing, speaking, and sanitized error states in Off, Minimal, or Interactive styles.

**Architecture:** A provider-neutral `ActivityOverlayModel` is the single typed source of presentation state and rejects stale session callbacks. SwiftUI maps that state to a compact capsule while a dedicated AppKit panel controller owns display selection, placement, and non-activating window behavior. TTS and dictation publish lifecycle events through protocol seams; neither backend layer knows about AppKit.

**Tech Stack:** Swift 6, SwiftUI, AppKit, AVFoundation, Observation, XCTest, XcodeGen 2.46.0.

**Spec:** `docs/superpowers/specs/2026-09-14-relay-activity-overlay-design.md`

## Global Constraints

- macOS-only, Apple Silicon (`arm64`), minimum deployment target macOS 14.0.
- Bundle identifier remains `dev.relaymac.Relay`; `LSUIElement = true`; App Sandbox remains disabled.
- `AppleTTSBackend` and Apple Speech remain the only production backends in this phase.
- Overlay style values are exactly `off`, `minimal`, and `interactive`; `interactive` is the default for new and migrated settings.
- The panel never becomes key or steals keyboard focus, joins all Spaces, and is full-screen auxiliary.
- Minimal target size is 154 × 40 points; Interactive target size is 282 × 62 points; bottom inset is 28 points from the chosen screen's visible frame.
- Activity callbacks, completion timers, and error timers mutate or dismiss only the matching session ID.
- No audio samples, selected text, clipboard text, transcripts, TTS request text, or raw backend error strings enter overlay state or diagnostics.
- Error visibility is 2.5 seconds; completion grace is 180 milliseconds.
- Reduce Motion removes scale and waveform motion while preserving opacity and color state changes.
- Project generation is controlled by `project.yml`; do not hand-edit `Relay.xcodeproj`.

---

## File Structure

```text
Relay/
  App/
    ActivityOverlayModel.swift          # typed session state, timers, and actions
    ActivityOverlayPresentation.swift   # pure state/style-to-view mapping
    ActivityOverlayView.swift           # SwiftUI capsule and accessibility
    ActivityOverlayWindowController.swift # NSPanel lifecycle and placement
    AppModel.swift                      # composition, host retention, and persisted style mutation
    SettingsView.swift                  # segmented style picker
  Domain/
    AppSettings.swift                   # persisted ActivityOverlayStyle + migration
  SpeechOut/
    TextToSpeechBackend.swift           # typed playback lifecycle contract
    AppleTTSBackend.swift               # AVSpeechSynthesizerDelegate adapter
    TTSRouter.swift                     # session-aware lifecycle forwarding
    SpeechCoordinator.swift             # overlay lifecycle mapping and stop control
  SpeechIn/
    MicrophoneCapture.swift             # normalized level output and cancellation
    DictationCoordinator.swift          # session lifecycle and cancel control
  System/
    Diagnostics.swift                   # sanitized overlay failure event
RelayTests/
  App/
    ActivityOverlayModelTests.swift
    ActivityOverlayPresentationTests.swift
    ActivityOverlayWindowControllerTests.swift
  Domain/AppSettingsTests.swift
  SpeechOut/{AppleTTSBackendTests,SpeechCoordinatorTests,TTSRouterTests}.swift
  SpeechIn/{MicrophoneCaptureStateTests,DictationCoordinatorTests}.swift
  System/DiagnosticsTests.swift
```

## Task 1: Persist and expose the overlay style

**Files:**
- Modify: `Relay/Domain/AppSettings.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/SettingsView.swift`
- Modify: `RelayTests/Domain/AppSettingsTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`

**Interfaces:**
- Produces: `ActivityOverlayStyle`, `AppSettings.activityOverlayStyle`, and `AppModel.setActivityOverlayStyle(_:)`.
- Preserves: every pre-overlay saved setting when `activityOverlayStyle` is absent.

- [x] **Step 1: Write failing migration, default, round-trip, and AppModel persistence tests**

```swift
func testDefaultsUseInteractiveActivityOverlay() {
    XCTAssertEqual(AppSettings.defaults.activityOverlayStyle, .interactive)
}

func testDecodingPreOverlaySettingsAddsInteractiveWithoutResettingOtherFields() throws {
    var saved = AppSettings.defaults
    saved.dictationMode = .toggle
    saved.ttsVoiceIdentifier = "voice.test"
    saved.ttsRate = 0.7
    saved.autoReadEnabled = false
    let encoded = try JSONEncoder().encode(saved)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "activityOverlayStyle")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded.activityOverlayStyle, .interactive)
    XCTAssertEqual(decoded.dictationMode, .toggle)
    XCTAssertEqual(decoded.ttsVoiceIdentifier, "voice.test")
    XCTAssertEqual(decoded.ttsRate, 0.7, accuracy: 0.0001)
    XCTAssertFalse(decoded.autoReadEnabled)
}

@MainActor
func testChangingActivityOverlayStylePersistsImmediately() {
    let store = FakeSettingsStore(settings: .defaults)
    let model = makeModel(settingsStore: store)
    model.setActivityOverlayStyle(.minimal)
    XCTAssertEqual(model.settings.activityOverlayStyle, .minimal)
    XCTAssertEqual(store.saved.last?.activityOverlayStyle, .minimal)
}
```

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/AppSettingsTests \
  -only-testing:RelayTests/AppModelTests test
```

Expected: compile failures because `ActivityOverlayStyle`, `activityOverlayStyle`, and the setter do not exist.

- [x] **Step 3: Add the persisted type and lossless legacy decode**

```swift
enum ActivityOverlayStyle: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case interactive
}

struct AppSettings: Codable, Equatable, Sendable {
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsVoiceIdentifier: String?
    var ttsRate: Float
    var autoReadEnabled: Bool
    var activityOverlayStyle: ActivityOverlayStyle

    private enum CodingKeys: String, CodingKey {
        case dictationMode, hotkeys, sttBackendOrder, ttsBackendOrder
        case ttsVoiceIdentifier, ttsRate, autoReadEnabled, activityOverlayStyle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dictationMode = try values.decode(DictationMode.self, forKey: .dictationMode)
        hotkeys = try values.decode([HotkeyAction: HotkeyDefinition].self, forKey: .hotkeys)
        sttBackendOrder = try values.decode([String].self, forKey: .sttBackendOrder)
        ttsBackendOrder = try values.decode([String].self, forKey: .ttsBackendOrder)
        ttsVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .ttsVoiceIdentifier)
        ttsRate = try values.decode(Float.self, forKey: .ttsRate)
        autoReadEnabled = try values.decode(Bool.self, forKey: .autoReadEnabled)
        activityOverlayStyle = try values.decodeIfPresent(ActivityOverlayStyle.self, forKey: .activityOverlayStyle) ?? .interactive
    }

    init(
        dictationMode: DictationMode,
        hotkeys: [HotkeyAction: HotkeyDefinition],
        sttBackendOrder: [String],
        ttsBackendOrder: [String],
        ttsVoiceIdentifier: String?,
        ttsRate: Float,
        autoReadEnabled: Bool,
        activityOverlayStyle: ActivityOverlayStyle
    ) {
        self.dictationMode = dictationMode
        self.hotkeys = hotkeys
        self.sttBackendOrder = sttBackendOrder
        self.ttsBackendOrder = ttsBackendOrder
        self.ttsVoiceIdentifier = ttsVoiceIdentifier
        self.ttsRate = ttsRate
        self.autoReadEnabled = autoReadEnabled
        self.activityOverlayStyle = activityOverlayStyle
    }
}
```

Keep the existing memberwise initializer available by adding it explicitly, and pass `activityOverlayStyle: .interactive` from `AppSettings.defaults`.

- [x] **Step 4: Add the model setter and segmented Settings picker**

```swift
func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
    updateSettings { $0.activityOverlayStyle = style }
}

private var activityOverlayStyleBinding: Binding<ActivityOverlayStyle> {
    Binding(
        get: { model.settings.activityOverlayStyle },
        set: { model.setActivityOverlayStyle($0) }
    )
}
```

Add a `Section("Activity Overlay")` with a `.segmented` picker whose labels are `Off`, `Minimal`, and `Interactive`. Increase the fixed Settings height only enough to avoid clipping.

- [x] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [x] **Step 6: Commit**

```bash
git add Relay/Domain/AppSettings.swift Relay/App/AppModel.swift Relay/App/SettingsView.swift \
  RelayTests/Domain/AppSettingsTests.swift RelayTests/App/AppModelTests.swift
git commit -m "feat(overlay): persist activity overlay style"
```

## Task 2: Build the session-safe activity state model

**Files:**
- Create: `Relay/App/ActivityOverlayModel.swift`
- Create: `RelayTests/App/ActivityOverlayModelTests.swift`

**Interfaces:**
- Produces: `ActivityOverlayState`, `ActivityOverlayErrorCategory`, `ActivityOverlayAction`, `ActivityOverlayScheduling`, and `ActivityOverlayModel`.
- Consumers call trusted `begin`, then `listen`, `updateLevel`, `process`, `speak`, `complete`, `cancel`, and `fail` with the same UUID.

- [x] **Step 1: Write failing reducer and timer race tests**

```swift
@MainActor
func testStaleCallbacksCannotMutateNewerSession() {
    let scheduler = FakeOverlayScheduler()
    let model = ActivityOverlayModel(scheduler: scheduler)
    let old = UUID(), new = UUID()
    model.begin(sessionID: old)
    model.listen(sessionID: old, startedAt: .distantPast)
    model.begin(sessionID: new)
    model.listen(sessionID: new, startedAt: .now)
    model.updateLevel(0.9, sessionID: old)
    model.complete(sessionID: old)
    XCTAssertEqual(model.state.sessionID, new)
}

@MainActor
func testMatchingCompletionHidesAfterGracePeriod() {
    let scheduler = FakeOverlayScheduler()
    let model = ActivityOverlayModel(scheduler: scheduler)
    let session = UUID()
    model.begin(sessionID: session)
    model.speak(sessionID: session, startedAt: .now)
    model.complete(sessionID: session)
    XCTAssertFalse(model.state.isHidden)
    scheduler.run(after: .milliseconds(180))
    XCTAssertTrue(model.state.isHidden)
}

@MainActor
func testOldErrorDismissalCannotHideNewActivity() {
    let scheduler = FakeOverlayScheduler()
    let model = ActivityOverlayModel(scheduler: scheduler)
    let old = UUID(), new = UUID()
    model.begin(sessionID: old)
    model.fail(sessionID: old, category: .speechPlayback, message: "Speech playback failed.")
    model.begin(sessionID: new)
    model.listen(sessionID: new, startedAt: .now)
    scheduler.run(after: .milliseconds(2_500))
    XCTAssertEqual(model.state.sessionID, new)
}

@MainActor
func testLateFailureCannotResurrectCompletedSession() {
    let scheduler = FakeOverlayScheduler()
    let model = ActivityOverlayModel(scheduler: scheduler)
    let session = UUID()
    model.begin(sessionID: session)
    model.speak(sessionID: session, startedAt: .now)
    model.complete(sessionID: session)
    scheduler.run(after: .milliseconds(180))
    model.fail(sessionID: session, category: .speechPlayback, message: "Speech playback failed.")
    XCTAssertTrue(model.state.isHidden)
}
```

Also cover level clamping to `0...1`, listening→processing with the same start time, matching cancellation, and state-derived actions (`Cancel` for listening/processing, `Stop` for speaking).

- [x] **Step 2: Run the focused model tests and verify RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/ActivityOverlayModelTests test
```

Expected: compile failure because the activity model types do not exist.

- [x] **Step 3: Implement the typed model and injectable timer**

```swift
enum ActivityOverlayErrorCategory: Equatable, Sendable {
    case microphone, speechRecognition, noUsableAudio, speechPlayback, insertion, unexpected
}

enum ActivityOverlayState: Equatable, Sendable {
    case hidden
    case listening(sessionID: UUID, startedAt: Date, level: Float)
    case processing(sessionID: UUID, startedAt: Date)
    case speaking(sessionID: UUID, startedAt: Date)
    case error(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String)

    var sessionID: UUID? {
        switch self {
        case .hidden:
            nil
        case let .listening(sessionID, _, _),
             let .processing(sessionID, _),
             let .speaking(sessionID, _),
             let .error(sessionID, _, _):
            sessionID
        }
    }
    var isHidden: Bool { if case .hidden = self { true } else { false } }
}

enum ActivityOverlayAction: Equatable, Sendable {
    case cancelDictation(sessionID: UUID)
    case stopSpeech(sessionID: UUID)
}

@MainActor
protocol ActivityOverlayScheduling {
    func schedule(after: Duration, _ operation: @escaping @MainActor () -> Void)
}

@MainActor
@Observable
final class ActivityOverlayModel {
    private(set) var state: ActivityOverlayState = .hidden
    private let scheduler: any ActivityOverlayScheduling
    private var activeSessionID: UUID?
    private var stateDidChange: (@MainActor (ActivityOverlayState) -> Void)?

    init(scheduler: any ActivityOverlayScheduling = MainActorOverlayScheduler()) {
        self.scheduler = scheduler
    }

    func setStateHandler(_ handler: @escaping @MainActor (ActivityOverlayState) -> Void) {
        stateDidChange = handler
        handler(state)
    }

    func begin(sessionID: UUID) {
        activeSessionID = sessionID
        setState(.hidden)
    }

    func listen(sessionID: UUID, startedAt: Date = .now) {
        guard activeSessionID == sessionID else { return }
        setState(.listening(sessionID: sessionID, startedAt: startedAt, level: 0))
    }

    func updateLevel(_ level: Float, sessionID: UUID) {
        guard case let .listening(active, startedAt, _) = state, active == sessionID else { return }
        setState(.listening(sessionID: active, startedAt: startedAt, level: min(max(level, 0), 1)))
    }

    func process(sessionID: UUID) {
        guard case let .listening(activeSession, startedAt, _) = state,
              activeSession == sessionID else { return }
        setState(.processing(sessionID: sessionID, startedAt: startedAt))
    }
    func speak(sessionID: UUID, startedAt: Date = .now) {
        guard activeSessionID == sessionID else { return }
        setState(.speaking(sessionID: sessionID, startedAt: startedAt))
    }
    func cancel(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        setState(.hidden)
    }
    func complete(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        scheduler.schedule(after: .milliseconds(180)) { [weak self] in
            guard self?.activeSessionID == sessionID else { return }
            self?.activeSessionID = nil
            self?.setState(.hidden)
        }
    }
    func fail(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String) {
        guard activeSessionID == sessionID else { return }
        setState(.error(sessionID: sessionID, category: category, message: message))
        scheduler.schedule(after: .milliseconds(2_500)) { [weak self] in
            guard self?.activeSessionID == sessionID else { return }
            self?.activeSessionID = nil
            self?.setState(.hidden)
        }
    }

    private func setState(_ nextState: ActivityOverlayState) {
        state = nextState
        stateDidChange?(nextState)
    }
}
```

The production scheduler uses `Task { try? await Task.sleep(for: delay); await operation() }`; the operation itself rechecks the session ID before hiding.

- [x] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 `xcodebuild` command. Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Relay/App/ActivityOverlayModel.swift RelayTests/App/ActivityOverlayModelTests.swift
git commit -m "feat(overlay): add session-safe activity model"
```

## Task 3: Map state to Minimal and Interactive SwiftUI presentation

**Files:**
- Create: `Relay/App/ActivityOverlayPresentation.swift`
- Create: `Relay/App/ActivityOverlayView.swift`
- Create: `RelayTests/App/ActivityOverlayPresentationTests.swift`

**Interfaces:**
- Consumes: `ActivityOverlayState`, `ActivityOverlayStyle`, and `ActivityOverlayAction`.
- Produces: pure `ActivityOverlayPresentation.make(state:style:reduceMotion:)` and `ActivityOverlayView`.

- [x] **Step 1: Write failing presentation mapping tests**

```swift
func testOffAlwaysMapsToHidden() {
    let state = ActivityOverlayState.speaking(sessionID: UUID(), startedAt: .now)
    XCTAssertNil(ActivityOverlayPresentation.make(state: state, style: .off, reduceMotion: false))
}

func testInteractiveListeningShowsCancelAndElapsedTime() {
    let id = UUID()
    let value = ActivityOverlayPresentation.make(
        state: .listening(sessionID: id, startedAt: .distantPast, level: 0.4),
        style: .interactive,
        reduceMotion: false
    )
    XCTAssertEqual(value?.title, "Listening")
    XCTAssertEqual(value?.action, .cancelDictation(sessionID: id))
    XCTAssertEqual(value?.actionAccessibilityLabel, "Cancel dictation")
    XCTAssertEqual(value?.size, CGSize(width: 282, height: 62))
}

func testMinimalHasNoTextOrControl() {
    let value = ActivityOverlayPresentation.make(
        state: .processing(sessionID: UUID(), startedAt: .now),
        style: .minimal,
        reduceMotion: false
    )
    XCTAssertNil(value?.title)
    XCTAssertNil(value?.action)
    XCTAssertEqual(value?.size, CGSize(width: 154, height: 40))
}

func testReduceMotionDisablesAnimatedWaveformsAndScale() {
    let value = ActivityOverlayPresentation.make(
        state: .speaking(sessionID: UUID(), startedAt: .now),
        style: .interactive,
        reduceMotion: true
    )
    XCTAssertFalse(value!.animatesWaveform)
    XCTAssertFalse(value!.usesScaleTransition)
}
```

Also cover Processing→Cancel, Speaking→Stop, sanitized error rendering, Listening red/Processing amber/Speaking violet-cyan accents, and deterministic synthetic speaking bars.

- [x] **Step 2: Run presentation tests and verify RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/ActivityOverlayPresentationTests test
```

Expected: compile failure because presentation types do not exist.

- [x] **Step 3: Implement the pure presentation value and mapper**

```swift
struct ActivityOverlayPresentation: Equatable {
    enum Kind: Equatable { case listening(level: Float), processing, speaking, error }
    enum Accent: Equatable { case red, amber, violetCyan, error }
    let kind: Kind
    let accent: Accent
    let size: CGSize
    let title: String?
    let startedAt: Date?
    let action: ActivityOverlayAction?
    let actionAccessibilityLabel: String?
    let animatesWaveform: Bool
    let usesScaleTransition: Bool

    static func make(
        state: ActivityOverlayState,
        style: ActivityOverlayStyle,
        reduceMotion: Bool
    ) -> Self? {
        guard style != .off, !state.isHidden else { return nil }
        let interactive = style == .interactive
        let size = interactive ? CGSize(width: 282, height: 62) : CGSize(width: 154, height: 40)
        switch state {
        case .hidden:
            return nil
        case let .listening(sessionID, startedAt, level):
            return .init(
                kind: .listening(level: level), accent: .red, size: size,
                title: interactive ? "Listening" : nil, startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: !reduceMotion
            )
        case let .processing(sessionID, startedAt):
            return .init(
                kind: .processing, accent: .amber, size: size,
                title: interactive ? "Processing" : nil, startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: false, usesScaleTransition: !reduceMotion
            )
        case let .speaking(sessionID, startedAt):
            return .init(
                kind: .speaking, accent: .violetCyan, size: size,
                title: interactive ? "Speaking" : nil, startedAt: startedAt,
                action: interactive ? .stopSpeech(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Stop speech" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: !reduceMotion
            )
        case let .error(_, _, message):
            return .init(
                kind: .error, accent: .error, size: size,
                title: interactive ? message : nil, startedAt: nil,
                action: nil, actionAccessibilityLabel: nil,
                animatesWaveform: false, usesScaleTransition: !reduceMotion
            )
        }
    }
}
```

- [x] **Step 4: Implement the capsule view**

`ActivityOverlayView` receives the observable model, style, and an async-safe `onAction` closure. Use `TimelineView(.animation)` for elapsed time and the deterministic speaking waveform; use microphone level only for listening. Apply a dark material capsule, subtle stroke/shadow, state accent color, and `@Environment(\.accessibilityReduceMotion)` to disable scale/wave motion. The button uses the presentation's exact accessibility label and no pause/resume affordance.

- [x] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [x] **Step 6: Commit**

```bash
git add Relay/App/ActivityOverlayPresentation.swift Relay/App/ActivityOverlayView.swift \
  RelayTests/App/ActivityOverlayPresentationTests.swift
git commit -m "feat(overlay): add activity capsule presentation"
```

## Task 4: Host the overlay in a non-activating AppKit panel

**Files:**
- Create: `Relay/App/ActivityOverlayWindowController.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/System/Diagnostics.swift`
- Create: `RelayTests/App/ActivityOverlayWindowControllerTests.swift`
- Modify: `RelayTests/System/DiagnosticsTests.swift`

**Interfaces:**
- Produces: `ActivityOverlayPresenting.update(state:style:)`, pure `ActivityOverlayPlacement`, and production `ActivityOverlayWindowController`.
- Consumes: the state model, current style, and an `ActivityOverlayAction` handler.

- [x] **Step 1: Write failing placement, screen pinning, show/hide, and failure-isolation tests**

```swift
func testPlacementCentersAboveVisibleFrameBottom() {
    let frame = CGRect(x: 100, y: 50, width: 1_200, height: 800)
    XCTAssertEqual(
        ActivityOverlayPlacement.origin(panelSize: .init(width: 282, height: 62), visibleFrame: frame),
        CGPoint(x: 559, y: 78)
    )
}

@MainActor
func testSessionPinsChosenDisplayUntilHidden() {
    let screens = FakeOverlayScreens(first: .left, then: .right)
    let host = FakeOverlayPanelHost()
    let presenter = ActivityOverlayWindowController(host: host, screens: screens)
    let id = UUID()
    presenter.update(state: .listening(sessionID: id, startedAt: .now, level: 0), style: .interactive)
    presenter.update(state: .processing(sessionID: id, startedAt: .now), style: .interactive)
    XCTAssertEqual(host.positionedScreens, [.left, .left])
}

@MainActor
func testOffAndHiddenOrderPanelOutWithoutCreatingIt() {
    let host = FakeOverlayPanelHost()
    let presenter = ActivityOverlayWindowController(host: host, screens: FakeOverlayScreens())
    presenter.update(state: .hidden, style: .interactive)
    presenter.update(state: .speaking(sessionID: UUID(), startedAt: .now), style: .off)
    XCTAssertEqual(host.createCount, 0)
}
```

Add a failure test proving a host creation/show error records only `.overlayFailed` and does not throw into speech/dictation.

- [x] **Step 2: Run focused controller/diagnostics tests and verify RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/ActivityOverlayWindowControllerTests \
  -only-testing:RelayTests/DiagnosticsTests test
```

Expected: compile failure because the controller and diagnostics event do not exist.

- [x] **Step 3: Implement pure placement and panel policies**

```swift
enum ActivityOverlayPlacement {
    static func origin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + 28
        )
    }
}
```

The lazily-created `NSPanel` uses `.borderless` and `.nonactivatingPanel`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`, `level = .floating`, `isMovable = false`, `isReleasedWhenClosed = false`, clear background, and no shadow outside the capsule. Override `canBecomeKey` and `canBecomeMain` to return false. Minimal sets `ignoresMouseEvents = true`; Interactive permits pointer events for the button without activation.

- [x] **Step 4: Implement session-pinned display selection and relayout**

Choose the display once when a new non-hidden session ID arrives; use the screen containing the mouse with `NSScreen.main`/first-screen fallback. Retain that screen ID through listening→processing and relayout against its current `visibleFrame` on `NSApplication.didChangeScreenParametersNotification`. Clear the pinned display only after hidden.

- [x] **Step 5: Wire the host without coupling backends to AppKit**

`AppModel` owns the overlay model and an injected class-bound `ActivityOverlayPresenting`. The production composition creates `ActivityOverlayWindowController`; tests default to a no-op presenter. Bind `ActivityOverlayModel.setStateHandler` to `presenter.update(state:style:)`, reading the current style from the existing shared `SettingsState`. `setActivityOverlayStyle` explicitly calls the same update after persistence so a style change redraws or hides the active panel. Add an AppModel test proving `overlayModel.begin` + `listen` reaches a fake presenter, and a style-change test proving an active presentation updates immediately. Add `.overlayFailed` to `DiagnosticEvent` with the fixed copy text `"Activity overlay failed"`; never attach raw errors.

- [x] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [x] **Step 7: Commit**

```bash
git add Relay/App/ActivityOverlayWindowController.swift Relay/App/AppModel.swift \
  Relay/System/Diagnostics.swift RelayTests/App/ActivityOverlayWindowControllerTests.swift \
  RelayTests/System/DiagnosticsTests.swift
git commit -m "feat(overlay): host activity capsule above apps"
```

## Task 5: Publish real Apple TTS playback lifecycle

**Files:**
- Modify: `Relay/SpeechOut/TextToSpeechBackend.swift`
- Modify: `Relay/SpeechOut/AppleTTSBackend.swift`
- Modify: `Relay/SpeechOut/TTSRouter.swift`
- Modify: `Relay/SpeechOut/SpeechCoordinator.swift`
- Modify: `Relay/App/AppModel.swift`
- Create: `RelayTests/SpeechOut/AppleTTSBackendTests.swift`
- Modify: `RelayTests/SpeechOut/TTSRouterTests.swift`
- Modify: `RelayTests/SpeechOut/SpeechCoordinatorTests.swift`

**Interfaces:**
- Produces: `TTSPlaybackEvent` and session-aware backend/router calls.
- Consumes: `ActivityOverlayModel.begin/speak/complete/cancel/fail`.

- [x] **Step 1: Write failing lifecycle and stale-session tests**

```swift
@MainActor
func testOverlayStartsOnlyWhenBackendReportsStarted() async throws {
    let backend = FakeTTSBackend(id: "apple")
    let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
    let coordinator = makeCoordinator(backend: backend, overlay: overlay)
    try await coordinator.speak(request(text: "hello", mode: .userRequested))
    XCTAssertTrue(overlay.state.isHidden)
    backend.emitStarted()
    guard case .speaking = overlay.state else { return XCTFail("Expected speaking") }
}

@MainActor
func testLateFinishFromStoppedSessionCannotHideReplacement() async throws {
    let backend = FakeTTSBackend(id: "apple")
    let overlay = ActivityOverlayModel(scheduler: FakeOverlayScheduler())
    let coordinator = makeCoordinator(backend: backend, overlay: overlay)
    try await coordinator.speak(request(text: "first", mode: .userRequested))
    let first = backend.lastSessionID!
    backend.emit(.started(sessionID: first))
    try await coordinator.speak(request(text: "second", mode: .userRequested))
    let second = backend.lastSessionID!
    backend.emit(.started(sessionID: second))
    backend.emit(.finished(sessionID: first))
    XCTAssertEqual(overlay.state.sessionID, second)
}
```

Apple adapter tests use the `AppleSpeechSynthesizing` seam defined in Step 3 to cover scheduled, didStart, didFinish, and didCancel mappings without speaking through the real system voice. A separate invalid-voice/router test covers `.failed`, because `AVSpeechSynthesizerDelegate` has no failure callback.

- [x] **Step 2: Run focused speech tests and verify RED**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/AppleTTSBackendTests \
  -only-testing:RelayTests/TTSRouterTests \
  -only-testing:RelayTests/SpeechCoordinatorTests test
```

Expected: compile failure because typed playback lifecycle does not exist.

- [x] **Step 3: Add the provider-neutral lifecycle contract**

```swift
enum TTSPlaybackEvent: Equatable, Sendable {
    case scheduled(sessionID: UUID)
    case started(sessionID: UUID)
    case finished(sessionID: UUID)
    case cancelled(sessionID: UUID)
    case failed(sessionID: UUID)
}

@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }
    func availability() async -> BackendAvailability
    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void)
    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}

@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}
```

Extend `AVSpeechSynthesizer` to conform to `AppleSpeechSynthesizing`. Update `TTSRouter.speak` to accept a session ID, track the active backend/session, and forward only that selected backend's events. When every candidate fails or a non-fallback error terminates routing, the router emits `.failed(sessionID:)` without exposing error text. `TTSRouter.stop()` clears its active backend/session after issuing stop; `stop(sessionID:)` no-ops unless the ID matches. Preserve fallback behavior for synchronous scheduling errors.

- [x] **Step 4: Adapt `AVSpeechSynthesizerDelegate`**

Make `AppleTTSBackend` inherit `NSObject`, inject `any AppleSpeechSynthesizing`, install itself as delegate, store `[ObjectIdentifier: UUID]` for live utterances, emit `.scheduled` after calling `speak`, and map the available delegate callbacks to `.started`, `.finished`, and `.cancelled`. Remove a mapping on either terminal event. Synchronous validation errors throw to the router, which emits `.failed`; there is no invented delegate failure callback. Never include utterance text in an event.

- [x] **Step 5: Map lifecycle in `SpeechCoordinator`**

Generate one UUID per speak/replay attempt and call `overlay.begin(sessionID:)` before routing. Enter overlay speaking only on matching `.started`; call `complete`, `cancel`, or `fail(category: .speechPlayback, message: "Speech playback failed.")` on matching terminal events. Add `SpeechCoordinating.stop(sessionID:)` and `SpeechCoordinator.stop(sessionID:)`; they no-op for a stale ID and otherwise stop the router and cancel only the matching overlay session. Unconditional `stop()` remains for the global hotkey and dictation priority rule. Add tests proving an old Interactive Stop cannot stop replacement speech.

- [x] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [x] **Step 7: Commit**

```bash
git add Relay/SpeechOut Relay/App/AppModel.swift RelayTests/SpeechOut
git commit -m "feat(overlay): report Apple speech playback lifecycle"
```

## Task 6: Publish dictation lifecycle, microphone level, and session cancellation

**Files:**
- Modify: `Relay/SpeechIn/MicrophoneCapture.swift`
- Modify: `Relay/SpeechIn/DictationCoordinator.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `RelayTests/SpeechIn/MicrophoneCaptureStateTests.swift`
- Modify: `RelayTests/SpeechIn/DictationCoordinatorTests.swift`
- Modify: `RelayTests/App/AppModelTests.swift`

**Interfaces:**
- `MicrophoneCapturing.start(onLevel:)` emits only normalized `Float` values and gains `cancel()`.
- `DictationCoordinating.cancel(sessionID:)` cancels only the represented session.
- Dictation consumes `ActivityOverlayModel.begin/listen/updateLevel/process/complete/cancel/fail`.

- [x] **Step 1: Write failing level, lifecycle, cancellation, and stale-callback tests**

```swift
func testLevelMeterNormalizesRMSWithoutExposingSamples() {
    XCTAssertEqual(MicrophoneLevelMeter.normalized(samples: [0, 0]), 0)
    XCTAssertEqual(MicrophoneLevelMeter.normalized(samples: [1, -1]), 1)
}

@MainActor
func testDictationPublishesListeningProcessingAndCompletionForOneSession() async {
    let overlay = RecordingActivityOverlay()
    let coordinator = makeCoordinator(overlay: overlay)
    await coordinator.start()
    let session = overlay.sessionID!
    await coordinator.finish()
    XCTAssertEqual(overlay.events, [.listening(session), .processing(session), .completed(session)])
}

@MainActor
func testInteractiveCancelStopsOnlyMatchingListeningSession() async {
    let microphone = CancellableFakeMicrophone()
    let overlay = RecordingActivityOverlay()
    let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)
    await coordinator.start()
    let session = overlay.sessionID!
    await coordinator.cancel(sessionID: session)
    XCTAssertEqual(microphone.cancelCount, 1)
    XCTAssertEqual(overlay.events.last, .cancelled(session))
}
```

Also cover processing cancellation, late level updates, late transcription completion, no-speech error category, microphone/start failure categories, insertion failure category, and starting dictation stopping/hiding active TTS before listening appears.

- [x] **Step 2: Run focused dictation tests and verify RED**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data \
  -only-testing:RelayTests/MicrophoneCaptureStateTests \
  -only-testing:RelayTests/DictationCoordinatorTests \
  -only-testing:RelayTests/AppModelTests test
```

Expected: compile failure because the level and cancellation interfaces do not exist.

- [x] **Step 3: Compute and emit normalized microphone levels in capture**

```swift
enum MicrophoneLevelMeter {
    static func normalized(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let rms = sqrt(meanSquare)
        return min(max(rms * 4, 0), 1)
    }
}
```

Change `MicrophoneCapturing.start` to accept `@escaping @Sendable (Float) -> Void`. In `MicrophoneCapture`'s existing source callback, append samples for STT and emit only `MicrophoneLevelMeter.normalized(samples:)`. Add `cancel()` that stops the source when starting/recording/stopping, resets the accumulator, and returns the actor to idle.

- [x] **Step 4: Make `DictationCoordinator` session-aware and cancellable**

Associate a UUID with `.starting`, `.recording`, and `.finishing`; retain a cancellable processing `Task`. Publish listening after microphone start, processing before stop/transcription, completion after insertion, and stable sanitized error messages/categories on failure. Every level/result/error callback checks the active session. Cancellation stops capture or cancels processing, clears state, and hides only that session.

- [x] **Step 5: Wire the Interactive action dispatcher**

```swift
@MainActor
protocol ActivityOverlayControlling: AnyObject {
    func perform(_ action: ActivityOverlayAction)
}
```

The production dispatcher routes `.cancelDictation(sessionID:)` to a `Task` calling `DictationCoordinator.cancel(sessionID:)` and `.stopSpeech(sessionID:)` to the session-aware `SpeechCoordinator.stop(sessionID:)` added in Task 5. It has no backend- or AppKit-specific logic.

- [x] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [x] **Step 7: Commit**

```bash
git add Relay/SpeechIn Relay/App/AppModel.swift RelayTests/SpeechIn RelayTests/App/AppModelTests.swift
git commit -m "feat(overlay): report and control dictation activity"
```

## Task 7: Complete integration and macOS acceptance

**Files:**
- Modify only files required by integration findings from Tasks 1–6.
- Update: `docs/superpowers/plans/2026-09-14-relay-phase-1-5-activity-overlay-implementation-plan.md` checkboxes.

**Interfaces:**
- Verifies the complete Phase 1.5 deliverable without expanding scope.

- [x] **Step 1: Regenerate the Xcode project and run the entire suite**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' \
  -derivedDataPath .derived-data test
```

Expected: `** TEST SUCCEEDED **`; all XCTest and Swift Testing cases pass.

- [x] **Step 2: Run a fresh review against the Phase 1.5 base commit**

Review both spec conformance and code quality. Resolve every Critical or Important finding, add a regression test for each behavior fix, and rerun Step 1.

- [ ] **Step 3: Perform manual macOS acceptance**

Build/run Relay from Xcode and verify:

1. Interactive overlay appears at the bottom center while dictating, changes Listening→Processing, and its Cancel control works.
2. Interactive overlay appears only after Apple TTS actually starts, shows elapsed time, and Stop ends speech.
3. Minimal shows the compact capsule with no text/control; Off never creates/shows the panel.
4. The panel floats above ordinary/full-screen apps, joins Spaces, stays on its initially selected display, and never steals typing focus.
5. Settings and Diagnostics can open/focus while the overlay is active.
6. Reduce Motion removes waveform/scale motion; VoiceOver announces the Interactive action label without forced focus.
7. A forced presentation failure leaves dictation/TTS functional and records only `Activity overlay failed` in Diagnostics.

Acceptance record 2026-09-15 at `64490cd` (live on the user's Mac):
- Items 1, 2, 3: pass. Cancel and Stop controls work. Off mid-dictation works. Minimal works.
- Item 4: Spaces, display selection, and full-screen app pass. Pointer-move-while-dictating not yet checked.
- Item 5: not yet checked. Item 6 (Reduce Motion, VoiceOver): optional accessibility checks, not yet run.
- Item 7: covered by unit tests only; not reachable by hand without a code change.
- Insertion: `via paste` confirmed in Ghostty, `via accessibility` confirmed in a native field.

- [ ] **Step 4: Commit any verified integration fixes**

```bash
git status --short
git diff --check
```

Stage only the exact files named by `git status --short`, inspect `git diff --cached`, and commit them with `fix(overlay): address macOS acceptance findings`.

If Step 3 needs no code changes, do not create an empty commit.
