# Call-safe Dictation Mic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dictation records from a mic the user picks, every dictation releases the mic, and Relay reports a mic that stays open.

**Architecture:** `AVAudioEngineSource` builds a fresh `AVAudioEngine` per dictation, points its input unit at the chosen device, and drops the engine on every teardown path. A `MicrophoneReleaseMonitor` asks CoreAudio 1 s after each teardown whether Relay's process still runs input, and reports to Diagnostics. A pure resolver maps the saved choice to a connected device or the system default.

**Tech Stack:** Swift 6, AVFoundation, CoreAudio (`AudioObjectGetPropertyData`, `AudioUnitSetProperty`), SwiftUI, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-06-call-safe-dictation-mic-design.md`

## Global Constraints

- Never change the system default input device.
- A missing chosen device falls back to the system default. Dictation never fails for that reason.
- Diagnostics carry no audio and no transcript text. Device names are allowed.
- Keep `AVAudioEngineSource` threading rules: engine mutations on `engineQueue`, no teardown from inside the tap, the gate brackets every callback.
- macOS deployment target 26.0. No new package dependency.
- New files: run `xcodegen generate` before you build.
- Test: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. Lint: `scripts/lint.sh` must be clean.
- Commits go through `/ledger`. No Claude attribution lines.

## Review Focus

- A new dictation starts less than 1 s after the previous one stopped: the monitor must not report the running mic as a leak. (Task 2 test `testNewCaptureBeforeCheckSuppressesReport`.)
- The chosen device disconnects between the picker and the key press: the capture uses the default, and Diagnostics gets one fallback note. (Task 1 resolver test `testMissingChoiceFallsBackToDefaultWithNote`; Task 3 logs the note.)
- `AudioUnitSetProperty` fails for a device that exists (busy, or no input streams now): use the default and log. Do not throw. (Task 3, the setter returns `Bool`.)
- A route change during a dictation (Bluetooth switches to headset mode) fails the capture. The failure teardown must also release the engine and arm the monitor. (Task 3, `fail()` path. No unit test reaches it without a device. Covered by the manual round in Task 5.)
- Settings from an older build have no `selectedMicrophone` key, or hold a malformed value: decode gives `nil`, and every other field keeps its value. (Task 1 tests.)

---

### Task 1: Settings field and device resolver

**Files:**
- Create: `Relay/Audio/AudioInputDevices.swift`
- Modify: `Relay/Domain/AppSettings.swift` (field, `CodingKeys`, `init(from:)`, memberwise `init`)
- Modify: `Relay/App/SettingsController.swift:94` (add setter beside `setLiveTranscriptionEnabled`)
- Test: `RelayTests/Audio/MicrophoneSelectionTests.swift`, `RelayTests/Domain/AppSettingsTests.swift` (add cases; create the file only if no settings test file exists — find it with `grep -rl "AppSettings" RelayTests`)

**Interfaces:**
- Produces:
  - `struct SelectedMicrophone: Codable, Equatable, Sendable { let uid: String; let name: String }`
  - `AppSettings.selectedMicrophone: SelectedMicrophone?` (default `nil` = system default)
  - `SettingsController.setSelectedMicrophone(_ microphone: SelectedMicrophone?)`
  - `struct AudioInputDevice: Equatable, Sendable, Identifiable { let id: AudioDeviceID; let uid: String; let name: String }`
  - `enum MicrophoneSelection { static func resolve(_ choice: SelectedMicrophone?, connected: [AudioInputDevice]) -> Resolution }`
  - `struct MicrophoneSelection.Resolution: Equatable { let device: AudioInputDevice?; let missing: SelectedMicrophone? }` — `device == nil` means "use the system default"
  - `enum AudioInputDevices { static func connected() -> [AudioInputDevice] }` (CoreAudio, input devices only, CoreAudio order)

- [ ] **Step 1: Write the failing tests**

```swift
// MicrophoneSelectionTests
let builtIn = AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
let airPods = AudioInputDevice(id: 20, uid: "AA-BB:input", name: "AirPods Pro")

func testNoChoiceUsesDefault() {
    XCTAssertEqual(MicrophoneSelection.resolve(nil, connected: [builtIn, airPods]), .init(device: nil, missing: nil))
}
func testConnectedChoiceIsUsed() {
    let choice = SelectedMicrophone(uid: builtIn.uid, name: builtIn.name)
    XCTAssertEqual(MicrophoneSelection.resolve(choice, connected: [airPods, builtIn]), .init(device: builtIn, missing: nil))
}
func testMissingChoiceFallsBackToDefaultWithNote() {
    let choice = SelectedMicrophone(uid: "gone", name: "Old Headset")
    XCTAssertEqual(MicrophoneSelection.resolve(choice, connected: [builtIn]), .init(device: nil, missing: choice))
}

// AppSettings tests
func testSelectedMicrophoneRoundTrips()          // encode defaults with selectedMicrophone set, decode, equal
func testMissingSelectedMicrophoneDecodesToNil() // JSON without the key -> nil, dictationMode kept
func testMalformedSelectedMicrophoneDecodesToNil() // "selectedMicrophone": 42 -> nil, ttsRate kept
```

- [ ] **Step 2: Run tests, expect FAIL** (`cannot find 'MicrophoneSelection' in scope`)

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/MicrophoneSelectionTests`

- [ ] **Step 3: Implement** the types above. `AppSettings` decodes with the existing `field(...)` helper: `field(.selectedMicrophone, default: SelectedMicrophone?.none)`. `AudioInputDevices.connected()` reads `kAudioHardwarePropertyDevices`, keeps devices whose `kAudioDevicePropertyStreams` in `kAudioObjectPropertyScopeInput` is non-empty, and reads `kAudioDevicePropertyDeviceUID` and `kAudioObjectPropertyName`. It is a thin CoreAudio wrapper with no unit test.

- [ ] **Step 4: Run tests, expect PASS.** Run the full suite once.

- [ ] **Step 5: Commit** with `/ledger`.

### Task 2: Mic release monitor

**Files:**
- Create: `Relay/Audio/MicrophoneReleaseMonitor.swift`
- Modify: `Relay/System/Diagnostics.swift:85-102` (`DictationDiagnostic` cases and messages)
- Test: `RelayTests/Audio/MicrophoneReleaseMonitorTests.swift`

**Interfaces:**
- Produces:
  - `enum MicrophoneStopPath: String, Sendable { case stop, cancel, failure }`
  - `protocol ProcessInputProbing: Sendable { func isRunningInput() -> Bool? }` — `nil` when CoreAudio cannot answer
  - `struct CoreAudioProcessInputProbe: ProcessInputProbing` — `kAudioHardwarePropertyTranslatePIDToProcessObject` for `getpid()`, then `kAudioProcessPropertyIsRunningInput`
  - `final class MicrophoneReleaseMonitor: @unchecked Sendable`
    - `init(probe: any ProcessInputProbing, delay: Duration = .seconds(1), schedule: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = <DispatchQueue.global asyncAfter>, report: @escaping @Sendable (MicrophoneStopPath) -> Void)`
    - `func captureStarted()` and `func captureReleased(_ path: MicrophoneStopPath)`
  - `DictationDiagnostic.microphoneStillOpen(MicrophoneStopPath)` → message `"Microphone still open after dictation stopped (\(path.rawValue))"`
  - `DictationDiagnostic.microphoneFallback(missingName: String)` → message `"\(name) is not connected. Using the system default microphone."`

Design call (plan author): the spec asks for a check right after teardown and one 1 s later. The HAL can report input as running for some milliseconds after `engine.stop()`, so an immediate check gives false reports. The monitor checks only once, after `delay`. A generation counter makes `captureStarted()` cancel a pending check.

- [ ] **Step 1: Write the failing tests** with a fake probe and a manual scheduler (it stores the closure; the test runs it).

```swift
func testReportsWhenInputStillRunsAfterDelay()          // probe true, captureReleased(.cancel), run scheduled -> report == [.cancel]
func testNoReportWhenInputStopped()                     // probe false -> report == []
func testNoReportWhenProbeCannotAnswer()                // probe nil -> report == []
func testNewCaptureBeforeCheckSuppressesReport()        // captureReleased(.stop), captureStarted(), run scheduled -> report == []
func testDiagnosticMessages() // .microphoneStillOpen(.failure).message == "Microphone still open after dictation stopped (failure)"
```

- [ ] **Step 2: Run tests, expect FAIL** (`cannot find 'MicrophoneReleaseMonitor'`).
- [ ] **Step 3: Implement** the monitor (lock-guarded generation `Int`), the probe and the two diagnostic cases.
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** with `/ledger`.

### Task 3: Fresh engine per dictation, chosen device, monitor wiring

**Files:**
- Modify: `Relay/SpeechIn/AVAudioEngineSource.swift` (whole file)
- Modify: `Relay/App/RelayRuntime.swift:179-182` (build the source and pass it to `MicrophoneCapture(source:onCaptureDiagnostics:)`)

**Interfaces:**
- Consumes: Task 1 `MicrophoneSelection`, `AudioInputDevices`, `SelectedMicrophone`; Task 2 `MicrophoneReleaseMonitor`, `MicrophoneStopPath`, `DictationDiagnostic` cases.
- Produces: `AVAudioEngineSource.init(notificationCenter: NotificationCenter = .default, preferredMicrophone: @escaping @Sendable () -> SelectedMicrophone? = { nil }, releaseMonitor: MicrophoneReleaseMonitor? = nil, onFallback: @escaping @Sendable (String) -> Void = { _ in })`

Changes:
- `engine` becomes `private var engine: AVAudioEngine?`, touched only on `engineQueue`. `start()` creates it. `tearDownEngine(path:)` removes the tap, stops the engine, sets it to `nil`, and calls `releaseMonitor?.captureReleased(path)`. `start()` calls `releaseMonitor?.captureStarted()` first.
- Before `inputNode.inputFormat(forBus: 0)`: resolve `MicrophoneSelection.resolve(preferredMicrophone(), connected: AudioInputDevices.connected())`. When `missing != nil`, call `onFallback(missing.name)`. When `device != nil`, set `kAudioOutputUnitProperty_CurrentDevice` (global scope, element 0) on `inputNode.audioUnit` in a private `setInputDevice(_:on:) -> Bool`. On `false`, call `onFallback(device.name)` and go on with the default.
- The configuration observer closure captures the local engine of that session, not `self.engine`.
- `stop()` tears down with `.stop`. The `start()` error path uses `.failure`. `fail()` queues teardown with `.failure`. `cancel` reaches the source as `stop()`, so `MicrophoneCapture.cancel()` must pass the path: add `func stop(path: MicrophoneStopPath) async throws` to `AudioCaptureSourcing`, and keep `stop()` as `stop(path: .stop)` in a protocol extension. `MicrophoneCapture.cancel()` calls `stop(path: .cancel)`. Update the fake source in `MicrophoneCaptureStateTests` to match.
- `RelayRuntime`: `preferredMicrophone: { settings.value.selectedMicrophone }`, a monitor with `CoreAudioProcessInputProbe()`, and both reports go to `diagnostics.record(.dictation(...))` through `Task { @MainActor in ... }`.

No unit test reaches a real `AVAudioEngine` input. When you read the code, you can find a path that skips `tearDownEngine` (for example, `MicrophoneCapture.stop()` in `failedRecording` never calls the source). For that path, write a `MicrophoneCaptureStateTests` case first with the fake source, and assert that `stop(path:)` is called or that teardown already ran.

- [ ] **Step 1:** Write `MicrophoneCaptureStateTests.testCancelPassesCancelPath` (fake source records paths; start, cancel → `[.cancel]`). Run it, expect FAIL.
- [ ] **Step 2:** Add `stop(path:)` to the protocol and `MicrophoneCapture.cancel()`. Run, expect PASS.
- [ ] **Step 3:** Make the `AVAudioEngineSource` changes and the runtime wiring. Build.
- [ ] **Step 4:** Run the full test suite and `scripts/lint.sh`. Expect all green.
- [ ] **Step 5: Commit** with `/ledger`.

### Task 4: Microphone picker

**Files:**
- Modify: `Relay/App/Settings/DictationSettingsView.swift` (the "Dictation" section, under "Mode")

**Interfaces:**
- Consumes: Task 1 `AudioInputDevices.connected()`, `SelectedMicrophone`, `MicrophoneSelection.resolve`, `SettingsController.setSelectedMicrophone(_:)`, `model.settings.selectedMicrophone`.

Behavior:
- `@State private var devices: [AudioInputDevice] = []`. Load in the existing `.task` with `await Task.detached { AudioInputDevices.connected() }.value`.
- `Picker("Microphone", selection:)` over `String?` (UID). Entries: `Text("System default").tag(String?.none)`, then each device by name, tag `device.uid`.
- When the saved choice is missing from `devices`, add one more entry `"\(saved.name) (not connected)"` with its UID tag, and a caption: `"\(saved.name) is not connected. Relay uses the system default microphone."`
- On select: `nil` → `setSelectedMicrophone(nil)`. A UID → `SelectedMicrophone(uid:name:)` from the device list.
- Under the picker, a caption: `"Pick your Mac's built-in microphone to keep Bluetooth headphones in high-quality mode during calls."`

- [ ] **Step 1:** Implement. Build.
- [ ] **Step 2:** Run the full suite and lint. Expect green.
- [ ] **Step 3:** Run the app (`/run` or the README install step). Open Settings › Dictation. Check that the list shows the built-in mic and the headphones, and that the choice survives a relaunch.
- [ ] **Step 4: Commit** with `/ledger`.

### Task 5: Manual test round (Darius)

Not a build step. After Task 4 is installed, Darius runs the spec's reproduction list with Bluetooth headphones: normal dictations, a short tap, a cancel during start and during recording, live transcription on and off, a headset-mode switch during a dictation, and a disconnect during a dictation. Pass: the orange dot goes off within about 1 s each time, and Diagnostics shows no "Microphone still open" line. Then he repeats one dictation with "MacBook Pro Microphone" chosen during a call, and the headphone sound stays in high-quality mode.
